# Smarter Smoker

An experimental, Wi-Fi-first controller application for compatible Smarter Grills/Taylor
pellet-smoker controllers. The Flutter application supports Android and iOS
source builds from a single project.

## Features

- Automatic MQTT connection using a saved `GRILL...` device ID
- BLE-assisted Grill ID discovery
- BLE Wi-Fi provisioning for 2.4 GHz networks
- Automatic grill status and temperature refresh
- Grill power and temperature control
- Three food-probe readings with locally stored software alarm targets
- Visual, audible, and haptic probe pre-alarms and target alarms
- Public lock-screen notifications for probe alerts on Android
- Smoker-ready sound and lock-screen notification at the chamber setpoint
- Shared binary protocol codec with tests
- Responsive Material 3 dashboard and diagnostics log

See [docs/wifi-mqtt-protocol.md](docs/wifi-mqtt-protocol.md) for the
reverse-engineered protocol notes.

## Screenshots

<p align="center">
  <img src="docs/screenshots/dashboard.png" width="31%" alt="Smarter Smoker dashboard">
  <img src="docs/screenshots/temperature-dialog.png" width="31%" alt="Grill temperature control">
  <img src="docs/screenshots/probe-alert.png" width="31%" alt="Probe target alarm and notification">
</p>

<p align="center">
  Dashboard &nbsp; • &nbsp; Temperature control &nbsp; • &nbsp; Probe alarm
</p>

## Development

From the repository root:

```text
flutter pub get
flutter test
flutter analyze
flutter run
```

Build an Android debug APK with:

```text
flutter build apk --debug
```

Android and iOS BLE/network permissions are configured. Building and signing
the iOS application requires Xcode on macOS.

## Project status

This is an independent reverse-engineering and interoperability project. It is
not affiliated with or endorsed by the grill manufacturer or app vendor. Use it
only with equipment you own. The project is in its final stages prior to release,
though its unlikely it will ever be uploaded to any app stores. I may add more 
features in the future but for now its been a fun project and does everything I
need it to do. If you find it usefull or feel the need to continue the project
please feel free to do so.

## Security

The vendor system uses unencrypted MQTT and a shared credential embedded in the
vendor APK. Device IDs and cook data should be treated as sensitive. Do not scan,
enumerate, or attempt to access devices you do not own.
