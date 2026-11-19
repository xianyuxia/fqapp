package com.fqapp.fqapp

import android.content.Context
import android.content.res.Configuration
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Discover remotes before their first key press and track Bluetooth reconnects. */
class RemoteInputPlugin : FlutterPlugin, InputManager.InputDeviceListener,
    EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var inputs: InputManager
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        inputs = context.getSystemService(Context.INPUT_SERVICE) as InputManager
        methods = MethodChannel(binding.binaryMessenger, "fqapp/remote_input")
        events = EventChannel(binding.binaryMessenger, "fqapp/remote_input/events")
        methods.setMethodCallHandler { call, result ->
            if (call.method == "isConnected") result.success(isConnected())
            else result.notImplemented()
        }
        events.setStreamHandler(this)
        inputs.registerInputDeviceListener(this, Handler(Looper.getMainLooper()))
    }

    private fun isConnected(): Boolean {
        val mode = context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return inputs.inputDeviceIds.any { id ->
            val device = inputs.getInputDevice(id) ?: return@any false
            if (device.isVirtual) return@any false
            val keyboard = device.supportsSource(InputDevice.SOURCE_KEYBOARD) &&
                device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
            // Phone vendors also expose internal gamepad/consumer devices.
            // Those and headset media keys must not turn on remote navigation.
            keyboard || (device.isExternal && (
                device.supportsSource(InputDevice.SOURCE_DPAD) ||
                    device.supportsSource(InputDevice.SOURCE_GAMEPAD) ||
                    device.hasKeys(
                        KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
                        KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                    ).all { it }
                ))
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        emit()
    }

    override fun onCancel(arguments: Any?) { sink = null }
    private fun emit() { sink?.success(isConnected()) }
    override fun onInputDeviceAdded(deviceId: Int) { emit() }
    override fun onInputDeviceRemoved(deviceId: Int) { emit() }
    override fun onInputDeviceChanged(deviceId: Int) { emit() }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        inputs.unregisterInputDeviceListener(this)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
    }
}
