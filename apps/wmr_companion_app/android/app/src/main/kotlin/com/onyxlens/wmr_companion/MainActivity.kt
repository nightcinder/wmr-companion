package com.onyxlens.wmr_companion

import android.content.res.Configuration
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/**
 * Flutter host activity that can also own the shared Unity player.
 *
 * A VITURE source start attaches the player behind this activity's Flutter
 * view (ONY-748), so the bench and debug screens stay visible instead of being
 * covered by an opaque Unity surface. The Unity player is a second Android
 * view with its own lifecycle, so every activity lifecycle callback Unity
 * relies on is forwarded while it is hosted; a Flutter-only session is
 * untouched.
 */
class MainActivity : FlutterActivity() {
    /**
     * Draws Flutter into a `FlutterTextureView` rather than an opaque
     * `FlutterSurfaceView`, and lets the window show what is behind it.
     *
     * The shared Unity player already sits behind the Flutter view (ONY-748).
     * Two stacked surface views let the opaque Flutter surface cover - and on
     * the VITURE XR path starve - the Unity surface the XR loader renders into,
     * so the loader reports a 2D player and 6DoF disappears (ONY-767). Texture
     * mode keeps the Unity surface composited underneath while the Flutter UI
     * stays in front.
     */
    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

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
