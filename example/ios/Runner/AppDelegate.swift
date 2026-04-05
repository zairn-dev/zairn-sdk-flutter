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

    // Location manager setup
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.showsBackgroundLocationIndicator = true
    // Small nonzero filter: iOS keeps sending updates even when nearly stationary
    locationManager.distanceFilter = 1.0

    // If app was launched by significant location change, resume collecting
    if launchOptions?[.location] != nil {
      NSLog("[ZairnLocation] App launched by location event, resuming collection")
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

    // Start BOTH location services:
    // 1. Continuous updates (main GPS, may be throttled in background)
    locationManager.startUpdatingLocation()
    // 2. Significant location change (wake-up mechanism, survives app kill)
    locationManager.startMonitoringSignificantLocationChanges()

    isCollecting = true
    lastRecordedTime = .distantPast

    NSLog("[ZairnLocation] Started. Points: %d, interval: %.0fs", pointCount, intervalSeconds)
  }

  private func stopLocationUpdates() {
    locationManager.stopUpdatingLocation()
    locationManager.stopMonitoringSignificantLocationChanges()
    endBackgroundTask()
    traceFileHandle?.closeFile()
    traceFileHandle = nil
    isCollecting = false
    NSLog("[ZairnLocation] Stopped. Total: %d", pointCount)
  }

  // =====================
  // Background task management
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
  // Restarting on transitions causes Flutter engine crashes

  // =====================
  // CLLocationManagerDelegate
  // =====================

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isCollecting, let location = locations.last else { return }
    // Reject stale or inaccurate locations
    guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 100 else { return }
    let age = -location.timestamp.timeIntervalSinceNow
    guard age < 30 else { return } // Skip locations older than 30s

    // Throttle by interval
    let now = Date()
    if now.timeIntervalSince(lastRecordedTime) < intervalSeconds { return }
    lastRecordedTime = now

    // Extend background execution time
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

    // Write to file (always, regardless of app state)
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

    // End background task after write, then start new one for next update
    endBackgroundTask()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[ZairnLocation] Error: %@", error.localizedDescription)
    // On error, try restarting
    if isCollecting {
      locationManager.stopUpdatingLocation()
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        self?.locationManager.startUpdatingLocation()
      }
    }
  }

  // Significant location change (wake-up from kill)
  func locationManager(_ manager: CLLocationManager, didFinishDeferredUpdatesWithError error: Error?) {
    if let error = error {
      NSLog("[ZairnLocation] Deferred error: %@", error.localizedDescription)
    }
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
