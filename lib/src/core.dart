import 'package:supabase_flutter/supabase_flutter.dart';
import 'types.dart';
import 'privacy_location.dart';

/// Main SDK factory. Creates a Zairn location sharing instance.
///
/// ```dart
/// final zairn = await ZairnSdk.create(
///   config: ZairnConfig(supabaseUrl: '...', supabaseAnonKey: '...'),
/// );
/// await zairn.sendLocation(LocationUpdate(lat: 35.68, lon: 139.76));
/// ```
class ZairnSdk {
  final SupabaseClient _supabase;
  final ZairnConfig _config;

  ZairnSdk._(this._supabase, this._config) {
    if (!_config.suppressRealtimeRlsWarning) {
      // ignore: avoid_print
      print(
        '[zairn_sdk] IMPORTANT: Ensure Realtime RLS is enabled in Supabase Dashboard '
        '(Database → Replication → enable RLS for locations_current, friend_requests, messages). '
        'Set suppressRealtimeRlsWarning: true after confirming.',
      );
    }
  }

  /// Create and initialize the SDK.
  static Future<ZairnSdk> create({required ZairnConfig config}) async {
    await Supabase.initialize(
      url: config.supabaseUrl,
      anonKey: config.supabaseAnonKey,
    );
    final supabase = Supabase.instance.client;
    return ZairnSdk._(supabase, config);
  }

  /// Create from an existing Supabase client (for testing or custom setup).
  factory ZairnSdk.fromClient(SupabaseClient client, ZairnConfig config) {
    return ZairnSdk._(client, config);
  }

  // =====================
  // Auth
  // =====================

