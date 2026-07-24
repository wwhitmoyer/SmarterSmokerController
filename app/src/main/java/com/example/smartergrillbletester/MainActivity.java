package com.example.smartergrillbletester;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.RingtoneManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.AdapterView;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;

import com.example.smartergrillbletester.mqtt.GrillMqttTransport;
import com.example.smartergrillbletester.protocol.GrillProtocol;

import java.text.SimpleDateFormat;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class MainActivity extends Activity {
    private static final UUID CLIENT_CONFIG_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");
    private static final String NOTIFICATION_CHANNEL_ID = "grill_alerts";
    private static final String PREFERENCES = "grill_settings";
    private static final String SAVED_GRILL_ID = "saved_grill_id";
    private static final Pattern GRILL_ID_PATTERN = Pattern.compile("(?i)(GRILL[A-Z0-9_-]*)");
    private static final byte[] PID_REQUEST = new byte[] {
            (byte) 0xFA, 0x06, (byte) 0xFE, 0x1F, 0x02, (byte) 0xFF
    };
    private static final byte[] ON_CANDIDATE = new byte[] {
            (byte) 0xFA, 0x06, (byte) 0xFE, 0x01, 0x01, (byte) 0xFF
    };
    private static final byte[] OFF_CANDIDATE = new byte[] {
            (byte) 0xFA, 0x06, (byte) 0xFE, 0x01, 0x02, (byte) 0xFF
    };
    private static final byte[] TEMP_188_CANDIDATE = new byte[] {
            (byte) 0xFA, 0x09, (byte) 0xFE, 0x05, 0x01, 0x01, 0x08, 0x08, (byte) 0xFF
    };
    private static final byte[] TEMP_200_CANDIDATE = new byte[] {
            (byte) 0xFA, 0x09, (byte) 0xFE, 0x05, 0x01, 0x02, 0x00, 0x00, (byte) 0xFF
    };
    private static final byte[] TEMP_225_CANDIDATE = new byte[] {
            (byte) 0xFA, 0x09, (byte) 0xFE, 0x05, 0x01, 0x02, 0x02, 0x05, (byte) 0xFF
    };

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Map<String, BluetoothDevice> devices = new LinkedHashMap<>();
    private final List<String> deviceRows = new ArrayList<>();
    private final List<CharacteristicRef> writableChars = new ArrayList<>();
    private final List<CharacteristicRef> notifyChars = new ArrayList<>();

    private BluetoothAdapter bluetoothAdapter;
    private BluetoothGatt bluetoothGatt;
    private GrillMqttTransport mqttTransport;
    private boolean scanning;
    private boolean probeRunning;
    private boolean sniffMode;
    private boolean grillIdPromptShown;
    private int notifyCount;
    private String selectedDeviceKey;
    private int selectedWriteIndex;
    private int selectedNotifyIndex;
    private String pendingReadLabel;
    private String lastNotifyHex;
    private StringBuilder frameBuffer = new StringBuilder();

    private TextView statusText;
    private TextView logText;
    private EditText hexInput;
    private EditText deviceIdInput;
    private EditText grillTargetInput;
    private EditText probe1TargetInput;
    private EditText probe2TargetInput;
    private EditText probe3TargetInput;
    private TextView probeStatusText;
    private Button grillPowerStatusButton;
    private Boolean currentGrillPowerOn;
    private Button scanButton;
    private ArrayAdapter<String> deviceAdapter;
    private ArrayAdapter<String> writeAdapter;
    private ArrayAdapter<String> notifyAdapter;
    private int grillTarget = -1;
    private int mqttRefreshSequence;
    private final Runnable mqttAutoRefreshTask = new Runnable() {
        @Override public void run() {
            if (!mqttTransport.isConnected()) {
                return;
            }
            refreshMqtt();
            mainHandler.postDelayed(this, 10_000L);
        }
    };
    private final boolean[] probePreAlertSent = new boolean[] { false, false, false };
    private final boolean[] probeDoneAlertSent = new boolean[] { false, false, false };

    private static final class CharacteristicRef {
        final UUID serviceUuid;
        final BluetoothGattCharacteristic characteristic;
        final String label;

        CharacteristicRef(UUID serviceUuid, BluetoothGattCharacteristic characteristic, String label) {
            this.serviceUuid = serviceUuid;
            this.characteristic = characteristic;
            this.label = label;
        }
    }

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice device = result.getDevice();
            String address = device.getAddress();
            if (address == null) {
                return;
            }
            String name = safeDeviceName(device);
            maybeOfferGrillId(grillIdFromScan(name, result.getScanRecord()));
            String row = (name == null ? "(unnamed)" : name) + "  " + address + "  RSSI " + result.getRssi();
            devices.put(address, device);
            int existingIndex = indexOfAddress(address);
            if (existingIndex >= 0) {
                deviceRows.set(existingIndex, row);
            } else {
                deviceRows.add(row);
            }
            deviceAdapter.notifyDataSetChanged();
        }

        @Override
        public void onScanFailed(int errorCode) {
            appendLog("Scan failed: " + errorCode);
            setScanning(false);
        }
    };

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt gatt, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                runUi(() -> {
                    statusText.setText("Connected: " + deviceLabel(gatt.getDevice()));
                    appendLog("Connected, discovering services");
                });
                gatt.discoverServices();
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                runUi(() -> {
                    statusText.setText("Disconnected");
                    appendLog("Disconnected status=" + status);
                    clearCharacteristics();
                });
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt gatt, int status) {
            runUi(() -> {
                appendLog("Services discovered status=" + status);
                loadCharacteristics(gatt.getServices());
            });
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt gatt, BluetoothGattCharacteristic characteristic) {
            appendNotify(characteristic, characteristic.getValue());
        }

        @Override
        public void onCharacteristicChanged(
                BluetoothGatt gatt,
                BluetoothGattCharacteristic characteristic,
                byte[] value
        ) {
            appendNotify(characteristic, value);
        }

        @Override
        public void onCharacteristicWrite(
                BluetoothGatt gatt,
                BluetoothGattCharacteristic characteristic,
                int status
        ) {
            runUi(() -> appendLog("Write " + shortUuid(characteristic.getUuid()) + " status=" + status));
        }

        @Override
        public void onCharacteristicRead(
                BluetoothGatt gatt,
                BluetoothGattCharacteristic characteristic,
                int status
        ) {
            appendRead(characteristic, characteristic.getValue(), status);
        }

        @Override
        public void onCharacteristicRead(
                BluetoothGatt gatt,
                BluetoothGattCharacteristic characteristic,
                byte[] value,
                int status
        ) {
            appendRead(characteristic, value, status);
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt gatt, BluetoothGattDescriptor descriptor, int status) {
            if (!probeRunning) {
                runUi(() -> appendLog("Descriptor write " + shortUuid(descriptor.getUuid()) + " status=" + status));
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        BluetoothManager bluetoothManager = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        bluetoothAdapter = bluetoothManager.getAdapter();
        mqttTransport = new GrillMqttTransport(new GrillMqttTransport.Listener() {
            @Override public void onConnectionChanged(boolean connected, String detail) {
                runUi(() -> {
                    statusText.setText(detail);
                    appendLog(detail);
                    mainHandler.removeCallbacks(mqttAutoRefreshTask);
                    if (connected) {
                        mainHandler.postDelayed(mqttAutoRefreshTask, 250L);
                    }
                });
            }

            @Override public void onMessage(String topic, byte[] payload) {
                runUi(() -> {
                    String hex = GrillProtocol.toHex(payload);
                    appendLog("MQTT RX " + topic + " " + hex + " " + GrillProtocol.decode(payload).description);
                    handleDecodedPayload(payload);
                });
            }

            @Override public void onError(String operation, Throwable error) {
                runUi(() -> {
                    appendLog(operation + " failed: " + error.getMessage());
                    if ("MQTT connect".equals(operation)) {
                        mainHandler.postDelayed(() -> {
                            if (!mqttTransport.isConnected() && !deviceIdInput.getText().toString().trim().isEmpty()) {
                                appendLog("Retrying Wi-Fi connection");
                                connectMqtt();
                            }
                        }, 10_000L);
                    }
                });
            }
        });
        createNotificationChannel();
        buildUi();
        requestBlePermissions();
        requestNotificationPermission();
        if (!loadSavedGrillId()) {
            promptForGrillDiscovery();
        }
    }

    @Override
    protected void onDestroy() {
        stopScan();
        mainHandler.removeCallbacks(mqttAutoRefreshTask);
        mqttTransport.disconnect();
        if (bluetoothGatt != null) {
            bluetoothGatt.close();
            bluetoothGatt = null;
        }
        super.onDestroy();
    }

    private void buildUi() {
        ScrollView pageScroll = new ScrollView(this);
        pageScroll.setFillViewport(true);
        pageScroll.setVerticalScrollBarEnabled(true);
        pageScroll.setScrollbarFadingEnabled(false);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(24, 24, 24, 24);
        pageScroll.addView(root, new ScrollView.LayoutParams(
                ScrollView.LayoutParams.MATCH_PARENT,
                ScrollView.LayoutParams.WRAP_CONTENT
        ));

        statusText = new TextView(this);
        statusText.setText("Idle");
        statusText.setTextSize(18);
        root.addView(statusText);

        grillPowerStatusButton = new Button(this);
        grillPowerStatusButton.setText("Grill power: Unknown - tap to refresh");
        grillPowerStatusButton.setTextSize(20);
        grillPowerStatusButton.setOnClickListener(v -> powerStatusClicked());
        root.addView(grillPowerStatusButton);

        root.addView(label("Wi-Fi / MQTT (primary)"));
        deviceIdInput = new EditText(this);
        deviceIdInput.setSingleLine(true);
        deviceIdInput.setHint("Grill device ID");
        root.addView(deviceIdInput);

        Button discoverGrillIdButton = new Button(this);
        discoverGrillIdButton.setText("Discover Grill ID With BLE");
        discoverGrillIdButton.setOnClickListener(v -> discoverGrillId());
        root.addView(discoverGrillIdButton);

        deviceAdapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, deviceRows);
        writeAdapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, new ArrayList<>());
        notifyAdapter = new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, new ArrayList<>());

        grillTargetInput = new EditText(this);
        grillTargetInput.setSingleLine(true);
        grillTargetInput.setHint("Grill target temp F");
        grillTargetInput.setText("225");
        root.addView(grillTargetInput);

        Button setTempButton = new Button(this);
        setTempButton.setText("Set Grill Temp");
        setTempButton.setOnClickListener(v -> setGrillTempFromInput());
        root.addView(setTempButton);

        LinearLayout unitsButtons = new LinearLayout(this);
        unitsButtons.setOrientation(LinearLayout.HORIZONTAL);
        Button fahrenheitButton = new Button(this);
        fahrenheitButton.setText("Use F");
        fahrenheitButton.setOnClickListener(v -> sendCommand(GrillProtocol.units(true), "Set Fahrenheit"));
        Button celsiusButton = new Button(this);
        celsiusButton.setText("Use C");
        celsiusButton.setOnClickListener(v -> sendCommand(GrillProtocol.units(false), "Set Celsius"));
        unitsButtons.addView(fahrenheitButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        unitsButtons.addView(celsiusButton, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        root.addView(unitsButtons);

        LinearLayout probeTargets = new LinearLayout(this);
        probeTargets.setOrientation(LinearLayout.HORIZONTAL);
        probe1TargetInput = probeTargetInput("Probe 1 target");
        probe2TargetInput = probeTargetInput("Probe 2 target");
        probe3TargetInput = probeTargetInput("Probe 3 target");
        probeTargets.addView(probe1TargetInput, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        probeTargets.addView(probe2TargetInput, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        probeTargets.addView(probe3TargetInput, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1));
        root.addView(probeTargets);

        Button setProbeTargetsButton = new Button(this);
        setProbeTargetsButton.setText("Send Probe Targets");
        setProbeTargetsButton.setOnClickListener(v -> sendProbeTargets());
        root.addView(setProbeTargetsButton);

        probeStatusText = new TextView(this);
        probeStatusText.setText("Probes: waiting for data");
        probeStatusText.setTextSize(16);
        root.addView(probeStatusText);

        hexInput = new EditText(this);
        hexInput.setSingleLine(true);
        hexInput.setText(toHex(PID_REQUEST));
        hexInput.setHint("Hex command");
        root.addView(hexInput);

        Button probeButton = new Button(this);
        probeButton.setText("Probe All With Hex");
        probeButton.setOnClickListener(v -> probeAllWithHex());
        root.addView(probeButton);

        Button listenButton = new Button(this);
        listenButton.setText("Monitor Grill");
        listenButton.setOnClickListener(v -> listenForAppTraffic());
        root.addView(listenButton);

        Button clearButton = new Button(this);
        clearButton.setText("Clear Log");
        clearButton.setOnClickListener(v -> clearLog());
        root.addView(clearButton);

        Button disconnectButton = new Button(this);
        disconnectButton.setText("Disconnect");
        disconnectButton.setOnClickListener(v -> disconnect());
        root.addView(disconnectButton);

        root.addView(label("BLE fallback / protocol capture"));

        scanButton = new Button(this);
        scanButton.setText("Scan");
        scanButton.setOnClickListener(v -> toggleScan());
        root.addView(scanButton);

        Spinner deviceSpinner = new Spinner(this);
        deviceSpinner.setAdapter(deviceAdapter);
        deviceSpinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                selectedDeviceKey = new ArrayList<>(devices.keySet()).get(position);
            }

            @Override
            public void onNothingSelected(AdapterView<?> parent) {
                selectedDeviceKey = null;
            }
        });
        root.addView(label("BLE devices"));
        root.addView(deviceSpinner);

        Button connectButton = new Button(this);
        connectButton.setText("Connect Selected");
        connectButton.setOnClickListener(v -> connectSelected());
        root.addView(connectButton);

        logText = new TextView(this);
        logText.setTextSize(13);
        logText.setMinLines(12);
        logText.setPadding(0, 12, 0, 24);
        root.addView(logText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        ));

        setContentView(pageScroll);
    }

    private TextView label(String text) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(14);
        view.setPadding(0, 16, 0, 4);
        return view;
    }

    private EditText probeTargetInput(String hint) {
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setHint(hint);
        return input;
    }

    private void sendCommand(byte[] payload, String label) {
        if (mqttTransport.isConnected()) {
            mqttTransport.publish(payload);
            appendLog("MQTT TX " + label + " " + GrillProtocol.toHex(payload));
            return;
        }
        if (bluetoothGatt == null) {
            toast("Connect Wi-Fi or BLE first");
            return;
        }
        List<CharacteristicRef> writeTargets = new ArrayList<>(writableChars);
        if (writeTargets.isEmpty()) {
            toast("No writable characteristics found");
            return;
        }
        appendLog(label + " " + toHex(payload) + describeFrame(toHex(payload)));
        long delayMs = 0;
        for (CharacteristicRef ref : writeTargets) {
            delayMs = scheduleProbe(delayMs, () -> writeHexToCharacteristic(ref, payload));
        }
    }

    private void setGrillTempFromInput() {
        Integer target = parseInteger(grillTargetInput.getText().toString());
        if (target == null || target < 0 || target > 999) {
            toast("Enter a valid grill temp");
            return;
        }
        grillTarget = target;
        sendCommand(GrillProtocol.grillTemperature(target), "Set grill temp");
    }

    private void connectMqtt() {
        try {
            statusText.setText("Connecting Wi-Fi...");
            mqttTransport.connect(deviceIdInput.getText().toString());
        } catch (IllegalArgumentException error) {
            toast(error.getMessage());
        }
    }

    private boolean loadSavedGrillId() {
        String saved = getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString(SAVED_GRILL_ID, "");
        if (saved != null && !saved.isEmpty()) {
            deviceIdInput.setText(saved);
            appendLog("Loaded saved Grill ID " + saved);
            connectMqtt();
            return true;
        }
        return false;
    }

    private void promptForGrillDiscovery() {
        new AlertDialog.Builder(this)
                .setTitle("Grill ID needed")
                .setMessage("No Grill ID is saved. Discover a GRILL device using BLE?")
                .setPositiveButton("Discover", (dialog, which) -> discoverGrillId())
                .setNegativeButton("Not now", null)
                .show();
    }

    private void discoverGrillId() {
        String saved = getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString(SAVED_GRILL_ID, "");
        if (saved != null && !saved.isEmpty()) {
            deviceIdInput.setText(saved);
            toast("Using saved Grill ID " + saved);
            return;
        }
        grillIdPromptShown = false;
        if (!scanning) {
            startScan();
        }
        appendLog("Looking for a BLE name beginning with GRILL");
    }

    private String grillIdFromScan(String deviceName, ScanRecord scanRecord) {
        String candidate = grillIdFromText(deviceName);
        if (candidate != null || scanRecord == null) {
            return candidate;
        }
        candidate = grillIdFromText(scanRecord.getDeviceName());
        if (candidate != null) {
            return candidate;
        }
        byte[] advertisedBytes = scanRecord.getBytes();
        return advertisedBytes == null ? null : grillIdFromText(new String(advertisedBytes, StandardCharsets.ISO_8859_1));
    }

    private String grillIdFromText(String text) {
        if (text == null) {
            return null;
        }
        Matcher matcher = GRILL_ID_PATTERN.matcher(text.trim());
        return matcher.find() ? matcher.group(1).toUpperCase(Locale.US) : null;
    }

    private void maybeOfferGrillId(String grillId) {
        if (grillId == null || grillIdPromptShown) {
            return;
        }
        SharedPreferences preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE);
        if (!preferences.getString(SAVED_GRILL_ID, "").isEmpty()) {
            return;
        }
        grillIdPromptShown = true;
        runUi(() -> {
            deviceIdInput.setText(grillId);
            appendLog("Discovered Grill ID " + grillId + " from BLE");
            new AlertDialog.Builder(this)
                    .setTitle("Save Grill ID?")
                    .setMessage("Found " + grillId + " in the BLE advertisement. Save it for Wi-Fi connections?")
                    .setPositiveButton("Save", (dialog, which) -> {
                        preferences.edit().putString(SAVED_GRILL_ID, grillId).apply();
                        appendLog("Saved Grill ID " + grillId);
                        connectMqtt();
                    })
                    .setNegativeButton("Use once", (dialog, which) -> connectMqtt())
                    .show();
        });
    }

    private void sendProbeTargets() {
        EditText[] inputs = new EditText[] {probe1TargetInput, probe2TargetInput, probe3TargetInput};
        boolean sent = false;
        for (int i = 0; i < inputs.length; i++) {
            Integer target = parseInteger(inputs[i].getText().toString());
            if (target == null) continue;
            if (target < 0 || target > 999) {
                toast("Probe targets must be 0 through 999");
                return;
            }
            sendCommand(GrillProtocol.probeTemperature(i + 1, target), "Set probe " + (i + 1));
            sent = true;
        }
        if (!sent) toast("Enter at least one probe target");
    }

    private void refreshMqtt() {
        if (!mqttTransport.isConnected()) {
            toast("Connect Wi-Fi first");
            return;
        }
        int sequence = ++mqttRefreshSequence;
        appendLog("MQTT refresh #" + sequence + " started");
        publishMqttQuery(sequence, 0L, GrillProtocol.QUERY_STATUS, "status");
        publishMqttQuery(sequence, 700L, GrillProtocol.QUERY_SET_TEMPERATURES, "set temperatures");
        publishMqttQuery(sequence, 1400L, GrillProtocol.QUERY_ACTUAL_TEMPERATURES, "actual temperatures");
    }

    private void publishMqttQuery(int sequence, long delayMs, byte[] query, String label) {
        mainHandler.postDelayed(() -> {
            if (sequence != mqttRefreshSequence || !mqttTransport.isConnected()) {
                return;
            }
            try {
                mqttTransport.publish(query);
                appendLog("MQTT TX refresh #" + sequence + " " + label + " " + GrillProtocol.toHex(query));
            } catch (IllegalStateException error) {
                appendLog("MQTT refresh stopped: " + error.getMessage());
            }
        }, delayMs);
    }

    private byte[] commandForTemp(int temp) {
        int hundreds = temp / 100;
        int tens = (temp / 10) % 10;
        int ones = temp % 10;
        return new byte[] {
                (byte) 0xFA, 0x09, (byte) 0xFE, 0x05, 0x01,
                (byte) hundreds, (byte) tens, (byte) ones, (byte) 0xFF
        };
    }

    private void requestBlePermissions() {
        List<String> missing = new ArrayList<>();
        for (String permission : permissionsForSdk()) {
            if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                missing.add(permission);
            }
        }
        if (!missing.isEmpty()) {
            requestPermissions(missing.toArray(new String[0]), 100);
        }
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, 101);
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Grill alerts",
                NotificationManager.IMPORTANCE_HIGH
        );
        channel.setDescription("Grill temperature and probe alerts");
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        manager.createNotificationChannel(channel);
    }

    private String[] permissionsForSdk() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return new String[] { Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT };
        }
        return new String[] { Manifest.permission.ACCESS_FINE_LOCATION };
    }

    private boolean hasBlePermissions() {
        for (String permission : permissionsForSdk()) {
            if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                return false;
            }
        }
        return true;
    }

    private void toggleScan() {
        if (scanning) {
            stopScan();
        } else {
            startScan();
        }
    }

    private void startScan() {
        if (!hasBlePermissions()) {
            requestBlePermissions();
            return;
        }
        if (bluetoothAdapter == null || bluetoothAdapter.getBluetoothLeScanner() == null) {
            toast("Bluetooth scanner unavailable");
            return;
        }
        devices.clear();
        deviceRows.clear();
        deviceAdapter.notifyDataSetChanged();
        bluetoothAdapter.getBluetoothLeScanner().startScan(scanCallback);
        setScanning(true);
        appendLog("Scan started");
    }

    private void stopScan() {
        if (!scanning) {
            return;
        }
        if (hasBlePermissions() && bluetoothAdapter != null && bluetoothAdapter.getBluetoothLeScanner() != null) {
            bluetoothAdapter.getBluetoothLeScanner().stopScan(scanCallback);
        }
        setScanning(false);
        appendLog("Scan stopped");
    }

    private void setScanning(boolean value) {
        scanning = value;
        scanButton.setText(value ? "Stop Scan" : "Scan");
    }

    private void connectSelected() {
        if (!hasBlePermissions()) {
            requestBlePermissions();
            return;
        }
        stopScan();
        BluetoothDevice device = selectedDeviceKey == null ? null : devices.get(selectedDeviceKey);
        if (device == null) {
            toast("Select a device first");
            return;
        }
        if (bluetoothGatt != null) {
            bluetoothGatt.close();
        }
        bluetoothGatt = device.connectGatt(this, false, gattCallback);
        statusText.setText("Connecting: " + deviceLabel(device));
        appendLog("Connecting to " + deviceLabel(device));
    }

    private void disconnect() {
        if (bluetoothGatt != null) {
            bluetoothGatt.disconnect();
            bluetoothGatt.close();
            bluetoothGatt = null;
        }
        clearCharacteristics();
        statusText.setText("Disconnected");
        appendLog("Closed GATT");
    }

    private void loadCharacteristics(List<BluetoothGattService> services) {
        clearCharacteristics();
        for (BluetoothGattService service : services) {
            for (BluetoothGattCharacteristic characteristic : service.getCharacteristics()) {
                String props = propertyLabels(characteristic.getProperties());
                String label = shortUuid(service.getUuid()) + " / " + shortUuid(characteristic.getUuid()) + " " + props;
                if (isWritable(characteristic)) {
                    writableChars.add(new CharacteristicRef(service.getUuid(), characteristic, label));
                    writeAdapter.add(label);
                }
                if (isNotifiable(characteristic)) {
                    notifyChars.add(new CharacteristicRef(service.getUuid(), characteristic, label));
                    notifyAdapter.add(label);
                }
            }
        }
        writeAdapter.notifyDataSetChanged();
        notifyAdapter.notifyDataSetChanged();
        appendLog("Writable=" + writableChars.size() + ", notify=" + notifyChars.size());
        appendLog("W: " + compactLabels(writableChars));
        appendLog("N: " + compactLabels(notifyChars));
    }

    private void clearLog() {
        notifyCount = 0;
        lastNotifyHex = null;
        frameBuffer.setLength(0);
        for (int i = 0; i < probePreAlertSent.length; i++) {
            probePreAlertSent[i] = false;
            probeDoneAlertSent[i] = false;
        }
        logText.setText("");
    }

    private void clearCharacteristics() {
        writableChars.clear();
        notifyChars.clear();
        if (writeAdapter != null) {
            writeAdapter.clear();
            writeAdapter.notifyDataSetChanged();
        }
        if (notifyAdapter != null) {
            notifyAdapter.clear();
            notifyAdapter.notifyDataSetChanged();
        }
    }

    private void subscribeSelected() {
        if (bluetoothGatt == null || selectedNotifyIndex >= notifyChars.size()) {
            toast("Connect and select a notify characteristic first");
            return;
        }
        subscribeCharacteristic(notifyChars.get(selectedNotifyIndex));
    }

    private void subscribeCharacteristic(CharacteristicRef ref) {
        bluetoothGatt.setCharacteristicNotification(ref.characteristic, true);
        BluetoothGattDescriptor descriptor = ref.characteristic.getDescriptor(CLIENT_CONFIG_UUID);
        if (descriptor == null) {
            appendLog("No CCCD descriptor on " + ref.label + "; notification flag requested only");
            return;
        }
        byte[] descriptorValue = descriptorValueFor(ref.characteristic);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            bluetoothGatt.writeDescriptor(descriptor, descriptorValue);
        } else {
            descriptor.setValue(descriptorValue);
            bluetoothGatt.writeDescriptor(descriptor);
        }
        if (!probeRunning) {
            appendLog("Subscribe requested " + ref.label);
        }
    }

    private void readSelectedWritable() {
        if (bluetoothGatt == null || selectedWriteIndex >= writableChars.size()) {
            toast("Connect and select a writable characteristic first");
            return;
        }
        readCharacteristic(writableChars.get(selectedWriteIndex));
    }

    private void readSelectedNotify() {
        if (bluetoothGatt == null || selectedNotifyIndex >= notifyChars.size()) {
            toast("Connect and select a notify characteristic first");
            return;
        }
        readCharacteristic(notifyChars.get(selectedNotifyIndex));
    }

    private void readCharacteristic(CharacteristicRef ref) {
        pendingReadLabel = shortRefLabel(ref);
        if (!probeRunning) {
            appendLog("Read requested " + ref.label);
        }
        bluetoothGatt.readCharacteristic(ref.characteristic);
    }

    private void sendHexCommand() {
        if (bluetoothGatt == null || selectedWriteIndex >= writableChars.size()) {
            toast("Connect and select a writable characteristic first");
            return;
        }
        byte[] payload;
        try {
            payload = parseHex(hexInput.getText().toString());
        } catch (IllegalArgumentException exception) {
            toast(exception.getMessage());
            return;
        }
        writeHexToCharacteristic(writableChars.get(selectedWriteIndex), payload);
    }

    private void writeHexToCharacteristic(CharacteristicRef ref, byte[] payload) {
        int writeType = writeTypeFor(ref.characteristic);
        ref.characteristic.setWriteType(writeType);
        String payloadHex = toHex(payload);
        String description = describeFrame(payloadHex);
        if (probeRunning) {
            appendLog("Write " + shortRefLabel(ref) + " " + payloadHex + description);
        } else {
            appendLog("Write hex " + payloadHex + description + " -> " + ref.label + " using " + writeTypeLabel(writeType));
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            bluetoothGatt.writeCharacteristic(
                    ref.characteristic,
                    payload,
                    writeType
            );
        } else {
            ref.characteristic.setValue(payload);
            bluetoothGatt.writeCharacteristic(ref.characteristic);
        }
    }

    private void probeAllWithHex() {
        if (bluetoothGatt == null) {
            toast("Connect first");
            return;
        }
        byte[] payload;
        try {
            payload = parseHex(hexInput.getText().toString());
        } catch (IllegalArgumentException exception) {
            toast(exception.getMessage());
            return;
        }
        List<CharacteristicRef> writeTargets = new ArrayList<>(writableChars);
        List<CharacteristicRef> notifyTargets = new ArrayList<>(notifyChars);
        probeRunning = true;
        sniffMode = false;
        pendingReadLabel = null;
        clearLog();
        String payloadHex = toHex(payload);
        appendLog("Probe hex " + payloadHex + describeFrame(payloadHex));
        appendLog("W: " + compactLabels(writeTargets));
        appendLog("N: " + compactLabels(notifyTargets));

        long delayMs = 0;
        for (CharacteristicRef ref : writeTargets) {
            delayMs = scheduleProbe(delayMs, () -> readCharacteristic(ref));
        }
        for (CharacteristicRef ref : notifyTargets) {
            delayMs = scheduleProbe(delayMs, () -> readCharacteristic(ref));
        }
        for (CharacteristicRef ref : notifyTargets) {
            delayMs = scheduleProbe(delayMs, () -> subscribeCharacteristic(ref));
        }
        for (CharacteristicRef writeRef : writeTargets) {
            delayMs = scheduleProbe(delayMs, () -> writeHexToCharacteristic(writeRef, payload));
            for (CharacteristicRef notifyRef : notifyTargets) {
                delayMs = scheduleProbe(delayMs, () -> readCharacteristic(notifyRef));
            }
            delayMs = scheduleProbe(delayMs, () -> readCharacteristic(writeRef));
        }
        mainHandler.postDelayed(() -> {
            appendLog("Probe complete");
            probeRunning = false;
            pendingReadLabel = null;
        }, delayMs + 250);
    }

    private long scheduleProbe(long delayMs, Runnable action) {
        mainHandler.postDelayed(action, delayMs);
        return delayMs + 900;
    }

    private void listenForAppTraffic() {
        if (bluetoothGatt == null) {
            toast("Connect first");
            return;
        }
        CharacteristicRef abf2 = findCharacteristic("abf2", notifyChars);
        if (abf2 == null) {
            toast("abf2 notify characteristic not found");
            return;
        }
        probeRunning = false;
        sniffMode = true;
        clearLog();
        appendLog("Listening on " + shortRefLabel(abf2));
        appendLog("Monitoring grill notifications");
        subscribeCharacteristic(abf2);
    }

    private void appendNotify(BluetoothGattCharacteristic characteristic, byte[] value) {
        String uuid = shortUuid(characteristic.getUuid());
        String hex = toHex(value);
        if (hex.equals(lastNotifyHex)) {
            return;
        }
        lastNotifyHex = hex;
        runUi(() -> appendNotifyFrame(uuid, hex));
    }

    private void appendNotifyFrame(String uuid, String hex) {
        frameBuffer.append(hex);
        while (true) {
            String buffered = frameBuffer.toString();
            int start = buffered.indexOf("FA");
            if (start < 0) {
                frameBuffer.setLength(0);
                return;
            }
            if (start > 0) {
                buffered = buffered.substring(start);
            }
            int end = buffered.indexOf("FF", 2);
            if (end < 0) {
                frameBuffer.setLength(0);
                frameBuffer.append(buffered);
                return;
            }
            String frame = buffered.substring(0, end + 2);
            int lineNumber = ++notifyCount;
            String prefix = sniffMode ? "RX" : "Notify";
            appendLog(prefix + lineNumber + " " + uuid + " " + frame + describeFrame(frame));
            handleDecodedFrame(frame);
            frameBuffer.setLength(0);
            frameBuffer.append(buffered.substring(end + 2));
        }
    }

    private void appendRead(BluetoothGattCharacteristic characteristic, byte[] value, int status) {
        String label = pendingReadLabel == null ? shortUuid(characteristic.getUuid()) : pendingReadLabel;
        pendingReadLabel = null;
        if (probeRunning) {
            String hex = toHex(value);
            runUi(() -> appendLog("Read " + label + "=" + hex + describeFrame(hex)));
        } else {
            String hex = toHex(value);
            runUi(() -> appendLog("Read " + shortUuid(characteristic.getUuid()) + " status=" + status + " " + hex + describeFrame(hex)));
        }
    }

    private void handleDecodedFrame(String frame) {
        try {
            updateGrillPowerStatus(GrillProtocol.decode(GrillProtocol.fromHex(frame)));
        } catch (IllegalArgumentException ignored) {
            // The existing BLE parser will still attempt its known temperature formats.
        }
        int[] probes = decodeProbeTemps(frame);
        if (probes == null) {
            return;
        }
        probeStatusText.setText("Probe 1: " + formatProbeTemp(probes[0]) +
                "  Probe 2: " + formatProbeTemp(probes[1]) +
                "  Probe 3: " + formatProbeTemp(probes[2]));
        checkProbeAlerts(probes);
    }

    private void handleDecodedPayload(byte[] payload) {
        GrillProtocol.DecodedFrame decoded = GrillProtocol.decode(payload);
        updateGrillPowerStatus(decoded);
        if (decoded.type != GrillProtocol.Type.ACTUAL_TEMPERATURES || decoded.temperatures.length < 3) {
            return;
        }
        int[] probes = new int[] {decoded.temperatures[0], decoded.temperatures[1], decoded.temperatures[2]};
        probeStatusText.setText("Probe 1: " + formatProbeTemp(probes[0]) +
                "  Probe 2: " + formatProbeTemp(probes[1]) +
                "  Probe 3: " + formatProbeTemp(probes[2]));
        checkProbeAlerts(probes);
    }

    private void updateGrillPowerStatus(GrillProtocol.DecodedFrame decoded) {
        if (decoded.type != GrillProtocol.Type.STATUS || decoded.powerOn == null) {
            return;
        }
        currentGrillPowerOn = decoded.powerOn;
        grillPowerStatusButton.setEnabled(true);
        grillPowerStatusButton.setText(decoded.powerOn
                ? "Grill power: ON - tap to turn OFF"
                : "Grill power: OFF - tap to turn ON");
    }

    private void powerStatusClicked() {
        if (currentGrillPowerOn == null) {
            if (mqttTransport.isConnected() || bluetoothGatt != null) {
                sendCommand(GrillProtocol.QUERY_STATUS, "Request power status");
                grillPowerStatusButton.setText("Grill power: Checking...");
            } else {
                toast("Waiting for a grill connection");
            }
            return;
        }
        boolean turnOn = !currentGrillPowerOn;
        new AlertDialog.Builder(this)
                .setTitle(turnOn ? "Turn grill on?" : "Turn grill off?")
                .setMessage("Confirm this grill power change.")
                .setPositiveButton(turnOn ? "Turn On" : "Turn Off", (dialog, which) -> {
                    sendCommand(GrillProtocol.power(turnOn), turnOn ? "Turn On" : "Turn Off");
                    currentGrillPowerOn = null;
                    grillPowerStatusButton.setEnabled(false);
                    grillPowerStatusButton.setText("Grill power: Changing...");
                    mainHandler.postDelayed(() -> {
                        if (mqttTransport.isConnected() || bluetoothGatt != null) {
                            sendCommand(GrillProtocol.QUERY_STATUS, "Verify power status");
                        }
                    }, 1500L);
                    mainHandler.postDelayed(() -> {
                        if (currentGrillPowerOn == null) {
                            grillPowerStatusButton.setEnabled(true);
                            grillPowerStatusButton.setText("Grill power: Unknown - tap to refresh");
                        }
                    }, 5000L);
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void checkProbeAlerts(int[] probes) {
        EditText[] targetInputs = new EditText[] { probe1TargetInput, probe2TargetInput, probe3TargetInput };
        for (int i = 0; i < probes.length && i < targetInputs.length; i++) {
            int current = probes[i];
            Integer target = parseInteger(targetInputs[i].getText().toString());
            if (current < 0 || target == null || target <= 0) {
                continue;
            }
            int delta = target - current;
            if (current >= target) {
                if (!probeDoneAlertSent[i]) {
                    sendNotification(
                            200 + i,
                            "Probe " + (i + 1) + " reached temp",
                            "Probe " + (i + 1) + " is " + current + "F, target " + target + "F"
                    );
                    probeDoneAlertSent[i] = true;
                    probePreAlertSent[i] = true;
                }
            } else if (delta <= 5) {
                if (!probePreAlertSent[i]) {
                    sendNotification(
                            100 + i,
                            "Probe " + (i + 1) + " within 5F",
                            "Probe " + (i + 1) + " is " + current + "F, target " + target + "F"
                    );
                    probePreAlertSent[i] = true;
                }
            } else {
                probePreAlertSent[i] = false;
                probeDoneAlertSent[i] = false;
            }
        }
    }

    private void sendNotification(int id, String title, String body) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            appendLog("Notification blocked: " + title);
            return;
        }
        NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        android.app.Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new android.app.Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
                : new android.app.Notification.Builder(this);
        builder.setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(new android.app.Notification.BigTextStyle().bigText(body))
                .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
                .setAutoCancel(true);
        manager.notify(id, builder.build());
        appendLog("Alert: " + title + " - " + body);
    }

    private void runUi(Runnable runnable) {
        mainHandler.post(runnable);
    }

    private void appendLog(String message) {
        String stamp = new SimpleDateFormat("HH:mm:ss", Locale.US).format(new Date());
        logText.append("[" + stamp + "] " + message + "\n");
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private String safeDeviceName(BluetoothDevice device) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !hasBlePermissions()) {
            return null;
        }
        return device.getName();
    }

    private String deviceLabel(BluetoothDevice device) {
        String name = safeDeviceName(device);
        return (name == null ? "(unnamed)" : name) + " " + device.getAddress();
    }

    private int indexOfAddress(String address) {
        for (int i = 0; i < deviceRows.size(); i++) {
            if (deviceRows.get(i).contains(address)) {
                return i;
            }
        }
        return -1;
    }

    private boolean isWritable(BluetoothGattCharacteristic characteristic) {
        int writable = BluetoothGattCharacteristic.PROPERTY_WRITE |
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE;
        return (characteristic.getProperties() & writable) != 0;
    }

    private boolean isNotifiable(BluetoothGattCharacteristic characteristic) {
        int readable = BluetoothGattCharacteristic.PROPERTY_NOTIFY |
                BluetoothGattCharacteristic.PROPERTY_INDICATE;
        return (characteristic.getProperties() & readable) != 0;
    }

    private int writeTypeFor(BluetoothGattCharacteristic characteristic) {
        int properties = characteristic.getProperties();
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) {
            return BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;
        }
        return BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT;
    }

    private byte[] descriptorValueFor(BluetoothGattCharacteristic characteristic) {
        int properties = characteristic.getProperties();
        if ((properties & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0 &&
                (properties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) == 0) {
            return BluetoothGattDescriptor.ENABLE_INDICATION_VALUE;
        }
        return BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
    }

    private String writeTypeLabel(int writeType) {
        if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
            return "write-no-response";
        }
        if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) {
            return "write-with-response";
        }
        return "write-type-" + writeType;
    }

    private String propertyLabels(int properties) {
        List<String> labels = new ArrayList<>();
        if ((properties & BluetoothGattCharacteristic.PROPERTY_READ) != 0) labels.add("read");
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) labels.add("write");
        if ((properties & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) labels.add("write-no-response");
        if ((properties & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) labels.add("notify");
        if ((properties & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) labels.add("indicate");
        return labels.toString();
    }

    private String toHex(byte[] bytes) {
        if (bytes == null) {
            return "";
        }
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            builder.append(String.format(Locale.US, "%02X", value & 0xFF));
        }
        return builder.toString();
    }

    private String compactLabels(List<CharacteristicRef> refs) {
        List<String> labels = new ArrayList<>();
        for (CharacteristicRef ref : refs) {
            labels.add(shortRefLabel(ref));
        }
        return labels.toString();
    }

    private String shortRefLabel(CharacteristicRef ref) {
        return shortUuid(ref.serviceUuid) + "/" + shortUuid(ref.characteristic.getUuid());
    }

    private String describeFrame(String hex) {
        Integer temp = decodeTempFrame(hex);
        if (temp != null) {
            return " temp=" + temp + "F";
        }
        int[] probes = decodeProbeTemps(hex);
        if (probes != null) {
            return " probe1=" + formatProbeTemp(probes[0]) +
                    " probe2=" + formatProbeTemp(probes[1]) +
                    " probe3=" + formatProbeTemp(probes[2]);
        }
        return "";
    }

    private Integer decodeTempFrame(String hex) {
        if (hex == null || !hex.startsWith("FA09FE05") || !hex.endsWith("FF") || hex.length() < 18) {
            return null;
        }
        try {
            int hundreds = Integer.parseInt(hex.substring(10, 12), 16);
            int tens = Integer.parseInt(hex.substring(12, 14), 16);
            int ones = Integer.parseInt(hex.substring(14, 16), 16);
            if (hundreds > 9 || tens > 9 || ones > 9) {
                return null;
            }
            return hundreds * 100 + tens * 10 + ones;
        } catch (NumberFormatException exception) {
            return null;
        }
    }

    private int[] decodeProbeTemps(String hex) {
        if (hex == null || !hex.startsWith("FA1AFE0E") || !hex.endsWith("FF") || hex.length() < 20) {
            return null;
        }
        try {
            int probe1 = decodeDigitTriplet(hex, 8);
            int probe2 = decodeDigitTriplet(hex, 14);
            int probe3 = decodeDigitTriplet(hex, 20);
            if (probe1 < -1 || probe2 < -1 || probe3 < -1) {
                return null;
            }
            return new int[] { probe1, probe2, probe3 };
        } catch (NumberFormatException exception) {
            return null;
        }
    }

    private int decodeDigitTriplet(String hex, int offset) {
        int hundreds = Integer.parseInt(hex.substring(offset, offset + 2), 16);
        int tens = Integer.parseInt(hex.substring(offset + 2, offset + 4), 16);
        int ones = Integer.parseInt(hex.substring(offset + 4, offset + 6), 16);
        if (hundreds == 9) {
            return -1;
        }
        if (hundreds > 9 || tens > 9 || ones > 9) {
            return -1;
        }
        return hundreds * 100 + tens * 10 + ones;
    }

    private String formatProbeTemp(int value) {
        if (value < 0) {
            return "disconnected";
        }
        return value + "F";
    }

    private CharacteristicRef findCharacteristic(String shortCharacteristicUuid, List<CharacteristicRef> refs) {
        for (CharacteristicRef ref : refs) {
            if (shortCharacteristicUuid.equalsIgnoreCase(shortUuid(ref.characteristic.getUuid()))) {
                return ref;
            }
        }
        return null;
    }

    private byte[] parseHex(String text) {
        String normalized = text.replaceAll("[^0-9A-Fa-f]", "");
        if (normalized.isEmpty()) {
            throw new IllegalArgumentException("Enter hex bytes first");
        }
        if ((normalized.length() % 2) != 0) {
            throw new IllegalArgumentException("Hex must have an even number of digits");
        }
        byte[] bytes = new byte[normalized.length() / 2];
        for (int i = 0; i < normalized.length(); i += 2) {
            bytes[i / 2] = (byte) Integer.parseInt(normalized.substring(i, i + 2), 16);
        }
        return bytes;
    }

    private Integer parseInteger(String text) {
        String normalized = text == null ? "" : text.trim();
        if (normalized.isEmpty()) {
            return null;
        }
        try {
            return Integer.parseInt(normalized);
        } catch (NumberFormatException exception) {
            return null;
        }
    }

    private String shortUuid(UUID uuid) {
        String text = uuid.toString();
        if (text.startsWith("0000") && text.endsWith("-0000-1000-8000-00805f9b34fb")) {
            return text.substring(4, 8);
        }
        return text;
    }
}
