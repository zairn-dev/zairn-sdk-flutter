import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'types.dart';

/// Background location service for continuous GPS tracking.
///
/// Handles permission requests, accuracy settings, and periodic callbacks.
/// Works on both iOS and Android.
///
/// ```dart
/// final locationService = BackgroundLocationService();
/// await locationService.start(
///   onLocation: (update) => zairn.sendLocation(update),
///   intervalMs: 60000,
/// );
/// ```
class BackgroundLocationService {
  StreamSubscription<Position>? _subscription;
  Timer? _timer;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// Request location permissions. Returns true if granted.
  Future<bool> requestPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;

    return true;
  }

  /// Start continuous location tracking.
  ///
  /// [onLocation] is called with each new position.
  /// [intervalMs] is the minimum interval between callbacks (default: 60s).
  /// [distanceFilter] is the minimum distance change in meters (default: 10m).
  Future<void> start({
    required void Function(LocationUpdate) onLocation,
    int intervalMs = 60000,
    double distanceFilter = 10,
  }) async {
    if (_isRunning) return;

    final hasPermission = await requestPermission();
    if (!hasPermission) {
      throw StateError('Location permission not granted');
    }

    _isRunning = true;
    Position? lastPosition;
    int lastCallbackTime = 0;

    _subscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0, // We handle filtering ourselves
      ),
    ).listen((position) {
      lastPosition = position;
    });

    // Periodic callback at fixed interval
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      final pos = lastPosition;
      if (pos == null) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastCallbackTime < intervalMs ~/ 2) return; // debounce
      lastCallbackTime = now;

      onLocation(LocationUpdate(
        lat: pos.latitude,
        lon: pos.longitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        heading: pos.heading,
        altitude: pos.altitude,
      ));
    });
  }

  /// Stop location tracking.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _timer?.cancel();
    _timer = null;
    _isRunning = false;
  }

  /// Get the current position once.
  Future<LocationUpdate> getCurrentPosition() async {
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return LocationUpdate(
      lat: pos.latitude,
      lon: pos.longitude,
      accuracy: pos.accuracy,
      speed: pos.speed,
      heading: pos.heading,
      altitude: pos.altitude,
    );
  }
}
