package com.android.extensions.xr.function;

/**
 * Compile-only stub of the {@code com.android.extensions.xr.function.Consumer}
 * interface that the Android XR runtime provides at run time from
 * {@code /system_ext/framework/com.android.extensions.xr.jar}.
 *
 * <p>Nothing here is packaged into the APK. The stub exists only on the R8
 * classpath, because without it R8 sees the interface as a missing class, does
 * not treat {@code accept} as an interface method, and emits the
 * {@code androidx.xr} callbacks as empty classes. The device then calls
 * {@code Consumer.accept} and the process dies with an
 * {@link AbstractMethodError} as soon as the Android XR session starts
 * (ONY-758).
 *
 * @param <T> the value the runtime hands to the callback
 */
public interface Consumer<T> {

    /** Called by the Android XR runtime. */
    void accept(T value);
}
