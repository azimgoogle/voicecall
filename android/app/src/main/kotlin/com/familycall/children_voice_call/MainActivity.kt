package com.familycall.children_voice_call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "com.familycall/audio"
    private lateinit var audioManager: AudioManager
    private var headsetReceiver: BroadcastReceiver? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    private lateinit var powerManager: PowerManager
    private lateinit var sensorManager: SensorManager
    private var proximitySensor: Sensor? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private val proximityListener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            val near = event.values[0] < (proximitySensor?.maximumRange ?: 5f)
            // Route to earpiece when near (phone at ear), speaker when far
            audioManager.isSpeakerphoneOn = !near
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
                        // Default to speaker; receiver will switch to earphone if plugged in
                        audioManager.isSpeakerphoneOn = !isWiredHeadsetOn()
                        registerHeadsetReceiver()
                        result.success(null)
                    }
                    "stopAudioSession" -> {
                        unregisterHeadsetReceiver()
                        audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
                        audioFocusRequest = null
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
                            "VoiceCall::Proximity"
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
                        // Restore speaker after proximity is released
                        audioManager.isSpeakerphoneOn = !isWiredHeadsetOn()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isWiredHeadsetOn(): Boolean {
        val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return devices.any {
            it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET ||
            it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES
        }
    }

    private fun registerHeadsetReceiver() {
        if (headsetReceiver != null) return
        headsetReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    AudioManager.ACTION_HEADSET_PLUG -> {
                        val state = intent.getIntExtra("state", -1)
                        // state 1 = plugged in, 0 = unplugged
                        audioManager.isSpeakerphoneOn = (state != 1)
                    }
                    AudioManager.ACTION_AUDIO_BECOMING_NOISY -> {
                        // Headset removed abruptly — route to speaker
                        audioManager.isSpeakerphoneOn = true
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_HEADSET_PLUG)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        }
        registerReceiver(headsetReceiver, filter)
    }

    private fun unregisterHeadsetReceiver() {
        headsetReceiver?.let {
            unregisterReceiver(it)
            headsetReceiver = null
        }
    }
}