  Future<String> _getUserId() async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw StateError('Not authenticated');
    return user.id;
  }

  /// Get the current authenticated user ID.
  String? get currentUserId => _supabase.auth.currentUser?.id;

  /// Sign in with email and password.
  Future<void> signIn(String email, String password) async {
    await _supabase.auth.signInWithPassword(email: email, password: password);
  }

  /// Sign up with email and password.
  Future<void> signUp(String email, String password) async {
    await _supabase.auth.signUp(email: email, password: password);
  }

  /// Sign out.
  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  // =====================
  // Location
  // =====================

  /// Send the user's current location.
  Future<void> sendLocation(LocationUpdate update) async {
    final userId = await _getUserId();

    if (!update.lat.isFinite || update.lat < -90 || update.lat > 90) {
      throw ArgumentError('Invalid latitude: ${update.lat}');
    }
    if (!update.lon.isFinite || update.lon < -180 || update.lon > 180) {
      throw ArgumentError('Invalid longitude: ${update.lon}');
    }

    // Check ghost mode
    final settings = await getSettings();
    if (settings?['ghost_mode'] == true) {
      final ghostUntil = settings?['ghost_until'] as String?;
      if (ghostUntil == null || DateTime.parse(ghostUntil).isAfter(DateTime.now())) {
        return; // Ghost mode active
      }
    }

    // Compute location_since (stayed in same area?)
    final current = await _supabase
        .from('locations_current')
        .select('lat, lon, location_since')
        .eq('user_id', userId)
        .maybeSingle();

    String locationSince = DateTime.now().toIso8601String();
    if (current != null) {
      final distance = haversine(
        (current['lat'] as num).toDouble(),
        (current['lon'] as num).toDouble(),
        update.lat,
        update.lon,
      );
      if (distance < 50 && current['location_since'] != null) {
        locationSince = current['location_since'] as String;
      }
    }

    await _supabase.from('locations_current').upsert({
      'user_id': userId,
      ...update.toJson(),
      'location_since': locationSince,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Get locations of friends visible to the current user.
  Future<List<LocationCurrent>> getFriendsLocations({int limit = 500}) async {
    final response = await _supabase
        .from('locations_current')
        .select()
        .limit(limit);
    return (response as List)
        .map((e) => LocationCurrent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get location history for a user.
  Future<List<LocationHistory>> getLocationHistory(
    String userId, {
    int limit = 500,
    int offset = 0,
    DateTime? since,
  }) async {
    PostgrestFilterBuilder query = _supabase
        .from('locations_history')
        .select()
        .eq('user_id', userId);

    if (since != null) {
      query = query.gte('recorded_at', since.toIso8601String());
    }

    final response = await query
        .order('recorded_at', ascending: false)
        .range(offset, offset + limit - 1);
    return (response as List)
        .map((e) => LocationHistory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // =====================
  // Friends
  // =====================

  /// Send a friend request.
  Future<void> sendFriendRequest(String toUserId) async {
    final userId = await _getUserId();
    await _supabase.from('friend_requests').insert({
      'from_user_id': userId,
      'to_user_id': toUserId,
    });
  }

  /// Accept a friend request.
  Future<void> acceptFriendRequest(int requestId) async {
    await _supabase
        .from('friend_requests')
        .update({'status': 'accepted', 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', requestId);
  }

  /// Get list of accepted friends.
  Future<List<FriendRequest>> getFriends() async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('friend_requests')
        .select()
        .eq('status', 'accepted')
        .or('from_user_id.eq.$userId,to_user_id.eq.$userId');
    return (response as List)
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Remove a friend.
  Future<void> removeFriend(String friendId) async {
    final userId = await _getUserId();
    await _supabase
        .from('friend_requests')
        .delete()
        .eq('status', 'accepted')
        .or('and(from_user_id.eq.$userId,to_user_id.eq.$friendId),and(from_user_id.eq.$friendId,to_user_id.eq.$userId)');
  }

  // =====================
  // Profile
  // =====================

  /// Get a user's profile.
  Future<Profile?> getProfile(String userId) async {
    final response = await _supabase
        .from('profiles')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return response != null ? Profile.fromJson(response) : null;
  }

  /// Update the current user's profile.
  Future<void> updateProfile({String? displayName, String? statusEmoji, String? statusText}) async {
    final userId = await _getUserId();
    await _supabase.from('profiles').upsert({
      'user_id': userId,
      if (displayName != null) 'display_name': displayName,
      if (statusEmoji != null) 'status_emoji': statusEmoji,
      if (statusText != null) 'status_text': statusText,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  // =====================
  // Settings
  // =====================

  /// Get current user settings.
  Future<Map<String, dynamic>?> getSettings() async {
    final userId = await _getUserId();
    return await _supabase
        .from('user_settings')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
  }

  /// Enable ghost mode.
  Future<void> enableGhostMode({Duration? duration}) async {
    final userId = await _getUserId();
    final ghostUntil = duration != null
        ? DateTime.now().add(duration).toIso8601String()
        : null;
    await _supabase.from('user_settings').upsert({
      'user_id': userId,
      'ghost_mode': true,
      'ghost_until': ghostUntil,
    });
  }

  /// Disable ghost mode.
  Future<void> disableGhostMode() async {
    final userId = await _getUserId();
    await _supabase.from('user_settings').upsert({
      'user_id': userId,
      'ghost_mode': false,
      'ghost_until': null,
    });
  }

  // =====================
  // Realtime
  // =====================

  /// Subscribe to friend location updates.
  RealtimeChannel subscribeLocations(
    void Function(LocationCurrent) onUpdate, {
    void Function(String status, Object? error)? onError,
  }) {
    return _supabase
        .channel('locations')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'locations_current',
          callback: (payload) {
            if (payload.newRecord.isNotEmpty) {
              onUpdate(LocationCurrent.fromJson(payload.newRecord));
            }
          },
        )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        onError?.call(status.name, error);
      }
    });
  }

  /// Subscribe to friend request changes.
  RealtimeChannel subscribeFriendRequests(
    void Function(FriendRequest) onUpdate, {
    void Function(String status, Object? error)? onError,
  }) {
    return _supabase
        .channel('friend_requests')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'friend_requests',
          callback: (payload) {
            if (payload.newRecord.isNotEmpty) {
              onUpdate(FriendRequest.fromJson(payload.newRecord));
            }
          },
        )
        .subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        onError?.call(status.name, error);
      }
    });
  }

  // =====================
  // Utilities
  // =====================

  /// Calculate distance between two points in meters.
  static double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    return haversine(lat1, lon1, lat2, lon2);
  }
}
