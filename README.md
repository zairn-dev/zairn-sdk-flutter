# zairn_sdk

Privacy-first location sharing SDK for Flutter. Port of [@zairn/sdk](https://github.com/zairn-dev/Zairn) (TypeScript).

## Features

| Feature | Description |
|---------|-------------|
| Real-time location | Share & subscribe to friend locations via Supabase Realtime |
| Privacy processing | 6-layer defense: Laplace noise, grid snap, zones, adaptive reporting |
| Friend management | Requests, accept/reject, block, remove |
| Ghost mode | Temporarily hide location with optional timer |
| Groups | Create, join via invite code, leave |
| Chat | Direct & group messaging with realtime subscription |
| Reactions | Emoji pokes to friends |
| Bump detection | Find nearby friends |
| Trails | Location history recording |
| Favorites | Mark home/work/school locations |
| Streaks | Track consecutive interaction days |
| Exploration | Visited cell tracking |
| Background GPS | Continuous tracking via geolocator |

## Quick Start

```dart
import 'package:zairn_sdk/zairn_sdk.dart';

// Initialize
final zairn = await ZairnSdk.create(
  config: ZairnConfig(
    supabaseUrl: 'https://your-project.supabase.co',
    supabaseAnonKey: 'your-anon-key',
    suppressRealtimeRlsWarning: true,
  ),
);

// Sign in
await zairn.signIn('user@example.com', 'password');

// Send location
await zairn.sendLocation(LocationUpdate(lat: 35.68, lon: 139.76, accuracy: 10));

// Get friends
final friends = await zairn.getFriendsLocations();

// Subscribe to realtime updates
zairn.subscribeLocations((location) {
  print('${location.userId} is at ${location.lat}, ${location.lon}');
});
```

## Privacy Processing

```dart
final privacy = createPrivacyProcessor(
  config: PrivacyConfig(gridSeed: zairn.currentUserId!),
  sensitivePlaces: [
    SensitivePlace(id: 'home', label: 'home', lat: 35.68, lon: 139.76),
  ],
);

// Process raw GPS → privacy-safe output
final state = privacy.process(rawLat, rawLon);
switch (state) {
  case CoarseLocation():
    shareWithFriends(state.lat, state.lon, state.cellId);
  case StateOnly():
    showStatus(state.label); // "At home"
  case Suppressed():
    break; // Don't share
  default:
    break;
}
```

## Background Location

```dart
final locationService = BackgroundLocationService();
await locationService.start(
  onLocation: (update) => zairn.sendLocation(update),
  intervalMs: 60000, // Every 1 minute
);
```

## Requirements

- Flutter >= 3.10
- Supabase project with [Zairn schema](https://github.com/zairn-dev/Zairn/tree/main/database)
- Enable Realtime RLS in Supabase Dashboard

## Related

- [Zairn](https://github.com/zairn-dev/Zairn) — TypeScript SDK, web app, and full platform
- [@zairn/geo-drop](https://github.com/zairn-dev/Zairn/tree/main/packages/geo-drop) — Encrypted geo-drops (TypeScript)

## License

MIT
