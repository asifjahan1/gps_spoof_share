package com.example.gps_spoof_share

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Manages BLE discovery, connection, and GPS data synchronisation for the
 * in-app device-to-device communication feature.
 *
 * Operates on a **separate** set of UUIDs from the existing [SpoofService]
 * BLE implementation to avoid any interference.
 *
 * Supports two roles:
 * - **Host (Peripheral)**: Advertises a GATT service, accepts connections,
 *   and broadcasts GPS data to all subscribed clients.
 * - **Client (Central)**: Scans for hosts, connects, and receives GPS
 *   notifications.
 */
class BleDiscoveryManager(private val context: Context) {

    companion object {
        private const val TAG = "BleDiscoveryManager"

        // Separate UUIDs from existing SpoofService
        private val DISCOVERY_SERVICE_UUID =
            UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        private val GPS_CHAR_UUID =
            UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567891")
        private val DEVICE_INFO_CHAR_UUID =
            UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567892")
        private val CCCD_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        // Reconnect parameters
        private const val RECONNECT_INITIAL_DELAY_MS = 1000L
        private const val RECONNECT_MAX_DELAY_MS = 30000L
    }

    // Flutter method channel for sending events back to Dart
    var channel: MethodChannel? = null

    private val bluetoothManager: BluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Host mode state ──────────────────────────────────────────────────────
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val subscribedClients = ConcurrentHashMap<String, BluetoothDevice>()
    private var isHostActive = false

    // ── Client mode state ────────────────────────────────────────────────────
    private var scanner: BluetoothLeScanner? = null
    private var isScanning = false
    private val connectedGatts = ConcurrentHashMap<String, BluetoothGatt>()
    private var isClientActive = false

    // ── Reconnect ────────────────────────────────────────────────────────────
    private val reconnectDelays = ConcurrentHashMap<String, Long>()
    private val reconnectRunnables = ConcurrentHashMap<String, Runnable>()

