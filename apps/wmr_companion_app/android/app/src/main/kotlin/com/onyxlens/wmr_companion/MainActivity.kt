package com.onyxlens.wmr_companion

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.onyxlens.wmr_tracking_dispatch.UnityPlayerHost
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

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
    private var installResult: MethodChannel.Result? = null
    private var installReceiver: BroadcastReceiver? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_UPDATER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                    "openUnknownSourcesSettings" -> {
                        try {
                            openUnknownSourcesSettings()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error(
                                "settings_unavailable",
                                e.message ?: "could not open the install settings",
                                null,
                            )
                        }
                    }
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /** Pre-Android 8 has no per-app unknown-sources toggle. */
    private fun canRequestPackageInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun openUnknownSourcesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
    }

    /**
     * Installs [path] as a full APK through `PackageInstaller`, then reports
     * the system's final status. The status broadcast also carries the user
     * confirmation intent, which must be started while it is pending.
     */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "installApk requires an APK path", null)
            return
        }
        if (installResult != null) {
            result.error("install_in_progress", "an install is already running", null)
            return
        }
        if (!canRequestPackageInstalls()) {
            result.error(
                "permission_denied",
                "the user has not allowed installs from this app",
                null,
            )
            return
        }
        val apk = File(path)
        if (!apk.isFile) {
            result.error("file_missing", "APK not found: $path", null)
            return
        }

        val action = "$ACTION_INSTALL_COMMIT.${UUID.randomUUID()}"
        val receiver = installStatusReceiver()
        try {
            registerInstallReceiver(receiver, action)
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: "could not register receiver", null)
            return
        }
        installReceiver = receiver
        installResult = result

        // The unified APK is ~431 MB (docs/STATUS.md), so the session write
        // must not run on the platform main thread: it would freeze the UI and
        // risk an ANR on every self-update. The status receiver was registered
        // on the main thread above and the broadcast arrives there too.
        Thread({ writeSession(apk, action) }, "app-updater-install").start()
    }

    /** Copies [apk] into a `PackageInstaller` session and commits it. */
    private fun writeSession(apk: File, action: String) {
        var sessionId = -1
        try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            sessionId = packageManager.packageInstaller.createSession(params)
            packageManager.packageInstaller.openSession(sessionId).use { session ->
                session.openWrite("base.apk", 0, apk.length()).use { out ->
                    apk.inputStream().use { it.copyTo(out) }
                    session.fsync(out)
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        PendingIntent.FLAG_MUTABLE
                    } else {
                        0
                    }
                val status = PendingIntent.getBroadcast(
                    this,
                    sessionId,
                    Intent(action).setPackage(packageName),
                    flags,
                )
                session.commit(status.intentSender)
            }
        } catch (e: Exception) {
            if (sessionId >= 0) {
                packageManager.packageInstaller.abandonSession(sessionId)
            }
            finishInstall("install_failed", e.message ?: "could not start the install")
        }
    }

    private fun installStatusReceiver(): BroadcastReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (
                    intent.getIntExtra(
                        PackageInstaller.EXTRA_STATUS,
                        PackageInstaller.STATUS_FAILURE,
                    )
                ) {
                    PackageInstaller.STATUS_SUCCESS -> finishInstall()
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        val confirmation = if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                        ) {
                            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(Intent.EXTRA_INTENT)
                        }
                        if (confirmation == null) {
                            finishInstall(
                                "install_failed",
                                "installer returned no confirmation intent",
                            )
                        } else {
                            startActivity(confirmation)
                        }
                    }
                    PackageInstaller.STATUS_FAILURE_ABORTED -> finishInstall(
                        "install_cancelled",
                        statusMessage(intent) ?: "the install was cancelled",
                    )
                    PackageInstaller.STATUS_FAILURE_BLOCKED -> finishInstall(
                        "install_blocked",
                        statusMessage(intent) ?: "the install was blocked",
                    )
                    else -> finishInstall(
                        "install_failed",
                        statusMessage(intent) ?: "the install failed",
                    )
                }
            }
        }

    private fun statusMessage(intent: Intent): String? =
        intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)

    private fun finishInstall(code: String? = null, message: String? = null) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { finishInstall(code, message) }
            return
        }
        val result = installResult ?: return
        installResult = null
        unregisterInstallReceiver()
        if (code == null) {
            result.success(null)
        } else {
            result.error(code, message, null)
        }
    }

    private fun registerInstallReceiver(receiver: BroadcastReceiver, action: String) {
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
    }

    private fun unregisterInstallReceiver() {
        val receiver = installReceiver ?: return
        installReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Already unregistered (activity torn down).
        }
    }

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
        finishInstall("install_cancelled", "the activity was destroyed")
        UnityPlayerHost.shared.onDestroy()
        super.onDestroy()
    }
}

private const val APP_UPDATER_CHANNEL = "com.onyxlens.wmr_companion/app_updater"
private const val ACTION_INSTALL_COMMIT = "com.onyxlens.wmr_companion.INSTALL_COMMIT"
