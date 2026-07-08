package com.example.gps_spoof_share

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Bundle
import android.net.wifi.WifiManager
import android.content.Context

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.gpsspoofshare/native_bridge"
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Acquire Multicast lock to allow mDNS / Bonjour discovery in Python (zeroconf)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("zeroconfLock")
        multicastLock?.setReferenceCounted(true)
        multicastLock?.acquire()
    }

    override fun onDestroy() {
        super.onDestroy()
        multicastLock?.release()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startSpoofing" -> {
                    if (isMockLocationEnabled()) {
                        startSpoofService()
                        result.success("Service Started")
                    } else {
                        result.error("MOCK_LOCATION_NOT_ENABLED", "Please select this app as the Mock Location app in Developer Options.", null)
                    }
                }
                "stopSpoofing" -> {
                    stopSpoofService()
                    result.success("Service Stopped")
                }
                "updateSpoofLocation" -> {
                    val lat = call.argument<Double>("lat") ?: 0.0
                    val lng = call.argument<Double>("lng") ?: 0.0
                    val intent = Intent("UPDATE_COORDINATES")
                    intent.setPackage(packageName)
                    intent.putExtra("lat", lat)
                    intent.putExtra("lng", lng)
                    sendBroadcast(intent)
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startSpoofService() {
        val serviceIntent = Intent(this, SpoofService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopSpoofService() {
        val serviceIntent = Intent(this, SpoofService::class.java)
        stopService(serviceIntent)
    }

    private fun isMockLocationEnabled(): Boolean {
        var isMockLocation = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val opsManager = getSystemService(android.content.Context.APP_OPS_SERVICE) as android.app.AppOpsManager
                isMockLocation = (opsManager.checkOp("android:mock_location", android.os.Process.myUid(), packageName) == android.app.AppOpsManager.MODE_ALLOWED)
            } else {
                isMockLocation = (android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ALLOW_MOCK_LOCATION) == "1")
            }
        } catch (e: Exception) {
            return false
        }
        return isMockLocation
    }
}
