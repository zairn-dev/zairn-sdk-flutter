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
  // Share Rules
  // =====================

  /// Allow a user to see your location.
  Future<void> allow(String viewerId, {ShareLevel level = ShareLevel.current}) async {
    final userId = await _getUserId();
    await _supabase.from('share_rules').upsert({
      'owner_id': userId,
      'viewer_id': viewerId,
      'level': level.name,
    });
  }

  /// Revoke location sharing with a user.
  Future<void> revoke(String viewerId) async {
    final userId = await _getUserId();
    await _supabase.from('share_rules')
        .delete()
        .eq('owner_id', userId)
        .eq('viewer_id', viewerId);
  }

  /// Set share expiry for a viewer.
  Future<void> setShareExpiry(String viewerId, DateTime expiresAt) async {
    final userId = await _getUserId();
    await _supabase.from('share_rules')
        .update({'expires_at': expiresAt.toIso8601String()})
        .eq('owner_id', userId)
        .eq('viewer_id', viewerId);
  }

  // =====================
  // Groups
  // =====================

  /// Create a group.
  Future<Map<String, dynamic>> createGroup(String name, {String? description}) async {
    final userId = await _getUserId();
    final inviteCode = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final response = await _supabase.from('groups').insert({
      'name': name,
      'description': description,
      'created_by': userId,
      'invite_code': inviteCode,
    }).select().single();
    // Auto-join as owner
    await _supabase.from('group_members').insert({
      'group_id': response['id'],
      'user_id': userId,
      'role': 'owner',
    });
    return response;
  }

  /// Get groups the current user belongs to.
  Future<List<Map<String, dynamic>>> getGroups() async {
    final userId = await _getUserId();
    final memberships = await _supabase
        .from('group_members')
        .select('group_id')
        .eq('user_id', userId);
    if ((memberships as List).isEmpty) return [];
    final groupIds = memberships.map((m) => m['group_id']).toList();
    final response = await _supabase
        .from('groups')
        .select()
        .inFilter('id', groupIds);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Join a group by invite code.
  Future<Map<String, dynamic>> joinGroup(String inviteCode) async {
    final userId = await _getUserId();
    final group = await _supabase
        .from('groups')
        .select()
        .eq('invite_code', inviteCode)
        .single();
    await _supabase.from('group_members').insert({
      'group_id': group['id'],
      'user_id': userId,
      'role': 'member',
    });
    return group;
  }

  /// Leave a group.
  Future<void> leaveGroup(String groupId) async {
    final userId = await _getUserId();
    await _supabase.from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', userId);
  }

  // =====================
  // Chat
  // =====================

  /// Get or create a direct chat room with another user.
  Future<Map<String, dynamic>> getOrCreateDirectChat(String otherUserId) async {
    final userId = await _getUserId();
    // Check existing
    final existing = await _supabase
        .from('chat_rooms')
        .select('*, chat_room_members!inner(*)')
        .eq('type', 'direct')
        .eq('chat_room_members.user_id', userId);

    for (final room in existing as List) {
      final members = await _supabase
          .from('chat_room_members')
          .select('user_id')
          .eq('room_id', room['id']);
      final memberIds = (members as List).map((m) => m['user_id']).toSet();
      if (memberIds.contains(otherUserId) && memberIds.length == 2) {
        return room;
      }
    }

    // Create new
    final room = await _supabase.from('chat_rooms')
        .insert({'type': 'direct', 'created_by': userId})
        .select().single();
    await _supabase.from('chat_room_members').insert([
      {'room_id': room['id'], 'user_id': userId},
      {'room_id': room['id'], 'user_id': otherUserId},
    ]);
    return room;
  }

  /// Send a message to a chat room.
  Future<Map<String, dynamic>> sendMessage(String roomId, String content, {String type = 'text'}) async {
    final userId = await _getUserId();
    return await _supabase.from('messages').insert({
      'room_id': roomId,
      'sender_id': userId,
      'content': content,
      'type': type,
    }).select().single();
  }

  /// Get messages in a chat room.
  Future<List<Map<String, dynamic>>> getMessages(String roomId, {int limit = 50, int offset = 0}) async {
    final response = await _supabase
        .from('messages')
        .select()
        .eq('room_id', roomId)
        .order('created_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Subscribe to new messages in a room.
  RealtimeChannel subscribeMessages(
    String roomId,
    void Function(Map<String, dynamic>) onMessage, {
    void Function(String, Object?)? onError,
  }) {
    return _supabase
        .channel('messages:$roomId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'room_id',
            value: roomId,
          ),
          callback: (payload) {
            if (payload.newRecord.isNotEmpty) {
              onMessage(payload.newRecord);
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
  // Reactions
  // =====================

  /// Send an emoji reaction to a friend.
  Future<Map<String, dynamic>> sendReaction(String toUserId, String emoji, {String? message}) async {
    final userId = await _getUserId();
    return await _supabase.from('location_reactions').insert({
      'from_user_id': userId,
      'to_user_id': toUserId,
      'emoji': emoji,
      if (message != null) 'message': message,
    }).select().single();
  }

  /// Get received reactions.
  Future<List<Map<String, dynamic>>> getReceivedReactions({int limit = 20, DateTime? since}) async {
    final userId = await _getUserId();
    var query = _supabase
        .from('location_reactions')
        .select()
        .eq('to_user_id', userId);
    if (since != null) {
      query = query.gte('created_at', since.toIso8601String());
    }
    final response = await query.order('created_at', ascending: false).limit(limit);
    return List<Map<String, dynamic>>.from(response);
  }

  // =====================
  // Bump Detection
  // =====================

  /// Find nearby friends within radius.
  Future<List<Map<String, dynamic>>> findNearbyFriends(double lat, double lon, {double radiusM = 500}) async {
    final friends = await getFriendsLocations();
    return friends
        .where((f) => haversine(lat, lon, f.lat, f.lon) <= radiusM)
        .map((f) => {
              'user_id': f.userId,
              'lat': f.lat,
              'lon': f.lon,
              'distance_meters': haversine(lat, lon, f.lat, f.lon).round(),
            })
        .toList()
      ..sort((a, b) => (a['distance_meters'] as int).compareTo(b['distance_meters'] as int));
  }

  /// Record a bump event with a nearby user.
  Future<Map<String, dynamic>> recordBump(String nearbyUserId, double distance, double lat, double lon) async {
    final userId = await _getUserId();
    return await _supabase.from('bump_events').insert({
      'user_id': userId,
      'bumped_user_id': nearbyUserId,
      'distance_meters': distance.round(),
      'lat': lat,
      'lon': lon,
    }).select().single();
  }

  /// Get bump history.
  Future<List<Map<String, dynamic>>> getBumpHistory({int limit = 20}) async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('bump_events')
        .select()
        .or('user_id.eq.$userId,bumped_user_id.eq.$userId')
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(response);
  }

  // =====================
  // Favorite Places
  // =====================

  /// Add a favorite place.
  Future<Map<String, dynamic>> addFavoritePlace({
    required String label,
    required double lat,
    required double lon,
    double radiusM = 100,
    String? name,
  }) async {
    final userId = await _getUserId();
    return await _supabase.from('favorite_places').insert({
      'user_id': userId,
      'label': label,
      'lat': lat,
      'lon': lon,
      'radius_meters': radiusM,
      if (name != null) 'name': name,
    }).select().single();
  }

  /// Get favorite places.
  Future<List<Map<String, dynamic>>> getFavoritePlaces({String? userId}) async {
    final uid = userId ?? await _getUserId();
    final response = await _supabase
        .from('favorite_places')
        .select()
        .eq('user_id', uid);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Delete a favorite place.
  Future<void> deleteFavoritePlace(String placeId) async {
    await _supabase.from('favorite_places').delete().eq('id', placeId);
  }

  // =====================
  // Block / Unblock
  // =====================

  /// Block a user.
  Future<void> blockUser(String targetUserId) async {
    final userId = await _getUserId();
    await _supabase.from('blocked_users').upsert({
      'user_id': userId,
      'blocked_user_id': targetUserId,
    });
  }

  /// Unblock a user.
  Future<void> unblockUser(String targetUserId) async {
    final userId = await _getUserId();
    await _supabase.from('blocked_users')
        .delete()
        .eq('user_id', userId)
        .eq('blocked_user_id', targetUserId);
  }

  /// Get list of blocked user IDs.
  Future<List<String>> getBlockedUsers() async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('blocked_users')
        .select('blocked_user_id')
        .eq('user_id', userId);
    return (response as List).map((r) => r['blocked_user_id'] as String).toList();
  }

  // =====================
  // Status
  // =====================

  /// Set status emoji and text.
  Future<void> setStatus(String emoji, {String? text, int? durationMinutes}) async {
    final userId = await _getUserId();
    await _supabase.from('profiles').upsert({
      'user_id': userId,
      'status_emoji': emoji,
      if (text != null) 'status_text': text,
      if (durationMinutes != null)
        'status_expires_at': DateTime.now().add(Duration(minutes: durationMinutes)).toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Clear status.
  Future<void> clearStatus() async {
    final userId = await _getUserId();
    await _supabase.from('profiles').update({
      'status_emoji': null,
      'status_text': null,
      'status_expires_at': null,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('user_id', userId);
  }

  // =====================
  // Search
  // =====================

  /// Search user profiles by username or display name.
  Future<List<Profile>> searchProfiles(String query) async {
    final response = await _supabase
        .from('profiles')
        .select()
        .or('username.ilike.%$query%,display_name.ilike.%$query%')
        .limit(20);
    return (response as List)
        .map((e) => Profile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // =====================
  // Friend Requests (extended)
  // =====================

  /// Get pending friend requests received.
  Future<List<FriendRequest>> getPendingRequests() async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('friend_requests')
        .select()
        .eq('to_user_id', userId)
        .eq('status', 'pending');
    return (response as List)
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get sent friend requests.
  Future<List<FriendRequest>> getSentRequests() async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('friend_requests')
        .select()
        .eq('from_user_id', userId)
        .eq('status', 'pending');
    return (response as List)
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Reject a friend request.
  Future<void> rejectFriendRequest(int requestId) async {
    await _supabase.from('friend_requests')
        .update({'status': 'rejected', 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', requestId);
  }

  /// Cancel a sent friend request.
  Future<void> cancelFriendRequest(int requestId) async {
    await _supabase.from('friend_requests')
        .delete()
        .eq('id', requestId)
        .eq('status', 'pending');
  }

  // =====================
  // Streaks
  // =====================

  /// Record an interaction with a friend (for streak tracking).
  Future<void> recordInteraction(String friendId) async {
    final userId = await _getUserId();
    await _supabase.rpc('record_friend_interaction', params: {
      'p_user_id': userId,
      'p_friend_id': friendId,
    });
  }

  /// Get streak with a specific friend.
  Future<Map<String, dynamic>?> getStreak(String friendId) async {
    final userId = await _getUserId();
    return await _supabase
        .from('friend_streaks')
        .select()
        .or('and(user_id.eq.$userId,friend_id.eq.$friendId),and(user_id.eq.$friendId,friend_id.eq.$userId)')
        .maybeSingle();
  }

  /// Get all active streaks.
  Future<List<Map<String, dynamic>>> getStreaks() async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('friend_streaks')
        .select()
        .or('user_id.eq.$userId,friend_id.eq.$userId')
        .gt('streak_count', 0)
        .order('streak_count', ascending: false);
    return List<Map<String, dynamic>>.from(response);
  }

  // =====================
  // Exploration (Visited Cells)
  // =====================

  /// Get visited cells for the current user.
  Future<List<Map<String, dynamic>>> getMyVisitedCells({int limit = 500, int offset = 0}) async {
    final userId = await _getUserId();
    final response = await _supabase
        .from('visited_cells')
        .select()
        .eq('user_id', userId)
        .order('last_visited_at', ascending: false)
        .range(offset, offset + limit - 1);
    return List<Map<String, dynamic>>.from(response);
  }

  /// Get exploration stats.
  Future<Map<String, dynamic>?> getMyExplorationStats() async {
    final userId = await _getUserId();
    return await _supabase
        .from('exploration_stats')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
  }

  // =====================
  // Trails
  // =====================

  /// Send location with trail recording.
  Future<void> sendLocationWithTrail(LocationUpdate update) async {
    await sendLocation(update);
    await saveLocationHistory(update.lat, update.lon, accuracy: update.accuracy);
  }

  /// Save a location history point.
  Future<void> saveLocationHistory(double lat, double lon, {double? accuracy}) async {
    final userId = await _getUserId();
    await _supabase.from('locations_history').insert({
      'user_id': userId,
      'lat': lat,
      'lon': lon,
      if (accuracy != null) 'accuracy': accuracy,
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
