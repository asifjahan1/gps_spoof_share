package com.example.gps_spoof_share

import android.annotation.SuppressLint
import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.os.ParcelUuid
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.UUID

class SpoofService : Service() {
    private val TAG = "SpoofService"
    private val CHANNEL_ID = "SpoofServiceChannel"
    private val NOTIFICATION_ID = 1

    private lateinit var locationManager: LocationManager
    private val mockProviders = arrayOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, "fused")
    
    private var isSpoofing = false
    private var spoofJob: Job? = null
    
    private var currentLat = 37.7749
    private var currentLng = -122.4194

    // BLE Variables
    private lateinit var bluetoothManager: BluetoothManager
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gattServer: BluetoothGattServer? = null
    private var bleAdvertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null
    
    private val SERVICE_UUID = UUID.fromString("8e6c7087-0b1a-4648-9366-239617fa7259")
    private val CHAR_UUID = UUID.fromString("90b6d267-33e1-4c6e-827a-8f9f60cb0fc0")
    
    private var subscribedDevice: BluetoothDevice? = null

    private val updateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == "UPDATE_COORDINATES") {
                currentLat = intent.getDoubleExtra("lat", currentLat)
                currentLng = intent.getDoubleExtra("lng", currentLng)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        
        // Register receiver for updates from Flutter via MainActivity
        val filter = IntentFilter("UPDATE_COORDINATES")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(updateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(updateReceiver, filter)
        }
        
        setupMockProvider()
        setupBLEServer()
    }

    @SuppressLint("ForegroundServiceType")
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GPS Spoofing Active")
            .setContentText("Broadcasting location via BLE")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        startSpoofingLoop()

        return START_STICKY
    }

    private fun setupMockProvider() {
        for (provider in mockProviders) {
            try {
                locationManager.removeTestProvider(provider)
            } catch (e: Exception) {
                // Ignore if it doesn't exist
            }
            
            try {
                // 1 = Criteria.POWER_LOW, 1 = Criteria.ACCURACY_FINE
                locationManager.addTestProvider(
                    provider,
                    false, false, false, false, true,
                    true, true, 1, 1
                )
                locationManager.setTestProviderEnabled(provider, true)
                Log.i(TAG, "Successfully added and enabled test provider: $provider")
            } catch (e: SecurityException) {
                Log.e(TAG, "Mock location permission not granted for $provider", e)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to add test provider $provider. Error: ${e.message}", e)
                // If adding failed, try just enabling it in case it's already a test provider
                try {
                    locationManager.setTestProviderEnabled(provider, true)
                } catch (e2: Exception) {
                    Log.e(TAG, "Failed to enable existing provider: $provider", e2)
                }
            }
        }
    }

    private fun startSpoofingLoop() {
        isSpoofing = true
        spoofJob = CoroutineScope(Dispatchers.IO).launch {
            while (isActive && isSpoofing) {
                try {
                    val currentTime = System.currentTimeMillis()
                    val currentNanos = SystemClock.elapsedRealtimeNanos()

                    for (provider in mockProviders) {
                        try {
                            val mockLocation = Location(provider).apply {
                                latitude = currentLat
                                longitude = currentLng
                                altitude = 3.0
                                time = currentTime
                                accuracy = 1.0f
                                speed = 0.1f
                                bearing = 1.0f
                                elapsedRealtimeNanos = currentNanos
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    bearingAccuracyDegrees = 0.1f
                                    speedAccuracyMetersPerSecond = 0.1f
                                    verticalAccuracyMeters = 0.1f
                                }
                            }
                            
                            try {
                                val method = Location::class.java.getMethod("makeComplete")
                                method.invoke(mockLocation)
                            } catch (e: Exception) {
                                // Ignore
                            }
                            
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                mockLocation.isMock = true
                            }
                            
                            locationManager.setTestProviderLocation(provider, mockLocation)
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to set location for $provider", e)
                        }
                    }
                    
                    val packet = JSONObject().apply {
                        put("lat", currentLat)
                        put("lng", currentLng)
                        put("ts", currentTime)
                    }.toString().toByteArray(Charsets.UTF_8)
                    
                    broadcastBLE(packet)
                    
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to set mock location", e)
                }
                delay(1000) // 1 second interval
            }
        }
    }

    override fun onDestroy() {
        isSpoofing = false
        spoofJob?.cancel()
        for (provider in mockProviders) {
            try {
                locationManager.removeTestProvider(provider)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to remove test provider: $provider", e)
            }
        }
        stopBLEServer()
        unregisterReceiver(updateReceiver)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Spoof Service Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    @SuppressLint("MissingPermission")
    private fun setupBLEServer() {
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager.adapter
        
        if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) return

        gattServer = bluetoothManager.openGattServer(this, gattServerCallback)
        
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val characteristic = BluetoothGattCharacteristic(
            CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        val descriptor = BluetoothGattDescriptor(cccdUuid, BluetoothGattDescriptor.PERMISSION_WRITE or BluetoothGattDescriptor.PERMISSION_READ)
        characteristic.addDescriptor(descriptor)
        service.addCharacteristic(characteristic)
        gattServer?.addService(service)

        startAdvertising()
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising() {
        bleAdvertiser = bluetoothAdapter?.bluetoothLeAdvertiser
        if (bleAdvertiser == null) return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        bleAdvertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            Log.i(TAG, "BLE Advertise Started.")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "BLE Advertise Failed: $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                subscribedDevice = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (subscribedDevice?.address == device.address) {
                    subscribedDevice = null
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun broadcastBLE(data: ByteArray) {
        val device = subscribedDevice ?: return
        val service = gattServer?.getService(SERVICE_UUID)
        val characteristic = service?.getCharacteristic(CHAR_UUID) ?: return
        
        characteristic.value = data
        gattServer?.notifyCharacteristicChanged(device, characteristic, false)
    }

    @SuppressLint("MissingPermission")
    private fun stopBLEServer() {
        bleAdvertiser?.stopAdvertising(advertiseCallback)
        gattServer?.close()
    }
}
