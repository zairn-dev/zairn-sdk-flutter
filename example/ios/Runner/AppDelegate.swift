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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let controller = window?.rootViewController as! FlutterViewController

    // Method channel for start/stop
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Event channel for location updates → Dart
    eventChannel = FlutterEventChannel(name: "zairn/ios_location_events", binaryMessenger: controller.binaryMessenger)
    eventChannel?.setStreamHandler(self)

    // Setup location manager
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.showsBackgroundLocationIndicator = true

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func startLocationUpdates() {
    locationManager.requestAlwaysAuthorization()

    // Open trace file for direct writing
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let filePath = docs.appendingPathComponent("dense-trace.jsonl")
    if !FileManager.default.fileExists(atPath: filePath.path) {
      FileManager.default.createFile(atPath: filePath.path, contents: nil)
    }
    traceFileHandle = try? FileHandle(forWritingTo: filePath)
    traceFileHandle?.seekToEndOfFile()

    // Count existing lines
    if let content = try? String(contentsOf: filePath, encoding: .utf8) {
      pointCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    locationManager.startUpdatingLocation()
    isCollecting = true
    lastRecordedTime = .distantPast
    NSLog("[ZairnLocation] Started. Existing points: %d", pointCount)
  }

  private func stopLocationUpdates() {
    locationManager.stopUpdatingLocation()
    traceFileHandle?.closeFile()
    traceFileHandle = nil
    isCollecting = false
    NSLog("[ZairnLocation] Stopped. Total points: %d", pointCount)
  }

  // CLLocationManagerDelegate — called by iOS even in background
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard isCollecting, let location = locations.last else { return }

    // Throttle: only emit if interval has passed
    let now = Date()
    if now.timeIntervalSince(lastRecordedTime) < intervalSeconds { return }
    lastRecordedTime = now

    let data: [String: Any] = [
      "latitude": location.coordinate.latitude,
      "longitude": location.coordinate.longitude,
      "accuracy": location.horizontalAccuracy,
      "speed": location.speed,
      "altitude": location.altitude,
      "heading": location.course,
      "timestamp": now.timeIntervalSince1970 * 1000,
    ]

    // Write directly to file ONLY — never touch Flutter in background
    if let jsonData = try? JSONSerialization.data(withJSONObject: data),
       let jsonString = String(data: jsonData, encoding: .utf8) {
      traceFileHandle?.write((jsonString + "\n").data(using: .utf8)!)
      traceFileHandle?.synchronizeFile()
      pointCount += 1
    }

    // Only send to Dart when app is in foreground
    if UIApplication.shared.applicationState == .active {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(data)
      }
    }

    NSLog("[ZairnLocation] #%d %.6f, %.6f (±%.0fm) bg=%@", pointCount, location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy, UIApplication.shared.applicationState == .active ? "NO" : "YES")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    NSLog("[ZairnLocation] Error: %@", error.localizedDescription)
  }
}

// FlutterStreamHandler for event channel
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
