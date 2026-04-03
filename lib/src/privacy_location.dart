import 'dart:math';
import 'types.dart';

/// Privacy configuration.
class PrivacyConfig {
  final double baseEpsilon;
  final double gridSizeM;
  final String gridSeed;
  final double defaultZoneRadiusM;
  final double defaultBufferRadiusM;
  final int maxReportsPerHourMoving;
  final int maxReportsPerHourStationary;
  final Map<String, PrivacyZoneRule> zoneRules;

  const PrivacyConfig({
    this.baseEpsilon = 0.001386, // ln(2)/500
    this.gridSizeM = 500,
    required this.gridSeed,
    this.defaultZoneRadiusM = 200,
    this.defaultBufferRadiusM = 1000,
    this.maxReportsPerHourMoving = 12,
    this.maxReportsPerHourStationary = 2,
    this.zoneRules = const {
      'home': PrivacyZoneRule(coreMode: 'state-only', bufferNoiseMultiplier: 10, stateLabel: 'At home'),
      'work': PrivacyZoneRule(coreMode: 'state-only', bufferNoiseMultiplier: 10, stateLabel: 'At work'),
      'medical': PrivacyZoneRule(coreMode: 'suppress', bufferNoiseMultiplier: 20),
    },
  });
}

class PrivacyZoneRule {
  final String coreMode; // 'state-only' or 'suppress'
  final double bufferNoiseMultiplier;
  final String? stateLabel;

  const PrivacyZoneRule({
    required this.coreMode,
    required this.bufferNoiseMultiplier,
    this.stateLabel,
  });
}

/// Validate privacy configuration. Throws on invalid values.
void validatePrivacyConfig(PrivacyConfig config) {
  if (config.baseEpsilon <= 0) {
    throw RangeError('baseEpsilon must be positive (got ${config.baseEpsilon})');
  }
  if (config.gridSizeM <= 0) {
    throw RangeError('gridSizeM must be positive (got ${config.gridSizeM})');
  }
  if (config.gridSeed.isEmpty) {
    throw RangeError('gridSeed must be non-empty (per-user unique)');
  }
  if (config.defaultBufferRadiusM < config.defaultZoneRadiusM) {
    throw RangeError('defaultBufferRadiusM must be >= defaultZoneRadiusM');
  }
}

// ============================================================
// Layer 1: Planar Laplace
// ============================================================

final _rng = Random.secure();

double _lambertWm1(double x) {
  if (x >= 0 || x < -1 / e) return double.nan;
  double w = x < -0.3
      ? -1 - sqrt(2 * (1 + e * x))
      : log(-x) - log(-log(-x));
  for (int i = 0; i < 20; i++) {
    final ew = exp(w);
    final wew = w * ew;
    final f = wew - x;
    final fp = ew * (w + 1);
    final fpp = ew * (w + 2);
    final delta = f / (fp - (f * fpp) / (2 * fp));
    w -= delta;
    if (delta.abs() < 1e-12) break;
  }
  return w;
}

({double lat, double lon}) addPlanarLaplaceNoise(
  double lat,
  double lon,
  double epsilon,
) {
  final p = _rng.nextDouble();
  final w = _lambertWm1((p - 1) / e);
  final rMeters = -(1 / epsilon) * (w + 1);
  final theta = _rng.nextDouble() * 2 * pi;

  final dLat = (rMeters * cos(theta)) / 111320;
  final dLon = (rMeters * sin(theta)) / (111320 * cos(lat * pi / 180));

  return (lat: lat + dLat, lon: lon + dLon);
}

// ============================================================
// Layer 2: Grid Snap
// ============================================================

