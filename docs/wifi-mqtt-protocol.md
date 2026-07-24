# Smarter Grills Wi-Fi/MQTT protocol

This project treats MQTT over Wi-Fi as the primary transport. The existing BLE tester remains available as a fallback and as a way to capture unknown frames. Both transports carry the same raw binary frames.

## Transport

- Broker: `tcp://iot.taylorgrill.com:1883`
- Username: `Taylor`
- Password: `YKC6WLIFUZaBaMQU`
- App to device: `<deviceId>/app2dev`
- Device to app: `<deviceId>/dev2app`
- QoS: 2
- Retained publishes: yes (matching the decompiled app)
- Payload: raw bytes; no JSON or hex-text wrapper

The broker is unencrypted and the shared credential is embedded in the vendor APK. Treat the device ID and all cook data as sensitive. Do not enumerate or access devices you do not own.

## Frame shape

Known frames use `FA <length> FE <command> <data...> FF`. The second byte appears to be total frame length. Temperature digits are individual numeric nibbles stored as bytes (`02 02 05` means 225), not ASCII characters.

## Known commands

| Frame/prefix | Meaning |
| --- | --- |
| `FA06FE0101FF` | Power on |
| `FA06FE0102FF` | Power off |
| `FA06FE0901FF` | Fahrenheit |
| `FA06FE0902FF` | Celsius |
| `FA06FE0B01FF` | Query status |
| `FA06FE0D01FF` | Query set temperatures |
| `FA06FE0E01FF` | Query actual temperatures |
| `FA06FE1F02FF` | Query PID/fan parameters |
| `FA06FE2701FF` | Query shutdown timer |
| `FA06FE5F01FF` | Query STM firmware |
| `FA18FE0B...FF` | Status response |
| `FA1AFE0D...FF` | Set-temperature response |
| `FA1AFE0E...FF` | Actual-temperature response |
| `FA11FE1F...FF` | PID/fan response |
| `FA0CFE27...FF` | Shutdown-timer response |
| `FA17FE5F...FF` | Firmware response |

Set grill temperature: `FA 09 FE 05 01 H T O FF`.

Set probe temperature: `FA 09 FE 05 PP H T O FF`, where `PP` is `02` through `07` for probes 1 through 6.

## Wi-Fi provisioning

The vendor APK's current setup flow sends Wi-Fi credentials over BLE, not MQTT.
It connects to service `0000abf0-0000-1000-8000-00805f9b34fb`, writes to
characteristic `0000abf1-0000-1000-8000-00805f9b34fb`, and listens on
`0000abf2-0000-1000-8000-00805f9b34fb`.

The complete frame is:

```text
FA <one-byte total length> FB <SSID UTF-8> F1 <password UTF-8> FF
```

The frame is written in 20-byte BLE chunks with a 500 ms pause between chunks.
`FA05FC00FF` is the success response. The app does not retain or log the Wi-Fi
password. Initial setup cannot be performed over Wi-Fi because the grill is not
yet connected; no verified MQTT command for changing Wi-Fi credentials was found.

## Uncertainties

- FE0B field meanings beyond known high-level status are not fully verified.
- FE0D/FE0E carry six protocol slots followed by the grill value, based on the APK substring offsets. This controller exposes only three physical probes, so the application ignores slots 4–6.
- FE1F, FE27, and FE5F response bodies are identified but not fully decoded.
- No separate smoke command has been confirmed. Smoke behavior may be implicit in temperature mode or PID/fan parameters.
- Retained control messages are potentially risky. The implementation matches the vendor app, but this should be validated on the owner's device before broader use.
