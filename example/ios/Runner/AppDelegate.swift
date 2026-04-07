import Flutter
import UIKit
import CoreLocation

@main
@objc class AppDelegate: FlutterAppDelegate, CLLocationManagerDelegate {

  private let locationManager = CLLocationManager()
  private var channel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private var isCollecting = false
  private var intervalSeconds: Double = 60
  private var lastRecordedTime: Date = .distantPast
  private var traceFileHandle: FileHandle?
  private var pointCount: Int = 0
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var lastKnownLocation: CLLocation?

  private let kCollectingKey = "zairn_is_collecting"
  private let kIntervalKey = "zairn_interval_seconds"
  private let kRegionId = "zairn_rolling_geofence"
  private let kCrashCountKey = "zairn_crash_count"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as! FlutterViewController

    channel = FlutterMethodChannel(name: "zairn/ios_location", binaryMessenger: controller.binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        self?.intervalSeconds = args?["intervalSeconds"] as? Double ?? 60
        // Reset crash counter on manual start
        UserDefaults.standard.set(0, forKey: self?.kCrashCountKey ?? "")
        self?.startLocationUpdates()
        result(true)
      case "stop":
        self?.stopLocationUpdates()
        result(true)
      case "isRunning":
        result(self?.isCollecting ?? false)
      case "getPointCount":
        result(self?.pointCount ?? 0)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    eventChannel = FlutterEventChannel(name: "zairn/ios_location_events", binaryMessenger: controller.binaryMessenger)
    eventChannel?.setStreamHandler(self)

    // Location manager setup
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.distanceFilter = 1.0

    // Low power mode
    NotificationCenter.default.addObserver(
      self, selector: #selector(powerStateChanged),
      name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil
    )

    // Background fetch
    UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

    // --- Crash-safe auto-resume ---
    let wasCollecting = UserDefaults.standard.bool(forKey: kCollectingKey)
    let launchedByLocation = launchOptions?[.location] != nil
    let crashCount = UserDefaults.standard.integer(forKey: kCrashCountKey)

    if (wasCollecting || launchedByLocation) && crashCount < 3 {
      // Increment crash counter BEFORE starting (decrement on successful write)
      UserDefaults.standard.set(crashCount + 1, forKey: kCrashCountKey)

      intervalSeconds = UserDefaults.standard.double(forKey: kIntervalKey)
      if intervalSeconds < 10 { intervalSeconds = 60 }

      NSLog("[ZairnLocation] Auto-resume in 3s (crash_count=%d)", crashCount + 1)

      // Delay to let Flutter engine finish initializing
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
        guard let self = self else { return }
        if UserDefaults.standard.bool(forKey: self.kCollectingKey) {
          self.startLocationUpdates()
        }
      }
    } else if crashCount >= 3 {
      NSLog("[ZairnLocation] Auto-resume DISABLED: crash loop detected (%d crashes). Tap Start manually.", crashCount)
      // Reset so user can manually start
      UserDefaults.standard.set(false, forKey: kCollectingKey)
      UserDefaults.standard.set(0, forKey: kCrashCountKey)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // =====================
  // Background Fetch
  // =====================

  override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if UserDefaults.standard.bool(forKey: kCollectingKey) && !isCollecting {
      let crashCount = UserDefaults.standard.integer(forKey: kCrashCountKey)
      guard crashCount < 3 else { completionHandler(.noData); return }
      NSLog("[ZairnLocation] Background fetch: restarting")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        self?.startLocationUpdates()
      }
      completionHandler(.newData)
    } else {
      completionHandler(.noData)
    }
  }

  // =====================
  // Start / Stop
  // =====================

  private func startLocationUpdates() {
    locationManager.requestAlwaysAuthorization()

    // Open NEW trace file per session to avoid growing-file problems
    // Files are named by date; export merges them
    openTraceFile()

    locationManager.startUpdatingLocation()
    locationManager.startMonitoringSignificantLocationChanges()
    locationManager.startMonitoringVisits()

    isCollecting = true
    lastRecordedTime = .distantPast

    UserDefaults.standard.set(true, forKey: kCollectingKey)
    UserDefaults.standard.set(intervalSeconds, forKey: kIntervalKey)

    NSLog("[ZairnLocation] Started. interval: %.0fs", intervalSeconds)
  }

  private func openTraceFile() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    // Use single file but DON'T count lines (avoid loading file into memory)
    let filePath = docs.appendingPathComponent("dense-trace.jsonl")
    if !FileManager.default.fileExists(atPath: filePath.path) {
      FileManager.default.createFile(atPath: filePath.path, contents: nil)
    }
    traceFileHandle = try? FileHandle(forWritingTo: filePath)
    traceFileHandle?.seekToEndOfFile()
    // Don't count lines — just track from this session
    pointCount = 0
  }

  private func stopLocationUpdates() {
    locationManager.stopUpdatingLocation()
    locationManager.stopMonitoringSignificantLocationChanges()
    locationManager.stopMonitoringVisits()
    removeRollingGeofence()
    endBackgroundTask()
    traceFileHandle?.closeFile()
    traceFileHandle = nil
    isCollecting = false
    UserDefaults.standard.set(false, forKey: kCollectingKey)
    UserDefaults.standard.set(0, forKey: kCrashCountKey)
    NSLog("[ZairnLocation] Stopped. Session points: %d", pointCount)
  }

  // =====================
  // Rolling Geofence
  // =====================

  private func updateRollingGeofence(at location: CLLocation) {
    removeRollingGeofence()
    let region = CLCircularRegion(
      center: location.coordinate, radius: 100, identifier: kRegionId
    )
    region.notifyOnExit = true
    region.notifyOnEntry = false
    locationManager.startMonitoring(for: region)
  }

  private func removeRollingGeofence() {
    for region in locationManager.monitoredRegions {
      if region.identifier == kRegionId {
        locationManager.stopMonitoring(for: region)
      }
    }
  }

  // =====================
  // Low Power Mode
  // =====================

  @objc private func powerStateChanged() {
    let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    NSLog("[ZairnLocation] Low Power: %@", isLowPower ? "ON" : "OFF")
    if isCollecting {
      if isLowPower {
        locationManager.stopUpdatingLocation()
      } else {
        locationManager.startUpdatingLocation()
      }
    }
    if UIApplication.shared.applicationState == .active {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(["_lowPowerMode": isLowPower])
      }
    }
  }

  // =====================
  // Background task
  // =====================

  private func beginBackgroundTaskIfNeeded() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ZairnGPS") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  // =====================
  // CLLocationManagerDelegate
  // =====================

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isCollecting, let location = locations.last else { return }
    guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else { return }
    guard -location.timestamp.timeIntervalSinceNow < 30 else { return }

    lastKnownLocation = location

    let now = Date()
    if now.timeIntervalSince(lastRecordedTime) < intervalSeconds { return }
    lastRecordedTime = now

    beginBackgroundTaskIfNeeded()
    writePoint(location: location, now: now)
    updateRollingGeofence(at: location)

    // Successful write = not crashing. Reset crash counter.
    UserDefaults.standard.set(0, forKey: kCrashCountKey)

    endBackgroundTask()
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isCollecting, region.identifier == kRegionId else { return }
    NSLog("[ZairnLocation] Geofence exit")
    locationManager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard isCollecting else { return }
    NSLog("[ZairnLocation] Visit detected")
    locationManager.startUpdatingLocation()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[ZairnLocation] Error: %@", error.localizedDescription)
    if isCollecting {
      locationManager.stopUpdatingLocation()
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        self?.locationManager.startUpdatingLocation()
      }
    }
  }

  // =====================
  // File writing — minimal, no memory allocation beyond the point
  // =====================

  private func writePoint(location: CLLocation, now: Date) {
    // Reopen file handle if it was closed (e.g., after background kill)
    if traceFileHandle == nil {
      openTraceFile()
    }

    // Manual JSON string construction — no JSONSerialization overhead
    let line = String(format:
      "{\"latitude\":%.7f,\"longitude\":%.7f,\"accuracy\":%.0f,\"speed\":%.1f,\"altitude\":%.1f,\"heading\":%.1f,\"timestamp\":%.0f}\n",
      location.coordinate.latitude,
      location.coordinate.longitude,
      location.horizontalAccuracy,
      max(0, location.speed),
      location.altitude,
      max(0, location.course),
      now.timeIntervalSince1970 * 1000
    )

    if let data = line.data(using: .utf8) {
      traceFileHandle?.write(data)
      traceFileHandle?.synchronizeFile()
      pointCount += 1
    }

    // Send to Flutter only when active
    if UIApplication.shared.applicationState == .active {
      let data: [String: Any] = [
        "latitude": location.coordinate.latitude,
        "longitude": location.coordinate.longitude,
        "accuracy": location.horizontalAccuracy,
        "speed": max(0, location.speed),
        "altitude": location.altitude,
        "heading": max(0, location.course),
        "timestamp": now.timeIntervalSince1970 * 1000,
      ]
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(data)
      }
    }

    NSLog("[ZairnLocation] #%d %.6f,%.6f ±%.0fm", pointCount,
          location.coordinate.latitude, location.coordinate.longitude,
          location.horizontalAccuracy)
  }
}

// FlutterStreamHandler
extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
