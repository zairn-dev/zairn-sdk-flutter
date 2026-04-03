# Contributing to zairn_sdk

Thank you for your interest in contributing!

## Development Setup

```bash
git clone https://github.com/zairn-dev/zairn-sdk-flutter.git
cd zairn-sdk-flutter
flutter pub get
```

## Running Analysis

```bash
dart analyze lib/
```

## Running Tests

```bash
flutter test
```

## Code Style

- Follow [Effective Dart](https://dart.dev/effective-dart) guidelines
- Run `dart format .` before committing
- Ensure `dart analyze` reports no issues

## Commit Conventions

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation
- `refactor:` — Code restructuring
- `test:` — Tests
- `chore:` — Maintenance

## Architecture

The SDK mirrors the TypeScript [@zairn/sdk](https://github.com/zairn-dev/Zairn):

```
lib/
  zairn_sdk.dart          # Public API exports
  src/
    core.dart             # Main SDK class (ZairnSdk)
    types.dart            # Data types and enums
    privacy_location.dart # 6-layer privacy processor
    background_location.dart # GPS tracking service
```

## Related

- [Zairn](https://github.com/zairn-dev/Zairn) — Main project (TypeScript SDK, web app, database schema)
- [Zairn Database Schema](https://github.com/zairn-dev/Zairn/tree/main/database) — Required Supabase schema