    // ── Bluetooth state monitoring ───────────────────────────────────────────
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                val state = intent.getIntExtra(
                    BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR
                )
                val isOn = state == BluetoothAdapter.STATE_ON
                invokeFlutter("onBluetoothStateChanged", isOn)
            }
        }
    }

    init {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                bluetoothStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            context.registerReceiver(bluetoothStateReceiver, filter)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Public API – called from MainActivity via MethodChannel
    // ─────────────────────────────────────────────────────────────────────────

    /** Returns whether the Bluetooth adapter is currently powered on. */
    fun isBluetoothOn(): Boolean = bluetoothAdapter?.isEnabled == true

    // ── Scanning ─────────────────────────────────────────────────────────────

    /** Starts a BLE scan for devices. We filter manually to avoid hardware filter bugs. */
    @SuppressLint("MissingPermission")
    fun startScan() {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            invokeFlutter("onError", "Bluetooth is not available or disabled")
            return
        }

        scanner = bluetoothAdapter.bluetoothLeScanner
        if (scanner == null) {
            invokeFlutter("onError", "BLE scanner not available")
            return
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()

        scanner?.startScan(emptyList(), settings, scanCallback)
        isScanning = true
        Log.i(TAG, "BLE scan started")
    }

    /** Stops the active BLE scan. */
    @SuppressLint("MissingPermission")
    fun stopScan() {
        if (isScanning) {
            scanner?.stopScan(scanCallback)
            isScanning = false
            invokeFlutter("onScanStopped", null)
            Log.i(TAG, "BLE scan stopped")
        }
    }

    // ── Connection ───────────────────────────────────────────────────────────

    /** Initiates a GATT connection to the device with the given address. */
    @SuppressLint("MissingPermission")
    fun connectToDevice(deviceId: String) {
        val device = bluetoothAdapter?.getRemoteDevice(deviceId)
        if (device == null) {
            invokeFlutter("onError", "Device not found: $deviceId")
            return
        }

        // Cancel any pending reconnect
        cancelReconnect(deviceId)

        Log.i(TAG, "Connecting to $deviceId")
        device.connectGatt(context, false, clientGattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    /** Disconnects from the device with the given address. */
    @SuppressLint("MissingPermission")
    fun disconnectDevice(deviceId: String) {
        cancelReconnect(deviceId)

        connectedGatts[deviceId]?.let { gatt ->
            gatt.disconnect()
            gatt.close()
            connectedGatts.remove(deviceId)
        }

        // Also remove from host's subscribed clients
        subscribedClients.remove(deviceId)

        invokeFlutter("onDeviceDisconnected", mapOf("id" to deviceId))
        Log.i(TAG, "Disconnected from $deviceId")
    }

    // ── Host mode ────────────────────────────────────────────────────────────

    /** Starts advertising and opens a GATT server to accept client connections. */
    @SuppressLint("MissingPermission")
    fun startHostMode() {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            invokeFlutter("onError", "Bluetooth is not available or disabled")
            return
        }

        // Open GATT server
        gattServer = bluetoothManager.openGattServer(context, hostGattCallback)
        if (gattServer == null) {
            invokeFlutter("onError", "Failed to open GATT server")
            return
        }

        // Create service
        val service = BluetoothGattService(
            DISCOVERY_SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )

        // GPS data characteristic (notify)
        val gpsChar = BluetoothGattCharacteristic(
            GPS_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_WRITE or
                    BluetoothGattDescriptor.PERMISSION_READ
        )
        gpsChar.addDescriptor(cccd)
        service.addCharacteristic(gpsChar)

        // Device info characteristic (read)
        val infoChar = BluetoothGattCharacteristic(
            DEVICE_INFO_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        service.addCharacteristic(infoChar)

        gattServer?.addService(service)

        // Start advertising
        startHostAdvertising()
        isHostActive = true
        Log.i(TAG, "Host mode started")
    }

    /** Stops advertising and closes the GATT server. */
    @SuppressLint("MissingPermission")
    fun stopHostMode() {
        stopHostAdvertising()
        gattServer?.close()
        gattServer = null
        subscribedClients.clear()
        isHostActive = false
        Log.i(TAG, "Host mode stopped")
    }

    /** Broadcasts a GPS location JSON string to all subscribed clients. */
    @SuppressLint("MissingPermission")
    fun broadcastLocation(jsonString: String) {
        if (!isHostActive || subscribedClients.isEmpty()) return

        val service = gattServer?.getService(DISCOVERY_SERVICE_UUID) ?: return
        val characteristic = service.getCharacteristic(GPS_CHAR_UUID) ?: return

        val data = jsonString.toByteArray(Charsets.UTF_8)

        for ((_, device) in subscribedClients) {
            try {
                characteristic.value = data
                gattServer?.notifyCharacteristicChanged(device, characteristic, false)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to notify client ${device.address}", e)
            }
        }
    }

    // ── Client mode ──────────────────────────────────────────────────────────

    /** Enters client mode (enables scan → connect → subscribe flow). */
    fun startClientMode() {
        isClientActive = true
        Log.i(TAG, "Client mode started")
    }

    /** Exits client mode and disconnects from all hosts. */
    @SuppressLint("MissingPermission")
    fun stopClientMode() {
        isClientActive = false
        stopScan()

        for ((id, gatt) in connectedGatts) {
            cancelReconnect(id)
            gatt.disconnect()
            gatt.close()
        }
        connectedGatts.clear()
        Log.i(TAG, "Client mode stopped")
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    /** Releases all resources.  Call from Activity.onDestroy(). */
    @SuppressLint("MissingPermission")
    fun destroy() {
        stopScan()
        stopHostMode()
        stopClientMode()
        try {
            context.unregisterReceiver(bluetoothStateReceiver)
        } catch (_: Exception) { }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scan callback
    // ─────────────────────────────────────────────────────────────────────────

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val uuids = result.scanRecord?.serviceUuids
            if (uuids == null || !uuids.contains(ParcelUuid(DISCOVERY_SERVICE_UUID))) {
                return
            }

            val device = result.device
            val deviceName = device.name ?: "Unknown"
            val rssi = result.rssi

            val deviceInfo = mapOf(
                "id" to device.address,
                "name" to deviceName,
                "rssi" to rssi,
                "platform" to "unknown"  // We can't determine platform from scan alone
            )

            invokeFlutter("onDeviceDiscovered", deviceInfo)
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed with error: $errorCode")
            isScanning = false
            invokeFlutter("onError", "Scan failed (error $errorCode)")
            invokeFlutter("onScanStopped", null)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Host GATT server callback
    // ─────────────────────────────────────────────────────────────────────────

    private val hostGattCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(
            device: BluetoothDevice, status: Int, newState: Int
        ) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                subscribedClients[device.address] = device
                val info = mapOf(
                    "id" to device.address,
                    "name" to (device.name ?: "Unknown"),
                    "platform" to "unknown"
                )
                invokeFlutter("onDeviceConnected", info)
                Log.i(TAG, "Client connected: ${device.address}")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                subscribedClients.remove(device.address)
                invokeFlutter(
                    "onDeviceDisconnected",
                    mapOf("id" to device.address)
                )
                Log.i(TAG, "Client disconnected: ${device.address}")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            when (characteristic.uuid) {
                DEVICE_INFO_CHAR_UUID -> {
                    val info = JSONObject().apply {
                        put("name", Build.MODEL)
                        put("platform", "android")
                    }.toString().toByteArray(Charsets.UTF_8)
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                        info.copyOfRange(offset, info.size)
                    )
                }
                GPS_CHAR_UUID -> {
                    val data = characteristic.value ?: ByteArray(0)
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                        if (offset < data.size) data.copyOfRange(offset, data.size)
                        else ByteArray(0)
                    )
                }
                else -> {
                    gattServer?.sendResponse(
                        device, requestId, BluetoothGatt.GATT_FAILURE, 0, null
                    )
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                // Client subscribing/unsubscribing to notifications
                if (value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribedClients[device.address] = device
                } else if (value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                    subscribedClients.remove(device.address)
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null
                )
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Client GATT callback
    // ─────────────────────────────────────────────────────────────────────────

    private val clientGattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(
            gatt: BluetoothGatt, status: Int, newState: Int
        ) {
            val deviceId = gatt.device.address

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i(TAG, "Connected to GATT server: $deviceId")
                connectedGatts[deviceId] = gatt
                reconnectDelays.remove(deviceId)
                gatt.discoverServices()

                val info = mapOf(
                    "id" to deviceId,
                    "name" to (gatt.device.name ?: "Unknown"),
                    "platform" to "unknown"
                )
                invokeFlutter("onDeviceConnected", info)

            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.i(TAG, "Disconnected from GATT server: $deviceId")
                gatt.close()
                connectedGatts.remove(deviceId)
                invokeFlutter("onDeviceDisconnected", mapOf("id" to deviceId))

                // Auto-reconnect if client mode is still active
                if (isClientActive) {
                    scheduleReconnect(deviceId)
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed: $status")
                return
            }

            val service = gatt.getService(DISCOVERY_SERVICE_UUID)
            if (service == null) {
                Log.e(TAG, "Discovery service not found on ${gatt.device.address}")
                return
            }

            // Read device info
            val infoChar = service.getCharacteristic(DEVICE_INFO_CHAR_UUID)
            if (infoChar != null) {
                gatt.readCharacteristic(infoChar)
            }

            // Subscribe to GPS notifications
            val gpsChar = service.getCharacteristic(GPS_CHAR_UUID)
            if (gpsChar != null) {
                gatt.setCharacteristicNotification(gpsChar, true)
                val cccd = gpsChar.getDescriptor(CCCD_UUID)
                if (cccd != null) {
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(cccd)
                }
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS &&
                characteristic.uuid == DEVICE_INFO_CHAR_UUID
            ) {
                val data = characteristic.value
                if (data != null) {
                    try {
                        val json = JSONObject(String(data, Charsets.UTF_8))
                        val platform = json.optString("platform", "unknown")
                        val name = json.optString("name", "Unknown")
                        // Update the device info on Flutter side
                        invokeFlutter("onDeviceConnected", mapOf(
                            "id" to gatt.device.address,
                            "name" to name,
                            "platform" to platform
                        ))
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to parse device info", e)
                    }
                }
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == GPS_CHAR_UUID) {
                val data = characteristic.value
                if (data != null) {
                    val jsonStr = String(data, Charsets.UTF_8)
                    invokeFlutter("onLocationReceived", jsonStr)
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Host advertising
    // ─────────────────────────────────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun startHostAdvertising() {
        advertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            invokeFlutter("onError", "BLE advertising not supported on this device")
            return
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(DISCOVERY_SERVICE_UUID))
            .build()

        advertiser?.startAdvertising(settings, data, null, advertiseCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopHostAdvertising() {
        advertiser?.stopAdvertising(advertiseCallback)
        advertiser = null
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "Discovery advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "Discovery advertising failed: $errorCode")
            invokeFlutter("onError", "Advertising failed (error $errorCode)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Auto-reconnect
    // ─────────────────────────────────────────────────────────────────────────

    private fun scheduleReconnect(deviceId: String) {
        val delay = reconnectDelays.getOrDefault(deviceId, RECONNECT_INITIAL_DELAY_MS)
        val nextDelay = (delay * 2).coerceAtMost(RECONNECT_MAX_DELAY_MS)
        reconnectDelays[deviceId] = nextDelay

        Log.i(TAG, "Scheduling reconnect to $deviceId in ${delay}ms")

        val runnable = Runnable {
            if (isClientActive && !connectedGatts.containsKey(deviceId)) {
                connectToDevice(deviceId)
            }
        }
        reconnectRunnables[deviceId] = runnable
        mainHandler.postDelayed(runnable, delay)
    }

    private fun cancelReconnect(deviceId: String) {
        reconnectRunnables.remove(deviceId)?.let { mainHandler.removeCallbacks(it) }
        reconnectDelays.remove(deviceId)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Flutter channel helper
    // ─────────────────────────────────────────────────────────────────────────

    private fun invokeFlutter(method: String, arguments: Any?) {
        mainHandler.post {
            channel?.invokeMethod(method, arguments)
        }
    }
}
