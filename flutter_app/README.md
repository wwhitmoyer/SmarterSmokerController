# Smarter Grill Flutter app

Cross-platform migration of the Android BLE tester into a Wi-Fi-first grill controller. The original Java app remains in the repository as the protocol tester and reference implementation.

## Included

- Android and iOS-ready Dart application source
- MQTT connection to `iot.taylorgrill.com:1883`
- Saved `GRILL...` ID and automatic connection
- BLE-assisted Grill ID discovery
- Automatic status and temperature refresh every 10 seconds
- Power control with confirmation and optimistic OFF state
- Grill control and three locally stored software probe targets
- Shared binary protocol codec and tests
- Responsive Material 3 dashboard with advanced diagnostics collapsed by default

## Development

Android and iOS platform wrappers are generated. With Flutter installed, run from this directory:

```text
flutter pub get
flutter test
flutter analyze
flutter build apk --debug
```

Android and iOS BLE/network permissions are already configured. iOS compilation and signing require Xcode on macOS.

## Security note

The vendor broker uses unencrypted MQTT with credentials embedded in the vendor APK. Use this app only with a grill you own. Never enumerate broker topics or guess other device IDs.
