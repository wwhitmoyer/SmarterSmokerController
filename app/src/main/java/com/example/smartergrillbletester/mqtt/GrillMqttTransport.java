package com.example.smartergrillbletester.mqtt;

import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttException;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;

/** Wi-Fi transport for the grill's cloud MQTT protocol. */
public final class GrillMqttTransport {
    public static final String BROKER = "tcp://iot.taylorgrill.com:1883";
    private static final String USERNAME = "Taylor";
    private static final String PASSWORD = "YKC6WLIFUZaBaMQU";
    private static final int QOS = 2;

    public interface Listener {
        void onConnectionChanged(boolean connected, String detail);
        void onMessage(String topic, byte[] payload);
        void onError(String operation, Throwable error);
    }

    private final Listener listener;
    private MqttClient client;
    private String deviceId;

    public GrillMqttTransport(Listener listener) { this.listener = listener; }

    public synchronized void connect(String requestedDeviceId) {
        String id = requestedDeviceId == null ? "" : requestedDeviceId.trim();
        if (id.isEmpty() || id.contains("/") || id.contains("#") || id.contains("+"))
            throw new IllegalArgumentException("Enter a valid device ID");
        disconnect();
        deviceId = id;
        new Thread(() -> connectInBackground(id), "grill-mqtt-connect").start();
    }

    private void connectInBackground(String id) {
        try {
            MqttClient next = new MqttClient(BROKER, MqttClient.generateClientId(), new MemoryPersistence());
            next.setCallback(new MqttCallbackExtended() {
                @Override public void connectComplete(boolean reconnect, String serverURI) {
                    listener.onConnectionChanged(true, reconnect ? "MQTT reconnected" : "MQTT connected");
                }
                @Override public void connectionLost(Throwable cause) { listener.onConnectionChanged(false, "MQTT connection lost"); }
                @Override public void messageArrived(String topic, MqttMessage message) { listener.onMessage(topic, message.getPayload()); }
                @Override public void deliveryComplete(IMqttDeliveryToken token) {}
            });
            MqttConnectOptions options = new MqttConnectOptions();
            options.setUserName(USERNAME);
            options.setPassword(PASSWORD.toCharArray());
            options.setCleanSession(true);
            options.setConnectionTimeout(10);
            options.setKeepAliveInterval(20);
            options.setAutomaticReconnect(true);
            next.connect(options);
            next.subscribe(id + "/dev2app", QOS);
            synchronized (this) { client = next; }
            listener.onConnectionChanged(true, "MQTT connected and subscribed");
        } catch (MqttException error) {
            listener.onError("MQTT connect", error);
        }
    }

    public synchronized boolean isConnected() { return client != null && client.isConnected(); }

    public synchronized void publish(byte[] payload) {
        if (!isConnected()) throw new IllegalStateException("Connect MQTT first");
        try {
            client.publish(deviceId + "/app2dev", payload, QOS, true);
        } catch (MqttException error) {
            listener.onError("MQTT publish", error);
        }
    }

    public synchronized void disconnect() {
        MqttClient previous = client;
        client = null;
        if (previous == null) return;
        try {
            if (previous.isConnected()) previous.disconnect();
            previous.close();
        } catch (MqttException error) {
            listener.onError("MQTT disconnect", error);
        }
        listener.onConnectionChanged(false, "MQTT disconnected");
    }
}
