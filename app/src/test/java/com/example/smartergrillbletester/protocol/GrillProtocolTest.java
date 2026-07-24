package com.example.smartergrillbletester.protocol;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class GrillProtocolTest {
    @Test public void knownQueriesMatchApk() {
        assertEquals("FA06FE0B01FF", GrillProtocol.toHex(GrillProtocol.QUERY_STATUS));
        assertEquals("FA06FE0D01FF", GrillProtocol.toHex(GrillProtocol.QUERY_SET_TEMPERATURES));
        assertEquals("FA06FE0E01FF", GrillProtocol.toHex(GrillProtocol.QUERY_ACTUAL_TEMPERATURES));
        assertEquals("FA06FE1F02FF", GrillProtocol.toHex(GrillProtocol.QUERY_PID_FAN));
        assertEquals("FA06FE2701FF", GrillProtocol.toHex(GrillProtocol.QUERY_SHUTDOWN_TIMER));
        assertEquals("FA06FE5F01FF", GrillProtocol.toHex(GrillProtocol.QUERY_FIRMWARE));
    }

    @Test public void buildersEncodeKnownCommands() {
        assertEquals("FA06FE0101FF", GrillProtocol.toHex(GrillProtocol.power(true)));
        assertEquals("FA06FE0102FF", GrillProtocol.toHex(GrillProtocol.power(false)));
        assertEquals("FA06FE0901FF", GrillProtocol.toHex(GrillProtocol.units(true)));
        assertEquals("FA09FE0501020205FF", GrillProtocol.toHex(GrillProtocol.grillTemperature(225)));
        assertEquals("FA09FE0502010605FF", GrillProtocol.toHex(GrillProtocol.probeTemperature(1, 165)));
    }

    @Test public void hexRoundTrips() {
        byte[] frame = GrillProtocol.grillTemperature(225);
        assertArrayEquals(frame, GrillProtocol.fromHex(GrillProtocol.toHex(frame)));
    }

    @Test public void decodesPowerStatus() {
        GrillProtocol.DecodedFrame on = GrillProtocol.decode(GrillProtocol.fromHex(
                "FA18FE0B00010000000000000000000000000000000000FF"));
        GrillProtocol.DecodedFrame off = GrillProtocol.decode(GrillProtocol.fromHex(
                "FA18FE0B00020000000000000000000000000000000000FF"));
        assertTrue(on.powerOn);
        assertFalse(off.powerOn);
    }

    @Test public void decodesObservedTemperatureLayout() {
        GrillProtocol.DecodedFrame decoded = GrillProtocol.decode(GrillProtocol.fromHex(
                "FA1AFE0E010000020000030000040000050000060000020205FF"));
        assertEquals(GrillProtocol.Type.ACTUAL_TEMPERATURES, decoded.type);
        assertArrayEquals(new int[] {100, 200, 300, 400, 500, 600, 225}, decoded.temperatures);
    }
}
