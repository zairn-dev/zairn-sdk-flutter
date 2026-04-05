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

  // UserDefaults key for persisting collection state across kills
  private let kCollectingKey = "zairn_is_collecting"
  private let kIntervalKey = "zairn_interval_seconds"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as! FlutterViewController

    // Method channel
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

    // Event channel
    eventChannel = FlutterEventChannel(name: "zairn/ios_location_events", binaryMessenger: controller.binaryMessenger)
    eventChannel?.setStreamHandler(self)

    // Location manager setup (always, even before start)
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.showsBackgroundLocationIndicator = true
    locationManager.distanceFilter = 1.0

    // Auto-resume after iOS kill:
    // If app was launched by location event OR was previously collecting
    let wasCollecting = UserDefaults.standard.bool(forKey: kCollectingKey)
    let launchedByLocation = launchOptions?[.location] != nil

    if wasCollecting || launchedByLocation {
      intervalSeconds = UserDefaults.standard.double(forKey: kIntervalKey)
      if intervalSeconds < 10 { intervalSeconds = 60 }
      NSLog("[ZairnLocation] Auto-resuming: wasCollecting=%d launchedByLocation=%d interval=%.0f",
            wasCollecting, launchedByLocation, intervalSeconds)
      startLocationUpdates()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

    // Start both services
    locationManager.startUpdatingLocation()
    locationManager.startMonitoringSignificantLocationChanges()

    isCollecting = true
    lastRecordedTime = .distantPast

    // Persist state so we can resume after kill
    UserDefaults.standard.set(true, forKey: kCollectingKey)
    UserDefaults.standard.set(intervalSeconds, forKey: kIntervalKey)

    NSLog("[ZairnLocation] Started. Points: %d, interval: %.0fs", pointCount, intervalSeconds)
  }

  private func stopLocationUpdates() {
    locationManager.stopUpdatingLocation()
    locationManager.stopMonitoringSignificantLocationChanges()
    endBackgroundTask()
    traceFileHandle?.closeFile()
    traceFileHandle = nil
    isCollecting = false

    // Clear persisted state
    UserDefaults.standard.set(false, forKey: kCollectingKey)

    NSLog("[ZairnLocation] Stopped. Total: %d", pointCount)
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

  // No lifecycle restarts — CLLocationManager runs continuously

  // =====================
  // CLLocationManagerDelegate
  // =====================

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isCollecting, let location = locations.last else { return }
    guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else { return }
    guard -location.timestamp.timeIntervalSinceNow < 30 else { return }

    let now = Date()
    if now.timeIntervalSince(lastRecordedTime) < intervalSeconds { return }
    lastRecordedTime = now

    beginBackgroundTaskIfNeeded()

    let data: [String: Any] = [
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy,
      "speed": max(0, location.speed),
      "altitude": location.altitude,
      "heading": max(0, location.course),
      "timestamp": now.timeIntervalSince1970 * 1000,
    ]

    // Write to file (always)
    if let jsonData = try? JSONSerialization.data(withJSONObject: data),
       let jsonString = String(data: jsonData, encoding: .utf8) {
      traceFileHandle?.write((jsonString + "\n").data(using: .utf8)!)
      traceFileHandle?.synchronizeFile()
      pointCount += 1
    }

    // Send to Flutter only when active
    if UIApplication.shared.applicationState == .active {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(data)
      }
    }

    NSLog("[ZairnLocation] #%d %.6f,%.6f ±%.0fm bg=%@",
          pointCount,
          location.coordinate.latitude,
          location.coordinate.longitude,
          location.horizontalAccuracy,
          UIApplication.shared.applicationState != .active ? "YES" : "NO")

    endBackgroundTask()
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

  // Called when app is terminated but significant location change fires
  // iOS relaunches the app, and didFinishLaunchingWithOptions has .location key
  // → auto-resume handled there
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
