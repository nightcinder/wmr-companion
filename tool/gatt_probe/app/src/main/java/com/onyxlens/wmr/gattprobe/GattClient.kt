package com.onyxlens.wmr.gattprobe

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

enum class StreamMode {
    NONE,
    BATCHED
}

enum class GattState {
    DISCONNECTED,
    CONNECTING,
    NEGOTIATING_MTU,
    DISCOVERING_SERVICES,
    SUBSCRIBING,
    READY
}

@SuppressLint("MissingPermission")
class GattClient(
    private val context: Context,
    private val listener: Listener
) {
    interface Listener {
        fun onStateChanged(state: GattState, message: String)
        fun onMtuNegotiated(mtu: Int)
        fun onPriorityGranted(granted: Boolean)
        fun onRssiRead(rssi: Int)
        fun onIntervalUpdated(intervalUs: Int)
        fun onEchoSample(sample: EchoSample)
        fun onEchoTimeout(pingId: Int)
        fun onEchoFailure(pingId: Int)
        fun onEchoLateOrDuplicate(pingId: Int)
        fun onEchoBadAnswer()
        fun onDecodedRecord(record: Protocol.DecodedRecord, arrivalUs: Long)
        fun onError(message: String)
    }

    companion object {
        private const val TAG = "GattClient"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var state = GattState.DISCONNECTED

    var streamMode = StreamMode.BATCHED

    var negotiatedMtu: Int? = null
        private set
    var priorityRequested: Boolean? = null
        private set
    var lastRssi: Int? = null
        private set
    var connectionIntervalUs: Int? = null
        private set

    private var echoChar: BluetoothGattCharacteristic? = null
    private var batchedChar: BluetoothGattCharacteristic? = null

    // Pending ping tracking
    private data class PendingPing(
        val id: Int,
        val t1Us: Long,
        var t1DoneUs: Long = 0L
    )

    private var currentPendingPing: PendingPing? = null
    private var pingTimeoutRunnable: Runnable? = null

    // End of run RSSI latch
    private var rssiLatch: CountDownLatch? = null

    val isReady: Boolean get() = state == GattState.READY

    fun connect(device: BluetoothDevice) {
        disconnect()
        updateState(GattState.CONNECTING, "Connecting to ${device.name ?: device.address}...")
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, gattCallback)
        }
    }

    fun disconnect() {
        cancelPendingPing()
        val g = gatt
        gatt = null
        if (g != null) {
            try {
                g.disconnect()
                g.close()
            } catch (e: Exception) {
                Log.w(TAG, "Error closing gatt", e)
            }
        }
        echoChar = null
        batchedChar = null
        negotiatedMtu = null
        priorityRequested = null
        connectionIntervalUs = null
        updateState(GattState.DISCONNECTED, "Disconnected")
    }

    private fun updateState(newState: GattState, message: String) {
        state = newState
        mainHandler.post { listener.onStateChanged(newState, message) }
    }

    fun readRssiSafe(timeoutMs: Long = 1500L): Int? {
        val currentGatt = gatt ?: return lastRssi
        val latch = CountDownLatch(1)
        rssiLatch = latch
        try {
            val started = currentGatt.readRemoteRssi()
            if (!started) {
                rssiLatch = null
                return lastRssi
            }
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "Interrupted reading RSSI", e)
        } finally {
            rssiLatch = null
        }
        return lastRssi
    }

    fun sendPing(pingId: Int, timeoutMs: Long = 1000L): Boolean {
        val currentGatt = gatt ?: return false
        val char = echoChar ?: return false

        val t1Us = SystemClock.elapsedRealtimeNanos() / 1000L

        synchronized(this) {
            if (currentPendingPing != null) {
                // Client busy: ping skipped
                return false
            }
            currentPendingPing = PendingPing(pingId, t1Us)
        }

        val requestBytes = Protocol.encodeEchoRequest(pingId)
        val writeSuccess: Boolean = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val res = currentGatt.writeCharacteristic(
                    char,
                    requestBytes,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                )
                res == BluetoothGatt.GATT_SUCCESS
            } else {
                char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                char.value = requestBytes
                currentGatt.writeCharacteristic(char)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception writing echo ping", e)
            false
        }

        val t1DoneUs = SystemClock.elapsedRealtimeNanos() / 1000L
        synchronized(this) {
            val pending = currentPendingPing
            if (pending != null && pending.id == pingId) {
                if (writeSuccess) {
                    pending.t1DoneUs = t1DoneUs
                } else {
                    currentPendingPing = null
                }
            }
        }

        if (!writeSuccess) {
            mainHandler.post { listener.onEchoFailure(pingId) }
            return false
        }

        // Schedule timeout
        val timeoutTask = Runnable {
            var timedOut = false
            synchronized(this@GattClient) {
                if (currentPendingPing?.id == pingId) {
                    currentPendingPing = null
                    timedOut = true
                }
            }
            if (timedOut) {
                mainHandler.post { listener.onEchoTimeout(pingId) }
            }
        }
        pingTimeoutRunnable = timeoutTask
        mainHandler.postDelayed(timeoutTask, timeoutMs)
        return true
    }

    private fun cancelPendingPing() {
        synchronized(this) {
            currentPendingPing = null
            pingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            pingTimeoutRunnable = null
        }
    }

    private fun writeDescriptor(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, value: ByteArray): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS
            } else {
                descriptor.value = value
                gatt.writeDescriptor(descriptor)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error writing descriptor", e)
            false
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        private var subscribingToBatched = false

        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                updateState(GattState.DISCONNECTED, "Link failed with status $status")
                disconnect()
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                updateState(GattState.NEGOTIATING_MTU, "Connected. Requesting MTU ${Protocol.REQUESTED_MTU}...")
                val ok = gatt.requestMtu(Protocol.REQUESTED_MTU)
                if (!ok) {
                    Log.w(TAG, "requestMtu returned false, proceeding to service discovery")
                    onMtuChanged(gatt, 23, BluetoothGatt.GATT_SUCCESS)
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                updateState(GattState.DISCONNECTED, "Device disconnected")
                disconnect()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            negotiatedMtu = mtu
            mainHandler.post { listener.onMtuNegotiated(mtu) }
            val reqPriorityOk = gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
            priorityRequested = reqPriorityOk
            mainHandler.post { listener.onPriorityGranted(reqPriorityOk) }

            updateState(GattState.DISCOVERING_SERVICES, "MTU $mtu negotiated. Discovering services...")
            gatt.discoverServices()
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                updateState(GattState.DISCONNECTED, "Service discovery failed: $status")
                return
            }

            val service = gatt.getService(Protocol.WMR_SERVICE_UUID)
            if (service == null) {
                updateState(GattState.DISCONNECTED, "WMR service 0xFF10 not found")
                return
            }

            echoChar = service.getCharacteristic(Protocol.WMR_ECHO_CHAR_UUID)
            batchedChar = service.getCharacteristic(Protocol.WMR_BATCHED_CHAR_UUID)

            if (echoChar == null) {
                updateState(GattState.DISCONNECTED, "Echo characteristic 0xFF15 not found")
                return
            }

            // Read start RSSI
            gatt.readRemoteRssi()

            // Begin CCC subscriptions: start with FF15
            updateState(GattState.SUBSCRIBING, "Subscribing to FF15 echo...")
            subscribingToBatched = false
            gatt.setCharacteristicNotification(echoChar, true)
            val ccc = echoChar?.getDescriptor(Protocol.CCC_DESCRIPTOR_UUID)
            if (ccc != null) {
                val ok = writeDescriptor(gatt, ccc, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                if (!ok) {
                    updateState(GattState.DISCONNECTED, "Failed to initiate FF15 descriptor write")
                }
            } else {
                updateState(GattState.DISCONNECTED, "CCC descriptor for FF15 not found")
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                updateState(GattState.DISCONNECTED, "Descriptor write failed with status $status")
                return
            }

            if (!subscribingToBatched && streamMode == StreamMode.BATCHED) {
                // FF15 subscribed. Now subscribe to FF14
                val bChar = batchedChar
                if (bChar != null) {
                    subscribingToBatched = true
                    updateState(GattState.SUBSCRIBING, "Subscribing to FF14 batched...")
                    gatt.setCharacteristicNotification(bChar, true)
                    val bCcc = bChar.getDescriptor(Protocol.CCC_DESCRIPTOR_UUID)
                    if (bCcc != null) {
                        val ok = writeDescriptor(gatt, bCcc, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                        if (!ok) {
                            updateState(GattState.DISCONNECTED, "Failed to initiate FF14 descriptor write")
                        }
                        return
                    }
                }
            }

            // All requested subscriptions completed
            updateState(GattState.READY, "Probe Ready (MTU: ${negotiatedMtu ?: "?"}, Stream: ${streamMode.name})")
        }

        // Available on Android 8.0+ (API 26+)
        fun onConnectionUpdated(
            gatt: BluetoothGatt,
            interval: Int,
            latency: Int,
            timeout: Int,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val intervalUs = interval * 1250 // 1.25 ms per interval unit
                connectionIntervalUs = intervalUs
                mainHandler.post { listener.onIntervalUpdated(intervalUs) }
            }
        }

        // For Android 13+ (API 33+)
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            handleNotification(characteristic.uuid, value)
        }

        // For Android 12 and below
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            val value = characteristic.value ?: return
            handleNotification(characteristic.uuid, value)
        }

        private fun handleNotification(uuid: java.util.UUID, value: ByteArray) {
            // First operation: capture nanosecond arrival time as early as possible
            val arrivalNanos = SystemClock.elapsedRealtimeNanos()
            val arrivalUs = arrivalNanos / 1000L

            if (uuid == Protocol.WMR_ECHO_CHAR_UUID) {
                when (val res = Protocol.parseEchoAnswer(value)) {
                    is Protocol.EchoParseResult.Ok -> {
                        val answer = res.answer
                        var matchedSample: EchoSample? = null
                        var isLateOrDup = false
                        synchronized(this@GattClient) {
                            val pending = currentPendingPing
                            if (pending != null && pending.id == answer.pingId) {
                                matchedSample = EchoSample(
                                    t1Us = pending.t1Us,
                                    t1DoneUs = pending.t1DoneUs,
                                    t4Us = arrivalUs,
                                    answer = answer
                                )
                                currentPendingPing = null
                                pingTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                                pingTimeoutRunnable = null
                            } else {
                                isLateOrDup = true
                            }
                        }
                        if (matchedSample != null) {
                            mainHandler.post { listener.onEchoSample(matchedSample!!) }
                        } else if (isLateOrDup) {
                            mainHandler.post { listener.onEchoLateOrDuplicate(answer.pingId) }
                        }
                    }
                    is Protocol.EchoParseResult.Error -> {
                        Log.w(TAG, "Echo parse error: ${res.reason}")
                        mainHandler.post { listener.onEchoBadAnswer() }
                    }
                }
            } else if (uuid == Protocol.WMR_BATCHED_CHAR_UUID) {
                when (val res = Protocol.parseDecodedBatch(value)) {
                    is Protocol.BatchParseResult.Ok -> {
                        for (rec in res.records) {
                            listener.onDecodedRecord(rec, arrivalUs)
                        }
                    }
                    is Protocol.BatchParseResult.Error -> {
                        Log.w(TAG, "Batch parse error: ${res.reason}")
                    }
                }
            }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                lastRssi = rssi
                mainHandler.post { listener.onRssiRead(rssi) }
            }
            rssiLatch?.countDown()
        }
    }
}
