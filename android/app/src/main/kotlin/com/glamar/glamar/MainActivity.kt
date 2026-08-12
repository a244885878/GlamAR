package com.glamar.glamar

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var openGlMakeupBridge: OpenGlMakeupBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        openGlMakeupBridge = OpenGlMakeupBridge(flutterEngine, this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        openGlMakeupBridge?.dispose()
        openGlMakeupBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
