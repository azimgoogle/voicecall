package com.zunova.nestcall

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "com.zunova.nestcall/audio"
    private lateinit var audioManager: AudioManager
    private var noisyReceiver: BroadcastReceiver? = null
    private var scoReceiver: BroadcastReceiver? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioSessionActive = false

    private lateinit var powerManager: PowerManager
    private lateinit var sensorManager: SensorManager
    private var proximitySensor: Sensor? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Fires immediately on registerAudioDeviceCallback with all currently-connected
    // devices — this handles the "already connected at call start" case reliably.
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
            if (audioSessionActive) applyCurrentRouting()
        }
        override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
            if (audioSessionActive) applyCurrentRouting()
        }
    }

    private val proximityListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val near = event.values[0] < (proximitySensor?.maximumRange ?: 5f)
            mainHandler.post {
                // Only switch speaker/earpiece when no headset of any kind is connected.
                if (!isAnyHeadsetConnected()) {
                    audioManager.isSpeakerphoneOn = !near
                }
            }
        }
        override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        proximitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_PROXIMITY)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startAudioSession" -> {
                        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                            .setOnAudioFocusChangeListener {}
                            .build()
                        audioFocusRequest = focusRequest
                        audioManager.requestAudioFocus(focusRequest)

                        audioSessionActive = true
                        // AudioDeviceCallback fires immediately with all currently-connected
                        // output devices, so already-connected headphones are handled here
                        // without needing to rely on a sticky broadcast.
                        audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
                        registerNoisyReceiver()
                        registerScoReceiver()
                        result.success(null)
                    }
                    "stopAudioSession" -> {
                        audioSessionActive = false
                        audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
                        unregisterNoisyReceiver()
                        unregisterScoReceiver()
                        audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
                        audioFocusRequest = null
                        audioManager.stopBluetoothSco()
                        audioManager.isSpeakerphoneOn = false
                        audioManager.mode = AudioManager.MODE_NORMAL
                        result.success(null)
                    }
                    "acquireProximityWakeLock" -> {
                        val sensor = proximitySensor
                        if (sensor != null) {
                            sensorManager.registerListener(
                                proximityListener, sensor,
                                SensorManager.SENSOR_DELAY_NORMAL
                            )
                        }
                        @Suppress("DEPRECATION")
                        val wl = powerManager.newWakeLock(
                            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                            "NestCall::Proximity"
                        )
                        wl.acquire(10 * 60 * 1000L) // 10 min max
                        proximityWakeLock = wl
                        result.success(null)
                    }
                    "releaseProximityWakeLock" -> {
                        sensorManager.unregisterListener(proximityListener)
                        val wl = proximityWakeLock
                        if (wl != null && wl.isHeld) wl.release()
                        proximityWakeLock = null
                        mainHandler.post { applyCurrentRouting() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Single place that decides how audio is routed.
    // Priority: Bluetooth SCO > wired/USB headset > speaker.
    private fun applyCurrentRouting() {
        when {
            isBluetoothHeadsetConnected() -> {
                audioManager.isSpeakerphoneOn = false
                audioManager.startBluetoothSco()
            }
            isWiredHeadsetConnected() -> {
                audioManager.stopBluetoothSco()
                audioManager.isSpeakerphoneOn = false
            }
            else -> {
                audioManager.stopBluetoothSco()
                audioManager.isSpeakerphoneOn = true
            }
        }
    }

    private fun isWiredHeadsetConnected(): Boolean {
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.any {
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
            it.type == AudioDeviceInfo.TYPE_USB_HEADSET
        }
    }

    private fun isBluetoothHeadsetConnected(): Boolean {
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
    }

    private fun isAnyHeadsetConnected() = isWiredHeadsetConnected() || isBluetoothHeadsetConnected()

    // Handles abrupt headset removal — fires before getDevices() reflects the removal,
    // so we keep this receiver in addition to AudioDeviceCallback.
    private fun registerNoisyReceiver() {
        if (noisyReceiver != null) return
        noisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    audioManager.isSpeakerphoneOn = true
                }
            }
        }
        registerReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
    }

    private fun unregisterNoisyReceiver() {
        noisyReceiver?.let { unregisterReceiver(it); noisyReceiver = null }
    }

    // Tracks Bluetooth SCO connection state so we can confirm routing once
    // SCO is actually established (startBluetoothSco is asynchronous).
    private fun registerScoReceiver() {
        if (scoReceiver != null) return
        scoReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED) return
                when (intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> {
                        audioManager.isSpeakerphoneOn = false
                    }
                    AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> {
                        if (!isWiredHeadsetConnected()) {
                            audioManager.isSpeakerphoneOn = true
                        }
                    }
                }
            }
        }
        registerReceiver(scoReceiver, IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED))
    }

    private fun unregisterScoReceiver() {
        scoReceiver?.let { unregisterReceiver(it); scoReceiver = null }
    }
}
