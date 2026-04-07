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

    // Low power mode monitoring
    NotificationCenter.default.addObserver(
      self, selector: #selector(powerStateChanged),
      name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil
    )

    // Enable background fetch for periodic wake-up
    UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

    // Auto-resume after kill
    let wasCollecting = UserDefaults.standard.bool(forKey: kCollectingKey)
    let launchedByLocation = launchOptions?[.location] != nil

    if wasCollecting || launchedByLocation {
      intervalSeconds = UserDefaults.standard.double(forKey: kIntervalKey)
      if intervalSeconds < 10 { intervalSeconds = 60 }
      NSLog("[ZairnLocation] Auto-resuming: wasCollecting=%d launchedByLocation=%d", wasCollecting, launchedByLocation)
      startLocationUpdates()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // =====================
  // Background Fetch — periodic wake-up even when stationary
  // =====================

  override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    let wasCollecting = UserDefaults.standard.bool(forKey: kCollectingKey)
    if wasCollecting && !isCollecting {
      NSLog("[ZairnLocation] Background fetch: restarting location")
      startLocationUpdates()
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

    // Open trace file
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let filePath = docs.appendingPathComponent("dense-trace.jsonl")
    if !FileManager.default.fileExists(atPath: filePath.path) {
      FileManager.default.createFile(atPath: filePath.path, contents: nil)
    }
    traceFileHandle = try? FileHandle(forWritingTo: filePath)
    traceFileHandle?.seekToEndOfFile()

    if let content = try? String(contentsOf: filePath, encoding: .utf8) {
      pointCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    // Start ALL location services for maximum wake-up coverage:
    // 1. Continuous GPS updates (primary, may be throttled in background)
    locationManager.startUpdatingLocation()
    // 2. Significant location changes (survives app kill, ~500m threshold)
    locationManager.startMonitoringSignificantLocationChanges()
    // 3. Visit monitoring (fires on arrival/departure detection)
    locationManager.startMonitoringVisits()

    isCollecting = true
    lastRecordedTime = .distantPast

    UserDefaults.standard.set(true, forKey: kCollectingKey)
    UserDefaults.standard.set(intervalSeconds, forKey: kIntervalKey)

    NSLog("[ZairnLocation] Started. Points: %d, interval: %.0fs", pointCount, intervalSeconds)
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
    NSLog("[ZairnLocation] Stopped. Total: %d", pointCount)
  }

  // =====================
  // Rolling Geofence — ensures wake-up on movement
  // =====================

  private func updateRollingGeofence(at location: CLLocation) {
    removeRollingGeofence()
    let region = CLCircularRegion(
      center: location.coordinate,
      radius: 100, // 100m radius
      identifier: kRegionId
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
    NSLog("[ZairnLocation] Low Power Mode: %@", isLowPower ? "ON" : "OFF")
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
    endBackgroundTask()
  }

  // Region exit → rolling geofence triggered → get fresh location
  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isCollecting, region.identifier == kRegionId else { return }
    NSLog("[ZairnLocation] Geofence exit — requesting location update")
    locationManager.requestLocation()
  }

  // Visit detected → record if interval passed
  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard isCollecting else { return }
    NSLog("[ZairnLocation] Visit detected: %.6f,%.6f", visit.coordinate.latitude, visit.coordinate.longitude)
    // Restart continuous updates (may have been stopped by iOS)
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
  // File writing
  // =====================

  private func writePoint(location: CLLocation, now: Date) {
    let data: [String: Any] = [
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy,
      "speed": max(0, location.speed),
      "altitude": location.altitude,
      "heading": max(0, location.course),
      "timestamp": now.timeIntervalSince1970 * 1000,
    ]

    if let jsonData = try? JSONSerialization.data(withJSONObject: data),
       let jsonString = String(data: jsonData, encoding: .utf8) {
      traceFileHandle?.write((jsonString + "\n").data(using: .utf8)!)
      traceFileHandle?.synchronizeFile()
      pointCount += 1
    }

    if UIApplication.shared.applicationState == .active {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(data)
      }
    }

    NSLog("[ZairnLocation] #%d %.6f,%.6f ±%.0fm bg=%@",
          pointCount, location.coordinate.latitude, location.coordinate.longitude,
          location.horizontalAccuracy,
          UIApplication.shared.applicationState != .active ? "YES" : "NO")
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
