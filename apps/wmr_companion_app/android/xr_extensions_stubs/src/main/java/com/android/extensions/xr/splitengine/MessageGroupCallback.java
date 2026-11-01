package com.android.extensions.xr.splitengine;

/**
 * Compile-only stub of the {@code MessageGroupCallback} interface that the
 * Android XR runtime provides at run time from
 * {@code /system_ext/framework/com.android.extensions.xr.jar}.
 *
 * <p>Not packaged into the APK. It exists so R8 can resolve the callback and
 * keep {@code onMessageGroupComplete} instead of emitting an empty class, which
 * crashes with an {@link AbstractMethodError} when the split-engine renderer
 * completes a group (ONY-758, same cause as {@code function.Consumer}).
 */
public interface MessageGroupCallback {

    /** Called by the Android XR runtime when a message group completes. */
    void onMessageGroupComplete(int groupId);
}
