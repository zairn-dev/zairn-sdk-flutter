## 0.1.0

Initial release.

### Features
- **Core SDK**: Auth, location sharing, friends, groups, chat, reactions, bumps, ghost mode
- **Privacy Processor**: 6-layer defense (Planar Laplace, grid snap, zones, adaptive reporting, distance bucketing)
- **Background Location**: Continuous GPS tracking via geolocator with permission handling
- **Realtime**: Location, friend request, and message subscriptions with error callbacks
- **Favorites**: Home/work/school place management
- **Streaks**: Friend interaction tracking
- **Exploration**: Visited cell tracking and stats
- **Trails**: Location history recording

### Notes
- Full feature parity with TypeScript @zairn/sdk v0.7.0
- Requires Supabase project with Zairn schema
- Ensure Realtime RLS is enabled in Supabase Dashboard
