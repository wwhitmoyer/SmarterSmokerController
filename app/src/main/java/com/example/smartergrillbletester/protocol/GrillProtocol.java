package com.example.smartergrillbletester.protocol;

import java.util.Arrays;
import java.util.Locale;

/** Shared wire protocol used by both MQTT and BLE transports. */
public final class GrillProtocol {
    public static final byte[] QUERY_STATUS = frame(0x0B, 0x01);
    public static final byte[] QUERY_SET_TEMPERATURES = frame(0x0D, 0x01);
    public static final byte[] QUERY_ACTUAL_TEMPERATURES = frame(0x0E, 0x01);
    public static final byte[] QUERY_PID_FAN = frame(0x1F, 0x02);
    public static final byte[] QUERY_SHUTDOWN_TIMER = frame(0x27, 0x01);
    public static final byte[] QUERY_FIRMWARE = frame(0x5F, 0x01);

    private GrillProtocol() {}

    public static byte[] power(boolean on) { return frame(0x01, on ? 0x01 : 0x02); }
    public static byte[] units(boolean fahrenheit) { return frame(0x09, fahrenheit ? 0x01 : 0x02); }
    public static byte[] grillTemperature(int temperature) { return temperature(1, temperature); }

    public static byte[] probeTemperature(int probe, int temperature) {
        if (probe < 1 || probe > 6) throw new IllegalArgumentException("Probe must be 1 through 6");
        return temperature(probe + 1, temperature);
    }

    private static byte[] temperature(int target, int temperature) {
        if (temperature < 0 || temperature > 999) throw new IllegalArgumentException("Temperature must be 0 through 999");
        return new byte[] {(byte) 0xFA, 0x09, (byte) 0xFE, 0x05, (byte) target,
                (byte) (temperature / 100), (byte) ((temperature / 10) % 10),
                (byte) (temperature % 10), (byte) 0xFF};
    }

    private static byte[] frame(int command, int value) {
        return new byte[] {(byte) 0xFA, 0x06, (byte) 0xFE, (byte) command, (byte) value, (byte) 0xFF};
    }

    public static DecodedFrame decode(byte[] bytes) {
        if (bytes == null || bytes.length < 6 || unsigned(bytes[0]) != 0xFA || unsigned(bytes[bytes.length - 1]) != 0xFF)
            return DecodedFrame.unknown(bytes, "Invalid frame boundary");
        if (unsigned(bytes[1]) != bytes.length)
            return DecodedFrame.unknown(bytes, "Length byte does not match payload");
        int command = unsigned(bytes[3]);
        switch (command) {
            case 0x0B: return statusResponse(bytes, command);
            case 0x0D: return temperatureResponse(bytes, Type.SET_TEMPERATURES, command, "Set temperatures");
            case 0x0E: return temperatureResponse(bytes, Type.ACTUAL_TEMPERATURES, command, "Actual temperatures");
            case 0x1F: return new DecodedFrame(bytes, Type.PID_FAN, command, new int[0], null, "PID/fan parameters");
            case 0x27: return new DecodedFrame(bytes, Type.SHUTDOWN_TIMER, command, new int[0], null, "Shutdown timer");
            case 0x5F: return new DecodedFrame(bytes, Type.FIRMWARE, command, new int[0], null, "STM firmware");
            default: return DecodedFrame.unknown(bytes, String.format(Locale.US, "Unknown command FE%02X", command));
        }
    }

    private static DecodedFrame statusResponse(byte[] bytes, int command) {
        Boolean powerOn = null;
        // Decompiled vendor parser reads hex characters 10-11, which is byte offset 5.
        if (bytes.length > 5) {
            int power = unsigned(bytes[5]);
            if (power == 0x01) powerOn = true;
            if (power == 0x02) powerOn = false;
        }
        return new DecodedFrame(bytes, Type.STATUS, command, new int[0], powerOn,
                powerOn == null ? "Grill status (power unknown)" : "Grill power " + (powerOn ? "ON" : "OFF"));
    }

    private static DecodedFrame temperatureResponse(byte[] bytes, Type type, int command, String label) {
        // Observed FE0D/FE0E frames contain seven three-digit values: six probes then grill.
        if (bytes.length != 26) return new DecodedFrame(bytes, type, command, new int[0], null, label + " (unexpected length)");
        int[] values = new int[7];
        for (int i = 0; i < values.length; i++) values[i] = digits(bytes, 4 + (i * 3));
        return new DecodedFrame(bytes, type, command, values, null, label);
    }

    private static int digits(byte[] bytes, int offset) {
        int a = unsigned(bytes[offset]), b = unsigned(bytes[offset + 1]), c = unsigned(bytes[offset + 2]);
        if (a == 9 && b == 9 && c == 9) return -1;
        if (a > 9 || b > 9 || c > 9) return -2;
        return a * 100 + b * 10 + c;
    }

    private static int unsigned(byte value) { return value & 0xFF; }

    public static String toHex(byte[] bytes) {
        if (bytes == null) return "";
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(Locale.US, "%02X", unsigned(value)));
        return result.toString();
    }

    public static byte[] fromHex(String text) {
        String value = text == null ? "" : text.replaceAll("[^0-9A-Fa-f]", "");
        if (value.isEmpty() || value.length() % 2 != 0) throw new IllegalArgumentException("Hex must contain complete bytes");
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < value.length(); i += 2) bytes[i / 2] = (byte) Integer.parseInt(value.substring(i, i + 2), 16);
        return bytes;
    }

    public enum Type { STATUS, SET_TEMPERATURES, ACTUAL_TEMPERATURES, PID_FAN, SHUTDOWN_TIMER, FIRMWARE, UNKNOWN }

    public static final class DecodedFrame {
        public final byte[] raw;
        public final Type type;
        public final int command;
        public final int[] temperatures;
        public final Boolean powerOn;
        public final String description;

        private DecodedFrame(byte[] raw, Type type, int command, int[] temperatures, Boolean powerOn, String description) {
            this.raw = raw == null ? new byte[0] : Arrays.copyOf(raw, raw.length);
            this.type = type;
            this.command = command;
            this.temperatures = Arrays.copyOf(temperatures, temperatures.length);
            this.powerOn = powerOn;
            this.description = description;
        }

        private static DecodedFrame unknown(byte[] raw, String description) {
            return new DecodedFrame(raw, Type.UNKNOWN, -1, new int[0], null, description);
        }
    }
}