int _fnv1a(String str) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < str.length; i++) {
    hash ^= str.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

({double lat, double lon, String cellId}) gridSnap(
  double lat,
  double lon,
  double gridSizeM,
  String gridSeed,
) {
  final seedHash = _fnv1a(gridSeed);
  final offsetLat = ((seedHash & 0xFFFF) / 0xFFFF) * (gridSizeM / 111320);
  final offsetLon = (((seedHash >> 16) & 0xFFFF) / 0xFFFF) *
      (gridSizeM / (111320 * cos(lat * pi / 180)));

  final gridLat = gridSizeM / 111320;
  final gridLon = gridSizeM / (111320 * cos(lat * pi / 180));

  final cellRow = ((lat + offsetLat) / gridLat).floor();
  final cellCol = ((lon + offsetLon) / gridLon).floor();

  final snappedLat = (cellRow + 0.5) * gridLat - offsetLat;
  final snappedLon = (cellCol + 0.5) * gridLon - offsetLon;

  final cellId = '${(seedHash & 0xFF).toRadixString(16)}:$cellRow:$cellCol';
  return (lat: snappedLat, lon: snappedLon, cellId: cellId);
}

// ============================================================
// Layer 5: Adaptive Reporter
// ============================================================

class AdaptiveReporter {
  String? _lastReportedCell;
  int _lastReportTime = 0;
  int _stationaryCount = 0;
  final List<int> _reportTimestamps = [];
  final int maxMoving;
  final int maxStationary;

  AdaptiveReporter({this.maxMoving = 12, this.maxStationary = 2});

  bool shouldReport(String currentCellId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final oneHourAgo = now - 3600000;
    _reportTimestamps.removeWhere((t) => t <= oneHourAgo);

    final isMoving = currentCellId != _lastReportedCell;
    final maxPerHour = isMoving ? maxMoving : maxStationary;

    if (_reportTimestamps.length >= maxPerHour) return false;

    if (!isMoving) {
      _stationaryCount++;
      final minInterval = 5 * 60 * 1000;
      final backoff = minInterval * pow(2, min(_stationaryCount - 1, 6)).toInt();
      if (now - _lastReportTime < backoff) return false;
    } else {
      _stationaryCount = 0;
    }

    return true;
  }

  void record(String cellId) {
    _lastReportedCell = cellId;
    _lastReportTime = DateTime.now().millisecondsSinceEpoch;
    _reportTimestamps.add(_lastReportTime);
  }
}

// ============================================================
// Layer 6: Distance Bucketing
// ============================================================

String bucketizeDistance(double distanceM) {
  if (distanceM < 100) return 'nearby';
  if (distanceM < 500) return '<500m';
  if (distanceM < 1000) return '<1km';
  if (distanceM < 2000) return '1-2km';
  if (distanceM < 5000) return '2-5km';
  if (distanceM < 10000) return '5-10km';
  if (distanceM < 50000) return '10-50km';
  return '>50km';
}

// ============================================================
// Haversine
// ============================================================

double haversine(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371000.0;
  final dLat = (lat2 - lat1) * pi / 180;
  final dLon = (lon2 - lon1) * pi / 180;
  final a = min(
    1.0,
    pow(sin(dLat / 2), 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * pow(sin(dLon / 2), 2),
  );
  return R * 2 * atan2(sqrt(a), sqrt(1 - a));
}

// ============================================================
// Main Processor
// ============================================================

/// Create a privacy processor. Recommended entry point.
///
/// Validates config and manages AdaptiveReporter internally.
/// ```dart
/// final privacy = createPrivacyProcessor(
///   config: PrivacyConfig(gridSeed: currentUser.id),
///   sensitivePlaces: detectedPlaces,
/// );
/// final state = privacy.process(rawLat, rawLon);
/// ```
PrivacyProcessor createPrivacyProcessor({
  required PrivacyConfig config,
  List<SensitivePlace> sensitivePlaces = const [],
}) {
  validatePrivacyConfig(config);
  return PrivacyProcessor._(config, sensitivePlaces);
}

class PrivacyProcessor {
  final PrivacyConfig _config;
  List<SensitivePlace> _places;
  late final AdaptiveReporter _reporter;

  PrivacyProcessor._(this._config, this._places) {
    _reporter = AdaptiveReporter(
      maxMoving: _config.maxReportsPerHourMoving,
      maxStationary: _config.maxReportsPerHourStationary,
    );
  }

  void updateSensitivePlaces(List<SensitivePlace> places) {
    _places = places;
  }

  LocationState process(double rawLat, double rawLon, {({double lat, double lon})? viewerLocation}) {
    // Layer 4: Zone check
    for (final place in _places) {
      final dist = haversine(rawLat, rawLon, place.lat, place.lon);
      if (dist <= place.radiusM) {
        final rule = _config.zoneRules[place.label];
        if (rule?.coreMode == 'suppress') {
          return Suppressed(reason: 'privacy_zone');
        }
        return StateOnly(label: rule?.stateLabel ?? 'Nearby');
      }
      if (dist <= place.bufferRadiusM) {
        // Buffer zone: amplified noise
        final bufferEpsilon = _config.baseEpsilon /
            (_config.zoneRules[place.label]?.bufferNoiseMultiplier ?? 10);
        final noisy = addPlanarLaplaceNoise(rawLat, rawLon, bufferEpsilon);
        final snapped = gridSnap(noisy.lat, noisy.lon, _config.gridSizeM, _config.gridSeed);
        if (!_reporter.shouldReport(snapped.cellId)) {
          return Suppressed(reason: 'budget_exhausted');
        }
        _reporter.record(snapped.cellId);
        return CoarseLocation(
          lat: snapped.lat,
          lon: snapped.lon,
          cellId: snapped.cellId,
          gridSizeM: _config.gridSizeM,
        );
      }
    }

    // Layer 1 + 2: Noise + Grid snap
    final noisy = addPlanarLaplaceNoise(rawLat, rawLon, _config.baseEpsilon);
    final snapped = gridSnap(noisy.lat, noisy.lon, _config.gridSizeM, _config.gridSeed);

    // Layer 5: Adaptive reporting
    if (!_reporter.shouldReport(snapped.cellId)) {
      return Suppressed(reason: 'budget_exhausted');
    }
    _reporter.record(snapped.cellId);

    // Layer 6: Distance bucketing for distant viewers
    if (viewerLocation != null) {
      final dist = haversine(rawLat, rawLon, viewerLocation.lat, viewerLocation.lon);
      if (dist > 5000) {
        return ProximityBucket(bucket: bucketizeDistance(dist));
      }
    }

    return CoarseLocation(
      lat: snapped.lat,
      lon: snapped.lon,
      cellId: snapped.cellId,
      gridSizeM: _config.gridSizeM,
    );
  }
}
