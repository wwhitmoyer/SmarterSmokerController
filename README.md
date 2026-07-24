# SmarterSmokerController

An experimental, Wi-Fi-first controller for compatible Smarter Grills/Taylor
pellet-grill controllers. The primary application is Flutter-based and supports
Android and iOS source builds. The original native Android BLE tester remains as
a protocol-testing reference.

## Features

- Automatic MQTT connection using a saved `GRILL...` device ID
- BLE-assisted Grill ID discovery
- BLE Wi-Fi provisioning for 2.4 GHz networks
- Automatic grill status and temperature refresh
- Grill power and temperature control
- Three food-probe readings with locally stored software alarm targets
- Shared binary protocol codec with tests
- Responsive Material 3 dashboard and diagnostics log

See [flutter_app/README.md](flutter_app/README.md) for build instructions and
[docs/wifi-mqtt-protocol.md](docs/wifi-mqtt-protocol.md) for the protocol notes.

## Project status

This is an independent reverse-engineering and interoperability project. It is
not affiliated with or endorsed by the grill manufacturer or app vendor. Use it
only with equipment you own.

## Security

The vendor system uses unencrypted MQTT and a shared credential embedded in the
vendor APK. Device IDs and cook data should be treated as sensitive. Do not scan,
enumerate, or attempt to access devices you do not own.
