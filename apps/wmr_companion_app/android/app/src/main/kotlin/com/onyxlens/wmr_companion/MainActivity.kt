package com.onyxlens.wmr_companion

import android.content.res.Configuration
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.embedding.android.FlutterActivity

/**
 * Flutter host activity that can also own the shared Unity player.
 *
 * A VITURE source start attaches the player full-screen over this activity's
 * Flutter view (ONY-612). The Unity player is a second Android view with its
 * own lifecycle, so every activity lifecycle callback Unity relies on is
 * forwarded while it is hosted; a Flutter-only session is untouched.
 */
class MainActivity : FlutterActivity() {
    override fun onResume() {
        super.onResume()
        UnityPlayerHost.shared.onResume()
    }

    override fun onPause() {
        UnityPlayerHost.shared.onPause()
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        UnityPlayerHost.shared.onWindowFocusChanged(hasFocus)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        UnityPlayerHost.shared.onConfigurationChanged(newConfig)
    }

    override fun onDestroy() {
        UnityPlayerHost.shared.onDestroy()
        super.onDestroy()
    }
}
