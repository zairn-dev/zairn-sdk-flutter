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
  private var pointCount: Int = 0
  private var lastKnownLocation: CLLocation?
  private var flutterChannelsConfigured = false
  private var isRestarting = false
  private var gpsErrorCount = 0
  private var bgActivitySession: NSObject? // CLBackgroundActivitySession (iOS 17+)

  private let kCollectingKey = "zairn_is_collecting"
  private let kIntervalKey = "zairn_interval_seconds"
  private let kRegionId = "zairn_rolling_geofence"
  private let kCrashCountKey = "zairn_crash_count"

  // Cached paths (avoid repeated FileManager lookups)
  private lazy var docsDir: URL = {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
  }()
  private lazy var traceFilePath: URL = { docsDir.appendingPathComponent("dense-trace.jsonl") }()
  private lazy var crashLogFilePath: URL = { docsDir.appendingPathComponent("zairn-crash-log.txt") }()

  // Cached formatter
  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
  }()

  // =====================
  // App Launch
  // =====================

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // === FIRST: crash loop detection (before ANY plugin code) ===
    let crashCount = UserDefaults.standard.integer(forKey: kCrashCountKey)
    if crashCount >= 3 {
      NSLog("[ZairnLocation] CRASH LOOP DETECTED (%d). Disabling auto-resume.", crashCount)
      UserDefaults.standard.set(false, forKey: kCollectingKey)
      UserDefaults.standard.set(0, forKey: kCrashCountKey)
    }

    installCrashLogger()
    logEvent("APP_LAUNCH crash_count=\(crashCount)")

    // Plugin registration
    GeneratedPluginRegistrant.register(with: self)
    if let pluginClass = NSClassFromString("FlutterForegroundTaskPlugin") as? NSObjectProtocol {
      let sel = NSSelectorFromString("setPluginRegistrantCallback:")
      if pluginClass.responds(to: sel) {
        FlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
          GeneratedPluginRegistrant.register(with: registry)
        }
      }
    }

    configureFlutterChannelsIfPossible()

    // Location manager setup (lightweight)
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.distanceFilter = 1.0

    NotificationCenter.default.addObserver(
      self, selector: #selector(powerStateChanged),
      name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil
    )

    UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

    // Auto-resume (crash counter is NOT incremented here — only on actual start)
    let wasCollecting = UserDefaults.standard.bool(forKey: kCollectingKey)
    let launchedByLocation = launchOptions?[.location] != nil

    if (wasCollecting || launchedByLocation) && crashCount < 3 {
      intervalSeconds = UserDefaults.standard.double(forKey: kIntervalKey)
      if intervalSeconds < 10 { intervalSeconds = 60 }

      logEvent("AUTO_RESUME scheduled (crash_count=\(crashCount))")

      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        guard let self = self else { return }
        guard UserDefaults.standard.bool(forKey: self.kCollectingKey) else { return }
        // Increment crash counter only when we actually start
        UserDefaults.standard.set(crashCount + 1, forKey: self.kCrashCountKey)
        self.logEvent("AUTO_RESUME executing")
        self.startLocationUpdates()
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // =====================
  // Lifecycle
  // =====================

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    logEvent("APP_DID_BECOME_ACTIVE pts=\(pointCount)")
    configureFlutterChannelsIfPossible()
    // Restore high accuracy in foreground
    if isCollecting {
      locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    logEvent("APP_DID_ENTER_BACKGROUND pts=\(pointCount)")
    // Reduce accuracy in background to lower power consumption
    // This makes iOS less likely to kill us for energy
    if isCollecting {
      locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    super.applicationWillTerminate(application)
    logEvent("APP_WILL_TERMINATE pts=\(pointCount)")
  }

  override func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    super.applicationDidReceiveMemoryWarning(application)
    logEvent("MEMORY_WARNING pts=\(pointCount)")
  }

  // =====================
  // Background Fetch
  // =====================

  override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    guard UserDefaults.standard.bool(forKey: kCollectingKey), !isCollecting else {
      completionHandler(.noData)
      return
    }
    let cc = UserDefaults.standard.integer(forKey: kCrashCountKey)
    guard cc < 3 else { completionHandler(.noData); return }

    logEvent("BG_FETCH: restarting")
    // Start location, THEN call completion handler
    DispatchQueue.main.async { [weak self] in
      self?.startLocationUpdates()
      // Give iOS a moment to register the location service
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        completionHandler(.newData)
      }
    }
  }

  // =====================
  // Start / Stop
  // =====================

  private func startLocationUpdates() {
    let status = locationManager.authorizationStatus
    if status == .notDetermined {
      locationManager.requestAlwaysAuthorization()
    }

    ensureTraceFileExists()

    // iOS 17+: CLBackgroundActivitySession tells iOS to prioritize this app
    if #available(iOS 17.0, *) {
      if bgActivitySession == nil {
        bgActivitySession = CLBackgroundActivitySession() as NSObject
        logEvent("CLBackgroundActivitySession started")
      }
    }

    // Activity type hint: .other is most general
    locationManager.activityType = .other

    locationManager.startUpdatingLocation()
    locationManager.startMonitoringSignificantLocationChanges()
    locationManager.startMonitoringVisits()

    isCollecting = true
    isRestarting = false
    gpsErrorCount = 0
    lastRecordedTime = .distantPast

    UserDefaults.standard.set(true, forKey: kCollectingKey)
    UserDefaults.standard.set(intervalSeconds, forKey: kIntervalKey)

    logEvent("STARTED interval=\(intervalSeconds)s")
  }

  private func stopLocationUpdates() {
    locationManager.stopUpdatingLocation()
    locationManager.stopMonitoringSignificantLocationChanges()
    locationManager.stopMonitoringVisits()
    removeRollingGeofence()
    if #available(iOS 17.0, *) {
      (bgActivitySession as? CLBackgroundActivitySession)?.invalidate()
      bgActivitySession = nil
    }
    isCollecting = false
    isRestarting = false
    UserDefaults.standard.set(false, forKey: kCollectingKey)
    UserDefaults.standard.set(0, forKey: kCrashCountKey)
    logEvent("STOPPED pts=\(pointCount)")
  }

  private func ensureTraceFileExists() {
    if !FileManager.default.fileExists(atPath: traceFilePath.path) {
      FileManager.default.createFile(atPath: traceFilePath.path, contents: nil)
    }
    pointCount = 0
  }

  // =====================
  // Flutter Channels (deferred setup)
  // =====================

  private func configureFlutterChannelsIfPossible() {
    guard !flutterChannelsConfigured else { return }
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    channel = FlutterMethodChannel(name: "zairn/ios_location", binaryMessenger: controller.binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any]
        self?.intervalSeconds = args?["intervalSeconds"] as? Double ?? 60
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
    flutterChannelsConfigured = true
  }

  // =====================
  // Rolling Geofence
  // =====================

  private func updateRollingGeofence(at location: CLLocation) {
    removeRollingGeofence()
    let region = CLCircularRegion(center: location.coordinate, radius: 100, identifier: kRegionId)
    region.notifyOnExit = true
    region.notifyOnEntry = false
    locationManager.startMonitoring(for: region)
  }

  private func removeRollingGeofence() {
    for region in locationManager.monitoredRegions where region.identifier == kRegionId {
      locationManager.stopMonitoring(for: region)
    }
  }

  // =====================
  // Low Power Mode
  // =====================

  @objc private func powerStateChanged() {
    let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    logEvent("LOW_POWER: \(isLowPower)")
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
  // CLLocationManagerDelegate
  // =====================

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isCollecting, let location = locations.last else { return }
    guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else { return }
    guard -location.timestamp.timeIntervalSinceNow < 30 else { return }

    let now = Date()
    guard now.timeIntervalSince(lastRecordedTime) >= intervalSeconds else { return }
    lastRecordedTime = now

    // Reset error count on successful location
    gpsErrorCount = 0

    writePoint(location: location, now: now)

    // Update geofence only on significant movement
    if let last = lastKnownLocation, location.distance(from: last) > 80 {
      updateRollingGeofence(at: location)
    } else if lastKnownLocation == nil {
      updateRollingGeofence(at: location)
    }
    lastKnownLocation = location

    // Reset crash counter periodically (not every write)
    if pointCount > 0 && pointCount % 10 == 0 {
      UserDefaults.standard.set(0, forKey: kCrashCountKey)
    }
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isCollecting, region.identifier == kRegionId else { return }
    logEvent("GEOFENCE_EXIT")
    locationManager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    guard isCollecting else { return }
    logEvent("VISIT_DETECTED")
    locationManager.startUpdatingLocation()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    logEvent("GPS_ERROR(\(gpsErrorCount)): \(error.localizedDescription)")
    guard isCollecting, !isRestarting else { return }

    gpsErrorCount += 1
    // Give up after 5 consecutive errors (avoid infinite restart loop)
    guard gpsErrorCount < 5 else {
      logEvent("GPS_ERROR: giving up after \(gpsErrorCount) errors")
      return
    }

    isRestarting = true
    locationManager.stopUpdatingLocation()
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self = self, self.isCollecting else { return }
      self.isRestarting = false
      self.locationManager.startUpdatingLocation()
    }
  }

  // =====================
  // File writing — OutputStream only (no FileHandle, no NSException)
  // =====================

  private func writePoint(location: CLLocation, now: Date) {
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

    guard let data = line.data(using: .utf8) else { return }

    if safeFileWrite(data) {
      pointCount += 1
    } else {
      logEvent("FILE_WRITE_FAILED")
    }

    // Flutter events only when active
    if UIApplication.shared.applicationState == .active {
      let eventData: [String: Any] = [
        "latitude": location.coordinate.latitude,
        "longitude": location.coordinate.longitude,
        "accuracy": location.horizontalAccuracy,
        "speed": max(0, location.speed),
        "altitude": location.altitude,
        "heading": max(0, location.course),
        "timestamp": now.timeIntervalSince1970 * 1000,
      ]
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(eventData)
      }
    }

    // Log only in foreground (NSLog in background wastes CPU/IO)
    if UIApplication.shared.applicationState == .active {
      NSLog("[ZairnLocation] #%d %.4f,%.4f ±%.0fm", pointCount,
            location.coordinate.latitude, location.coordinate.longitude,
            location.horizontalAccuracy)
    }
  }

  private func safeFileWrite(_ data: Data) -> Bool {
    guard let stream = OutputStream(url: traceFilePath, append: true) else { return false }
    stream.open()
    defer { stream.close() }
    return data.withUnsafeBytes { ptr -> Bool in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
      return stream.write(base, maxLength: data.count) > 0
    }
  }

  // =====================
  // Crash & event logging
  // =====================

  private func installCrashLogger() {
    if FileManager.default.fileExists(atPath: crashLogFilePath.path) {
      if let prev = try? String(contentsOf: crashLogFilePath, encoding: .utf8), !prev.isEmpty {
        NSLog("[ZairnCrashLog] PREVIOUS:\n%@", prev.suffix(2000))
      }
    }

    NSSetUncaughtExceptionHandler { exception in
      let msg = "UNCAUGHT: \(exception.name.rawValue): \(exception.reason ?? "?") | \(exception.callStackSymbols.prefix(5).joined(separator: "\n"))"
      AppDelegate.writeToLog(msg)
    }
  }

  func logEvent(_ msg: String) {
    let ts = AppDelegate.isoFormatter.string(from: Date())
    let line = "[\(ts)] \(msg)"
    // NSLog only in foreground (background NSLog wastes resources)
    if UIApplication.shared.applicationState == .active {
      NSLog("[ZairnLocation] %@", msg)
    }
    AppDelegate.writeToLog(line)
  }

  private static func writeToLog(_ msg: String) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = docs.appendingPathComponent("zairn-crash-log.txt")
    guard let data = (msg + "\n").data(using: .utf8) else { return }

    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: data)
      return
    }
    guard let stream = OutputStream(url: url, append: true) else { return }
    stream.open()
    data.withUnsafeBytes { ptr in
      guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      stream.write(base, maxLength: data.count)
    }
    stream.close()
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
