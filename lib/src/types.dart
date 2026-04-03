// Type definitions for the Zairn SDK.
// Mirrors the TypeScript @zairn/sdk types.

/// Share level between users.
enum ShareLevel { none, current, history }

/// Motion type detected from device sensors.
enum MotionType { stationary, walking, running, cycling, driving, transit, unknown }

/// Configuration for creating the SDK instance.
class ZairnConfig {
  final String supabaseUrl;
  final String supabaseAnonKey;

  /// Suppress the Realtime RLS startup warning.
  /// Set to true after confirming RLS is enabled in Supabase Dashboard.
  final bool suppressRealtimeRlsWarning;

  const ZairnConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.suppressRealtimeRlsWarning = false,
  });
}

/// Current location of a user.
class LocationCurrent {
  final String userId;
  final double lat;
  final double lon;
  final double? accuracy;
  final DateTime updatedAt;
  final int? batteryLevel;
  final bool? isCharging;
  final DateTime? locationSince;
  final double? speed;
  final double? heading;
  final double? altitude;
  final MotionType motion;

  const LocationCurrent({
    required this.userId,
    required this.lat,
    required this.lon,
    this.accuracy,
    required this.updatedAt,
    this.batteryLevel,
    this.isCharging,
    this.locationSince,
    this.speed,
    this.heading,
    this.altitude,
    this.motion = MotionType.unknown,
  });

  factory LocationCurrent.fromJson(Map<String, dynamic> json) {
    return LocationCurrent(
      userId: json['user_id'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      batteryLevel: json['battery_level'] as int?,
      isCharging: json['is_charging'] as bool?,
      locationSince: json['location_since'] != null
          ? DateTime.parse(json['location_since'] as String)
          : null,
      speed: (json['speed'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      motion: MotionType.values.firstWhere(
        (e) => e.name == json['motion'],
        orElse: () => MotionType.unknown,
      ),
    );
  }
}

/// Location update to send.
class LocationUpdate {
  final double lat;
  final double lon;
  final double? accuracy;
  final int? batteryLevel;
  final bool? isCharging;
  final double? speed;
  final double? heading;
  final double? altitude;
  final MotionType? motion;

  const LocationUpdate({
    required this.lat,
    required this.lon,
    this.accuracy,
    this.batteryLevel,
    this.isCharging,
    this.speed,
    this.heading,
    this.altitude,
    this.motion,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        if (accuracy != null) 'accuracy': accuracy,
        if (batteryLevel != null) 'battery_level': batteryLevel,
        if (isCharging != null) 'is_charging': isCharging,
        if (speed != null) 'speed': speed,
        if (heading != null) 'heading': heading,
        if (altitude != null) 'altitude': altitude,
        if (motion != null) 'motion': motion!.name,
      };
}

/// Location history entry.
class LocationHistory {
  final int id;
  final String userId;
  final double lat;
  final double lon;
  final double? accuracy;
  final DateTime recordedAt;

  const LocationHistory({
    required this.id,
    required this.userId,
    required this.lat,
    required this.lon,
    this.accuracy,
    required this.recordedAt,
  });

  factory LocationHistory.fromJson(Map<String, dynamic> json) {
    return LocationHistory(
      id: json['id'] as int,
      userId: json['user_id'] as String,
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      recordedAt: DateTime.parse(json['recorded_at'] as String),
    );
  }
}

/// Friend request.
class FriendRequest {
  final int id;
  final String fromUserId;
  final String toUserId;
  final String status;
  final DateTime createdAt;

  const FriendRequest({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.status,
    required this.createdAt,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) {
    return FriendRequest(
      id: json['id'] as int,
      fromUserId: json['from_user_id'] as String,
      toUserId: json['to_user_id'] as String,
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// User profile.
class Profile {
  final String userId;
  final String? username;
  final String? displayName;
  final String? avatarUrl;
  final String? statusEmoji;
  final String? statusText;

  const Profile({
    required this.userId,
    this.username,
    this.displayName,
    this.avatarUrl,
    this.statusEmoji,
    this.statusText,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      userId: json['user_id'] as String,
      username: json['username'] as String?,
      displayName: json['display_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      statusEmoji: json['status_emoji'] as String?,
      statusText: json['status_text'] as String?,
    );
  }
}

/// Sensitive place for privacy zone configuration.
class SensitivePlace {
  final String id;
  final String label;
  final double lat;
  final double lon;
  final double radiusM;
  final double bufferRadiusM;

  const SensitivePlace({
    required this.id,
    required this.label,
    required this.lat,
    required this.lon,
    this.radiusM = 200,
    this.bufferRadiusM = 1000,
  });
}

/// Result of privacy-processed location.
sealed class LocationState {}

class PreciseLocation extends LocationState {
  final double lat;
  final double lon;
  PreciseLocation({required this.lat, required this.lon});
}

class CoarseLocation extends LocationState {
  final double lat;
  final double lon;
  final String cellId;
  final double gridSizeM;
  CoarseLocation({
    required this.lat,
    required this.lon,
    required this.cellId,
    required this.gridSizeM,
  });
}

class StateOnly extends LocationState {
  final String label;
  StateOnly({required this.label});
}

class ProximityBucket extends LocationState {
  final String bucket;
  ProximityBucket({required this.bucket});
}

class Suppressed extends LocationState {
  final String reason;
  Suppressed({required this.reason});
}
