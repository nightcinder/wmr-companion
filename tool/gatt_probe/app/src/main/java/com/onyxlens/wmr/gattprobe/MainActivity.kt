package com.onyxlens.wmr.gattprobe

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import android.widget.Button
import android.widget.CheckBox
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Date
import java.util.Locale

@SuppressLint("MissingPermission")
class MainActivity : AppCompatActivity(), GattClient.Listener {

    companion object {
        private const val TAG = "MainActivity"
        private const val DEFAULT_RUN_DURATION_SEC = 120
    }

    private lateinit var tvConnectionStatus: TextView
    private lateinit var tvRunMetrics: TextView
    private lateinit var tvSummary: TextView
    private lateinit var btnConnect: Button
    private lateinit var btnDisconnect: Button
    private lateinit var btnStartRun: Button
    private lateinit var btnStopRun: Button
    private lateinit var btnShare: Button
    private lateinit var rgStream: RadioGroup
    private lateinit var rbStreamBatched: RadioButton
    private lateinit var rgInterval: RadioGroup
    private lateinit var rbInterval50: RadioButton
    private lateinit var rbInterval250: RadioButton
    private lateinit var rbInterval1000: RadioButton
    private lateinit var cbTwoBridges: CheckBox

    private val mainHandler = Handler(Looper.getMainLooper())
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var gattClient: GattClient? = null
    private var isScanning = false

    private var targetDevice: BluetoothDevice? = null

    // Run measurement state
    private var isRunInProgress = false
    private var runStartTimeNanos: Long = 0L
    private var runDurationSec = DEFAULT_RUN_DURATION_SEC
    private var currentRecorder: LatencyRecorder? = null
    private var pingTimerHandler = Handler(Looper.getMainLooper())
    private var pingRunnable: Runnable? = null
    private var nextPingId = 1
    private var selectedIntervalMs = 250L

    // Snapshotted at run start to prevent mid-run UI changes from altering report
    private var runStartRssi: Int? = null
    private var runStreamStr: String = "batched"
    private var runEchoIntervalUs: Long = 250000L

    private var lastExportedJsonFile: File? = null
    private var lastExportedEchoFile: File? = null
    private var lastExportedSamplesFile: File? = null

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.entries.all { it.value }
        if (allGranted) {
            startScanOrConnect()
        } else {
            Toast.makeText(this, "Bluetooth permissions required for probe", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        tvConnectionStatus = findViewById(R.id.tvConnectionStatus)
        tvRunMetrics = findViewById(R.id.tvRunMetrics)
        tvSummary = findViewById(R.id.tvSummary)
        btnConnect = findViewById(R.id.btnConnect)
        btnDisconnect = findViewById(R.id.btnDisconnect)
        btnStartRun = findViewById(R.id.btnStartRun)
        btnStopRun = findViewById(R.id.btnStopRun)
        btnShare = findViewById(R.id.btnShare)
        rgStream = findViewById(R.id.rgStream)
        rbStreamBatched = findViewById(R.id.rbStreamBatched)
        rgInterval = findViewById(R.id.rgInterval)
        rbInterval50 = findViewById(R.id.rbInterval50)
        rbInterval250 = findViewById(R.id.rbInterval250)
        rbInterval1000 = findViewById(R.id.rbInterval1000)
        cbTwoBridges = findViewById(R.id.cbTwoBridges)

        val bm = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bm.adapter
        gattClient = GattClient(this, this)

        setupListeners()
    }

    private fun setupListeners() {
        btnConnect.setOnClickListener {
            checkPermissionsAndConnect()
        }

        btnDisconnect.setOnClickListener {
            stopRun(userCancelled = true)
            gattClient?.disconnect()
        }

        btnStartRun.setOnClickListener {
            startRun()
        }

        btnStopRun.setOnClickListener {
            stopRun(userCancelled = true)
        }

        btnShare.setOnClickListener {
            shareResults()
        }

        rgStream.setOnCheckedChangeListener { _, checkedId ->
            val mode = if (checkedId == R.id.rbStreamBatched) StreamMode.BATCHED else StreamMode.NONE
            gattClient?.streamMode = mode
        }

        rgInterval.setOnCheckedChangeListener { _, checkedId ->
            selectedIntervalMs = when (checkedId) {
                R.id.rbInterval50 -> 50L
                R.id.rbInterval1000 -> 1000L
                else -> 250L
            }
        }

        cbTwoBridges.setOnCheckedChangeListener { _, isChecked ->
            Log.i(TAG, "Dual-bridge mode: $isChecked")
            if (isChecked) {
                Toast.makeText(this, "Dual-bridge mode selected (connects primary bridge)", Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun checkPermissionsAndConnect() {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        } else {
            startScanOrConnect()
        }
    }

    private fun startScanOrConnect() {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) {
            Toast.makeText(this, "Please enable Bluetooth first", Toast.LENGTH_SHORT).show()
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            Toast.makeText(this, "BLE Scanner unavailable", Toast.LENGTH_SHORT).show()
            return
        }

        tvConnectionStatus.text = "Status: Scanning for WMR Bridge..."
        btnConnect.isEnabled = false
        isScanning = true

        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(ParcelUuid(Protocol.WMR_SERVICE_UUID))
                .build(),
            ScanFilter.Builder()
                .setDeviceName(Protocol.WMR_BRIDGE_NAME)
                .build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(filters, settings, scanCallback)

        // Stop scan after 10 s timeout
        mainHandler.postDelayed({
            if (isScanning) {
                isScanning = false
                try {
                    scanner.stopScan(scanCallback)
                } catch (e: Exception) {
                    Log.w(TAG, "Error stopping scan", e)
                }
                btnConnect.isEnabled = true
                if (targetDevice == null) {
                    tvConnectionStatus.text = "Status: Scan timed out (Bridge not found)"
                }
            }
        }, 10000L)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val name = result.scanRecord?.deviceName ?: device.name ?: ""
            if (name.contains("WMR Bridge", ignoreCase = true) ||
                result.scanRecord?.serviceUuids?.any { it.uuid == Protocol.WMR_SERVICE_UUID } == true
            ) {
                if (isScanning) {
                    isScanning = false
                    try {
                        bluetoothAdapter?.bluetoothLeScanner?.stopScan(this)
                    } catch (e: Exception) {
                        Log.w(TAG, "Error stopping scan", e)
                    }
                    targetDevice = device
                    tvConnectionStatus.text = "Found ${device.name ?: "Bridge"}. Connecting..."
                    val client = gattClient ?: return
                    client.streamMode = if (rbStreamBatched.isChecked) StreamMode.BATCHED else StreamMode.NONE
                    client.connect(device)
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            isScanning = false
            btnConnect.isEnabled = true
            tvConnectionStatus.text = "Scan failed with error $errorCode"
        }
    }

    // GattClient.Listener implementations
    override fun onStateChanged(state: GattState, message: String) {
        tvConnectionStatus.text = "Status: $message"
        when (state) {
            GattState.READY -> {
                btnConnect.isEnabled = false
                btnDisconnect.isEnabled = true
                btnStartRun.isEnabled = !isRunInProgress
            }
            GattState.DISCONNECTED -> {
                btnConnect.isEnabled = true
                btnDisconnect.isEnabled = false
                btnStartRun.isEnabled = false
                if (isRunInProgress) {
                    stopRun(userCancelled = true)
                }
            }
            else -> {
                btnConnect.isEnabled = false
                btnDisconnect.isEnabled = true
                btnStartRun.isEnabled = false
            }
        }
    }

    override fun onMtuNegotiated(mtu: Int) {
        Log.i(TAG, "MTU Negotiated: $mtu")
    }

    override fun onPriorityGranted(granted: Boolean) {
        Log.i(TAG, "Priority Granted: $granted")
    }

    override fun onRssiRead(rssi: Int) {
        Log.i(TAG, "RSSI Read: $rssi dBm")
    }

    override fun onIntervalUpdated(intervalUs: Int) {
        Log.i(TAG, "Interval Updated: ${intervalUs / 1000.0} ms")
    }

    override fun onEchoSample(sample: EchoSample) {
        if (isRunInProgress) {
            currentRecorder?.addEcho(sample)
        }
    }

    override fun onEchoTimeout(pingId: Int) {
        if (isRunInProgress) {
            currentRecorder?.addEchoTimeout()
        }
    }

    override fun onEchoFailure(pingId: Int) {
        if (isRunInProgress) {
            currentRecorder?.addEchoFailure()
        }
    }

    override fun onEchoLateOrDuplicate(pingId: Int) {
        if (isRunInProgress) {
            currentRecorder?.addEchoLateOrDuplicate()
        }
    }

    override fun onEchoBadAnswer() {
        if (isRunInProgress) {
            currentRecorder?.addEchoBadAnswer()
        }
    }

    override fun onDecodedRecord(record: Protocol.DecodedRecord, arrivalUs: Long) {
        if (isRunInProgress) {
            currentRecorder?.addRecord(
                hand = record.hand,
                sequence = record.sequence,
                arrivalUs = arrivalUs,
                deviceTicks = record.deviceTicks,
                espRxUs = record.rxTimeUs
            )
        }
    }

    override fun onError(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun startRun() {
        val client = gattClient ?: return
        if (!client.isReady) {
            Toast.makeText(this, "GATT not ready", Toast.LENGTH_SHORT).show()
            return
        }

        isRunInProgress = true
        btnStartRun.isEnabled = false
        btnStopRun.isEnabled = true
        btnShare.isEnabled = false
        tvSummary.text = "Measurement run in progress..."

        val nowIso = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            DateTimeFormatter.ISO_INSTANT.format(Instant.now())
        } else {
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).format(Date())
        }

        runStartTimeNanos = SystemClock.elapsedRealtimeNanos()
        val originUs = runStartTimeNanos / 1000L

        // Snapshot parameters at start of run
        runStartRssi = client.lastRssi
        runStreamStr = if (rbStreamBatched.isChecked) "batched" else "none"
        runEchoIntervalUs = selectedIntervalMs * 1000L

        currentRecorder = LatencyRecorder(
            started = nowIso,
            originUs = originUs,
            stream = runStreamStr
        ).apply {
            useEcho()
        }

        nextPingId = 1
        schedulePings()
        startLiveMetricsUpdater()
    }

    private fun schedulePings() {
        val interval = selectedIntervalMs
        val pingTask = object : Runnable {
            override fun run() {
                if (!isRunInProgress) return
                val client = gattClient
                val recorder = currentRecorder
                if (client != null && recorder != null) {
                    val id = nextPingId
                    nextPingId = (nextPingId + 1) and 0xFFFF
                    val ok = client.sendPing(id, timeoutMs = 1000L)
                    if (!ok) {
                        recorder.addEchoSkipped()
                    }
                }
                pingTimerHandler.postDelayed(this, interval)
            }
        }
        pingRunnable = pingTask
        pingTimerHandler.post(pingTask)
    }

    private fun startLiveMetricsUpdater() {
        val updater = object : Runnable {
            override fun run() {
                if (!isRunInProgress) return
                val elapsedSec = ((SystemClock.elapsedRealtimeNanos() - runStartTimeNanos) / 1_000_000_000L).toInt()
                val recorder = currentRecorder

                if (recorder != null) {
                    val echoCount = recorder.echoRows.size
                    tvRunMetrics.text = String.format(
                        Locale.US,
                        "Run: %d / %d s | Echo answers: %d | Records dropped: %d",
                        elapsedSec,
                        runDurationSec,
                        echoCount,
                        recorder.rowsDropped
                    )
                }

                if (elapsedSec >= runDurationSec) {
                    stopRun(userCancelled = false)
                } else {
                    mainHandler.postDelayed(this, 500L)
                }
            }
        }
        mainHandler.post(updater)
    }

    private fun stopRun(userCancelled: Boolean) {
        if (!isRunInProgress) return
        isRunInProgress = false

        pingRunnable?.let { pingTimerHandler.removeCallbacks(it) }
        pingRunnable = null

        btnStartRun.isEnabled = gattClient?.isReady == true
        btnStopRun.isEnabled = false

        val recorder = currentRecorder ?: return
        val endNanos = SystemClock.elapsedRealtimeNanos()
        val nowUs = endNanos / 1000L

        // Read end RSSI with safe timeout
        val endRssi = gattClient?.readRssiSafe(1500L)

        val link = LatencyLink(
            mtu = gattClient?.negotiatedMtu,
            rssiStart = runStartRssi,
            rssiEnd = endRssi,
            connectionIntervalUs = gattClient?.connectionIntervalUs,
            highPriorityRequested = gattClient?.priorityRequested
        )

        val report = recorder.report(
            nowUs = nowUs,
            link = link,
            echoIntervalUs = runEchoIntervalUs
        )

        val jsonString = JsonWriter.toJsonString(report)
        val echoCsvString = recorder.toEchoCsv()
        val samplesCsvString = recorder.toSamplesCsv()

        exportFiles(jsonString, echoCsvString, samplesCsvString)

        tvSummary.text = jsonString
        btnShare.isEnabled = true
        tvRunMetrics.text = if (userCancelled) "Run cancelled by user." else "Run finished successfully (120 s)."
    }

    private fun exportFiles(jsonContent: String, echoContent: String, samplesContent: String) {
        val timeStamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val dir = getExternalFilesDir(null) ?: filesDir

        val jsonFile = File(dir, "latency-$timeStamp.json")
        val echoFile = File(dir, "latency-$timeStamp-echo.csv")
        val samplesFile = File(dir, "latency-$timeStamp-samples.csv")

        try {
            FileWriter(jsonFile).use { it.write(jsonContent) }
            FileWriter(echoFile).use { it.write(echoContent) }
            FileWriter(samplesFile).use { it.write(samplesContent) }

            lastExportedJsonFile = jsonFile
            lastExportedEchoFile = echoFile
            lastExportedSamplesFile = samplesFile

            Log.i(TAG, "Exported probe files to: ${jsonFile.absolutePath}")
            Toast.makeText(this, "Files exported to: ${jsonFile.name}", Toast.LENGTH_LONG).show()
        } catch (e: Exception) {
            Log.e(TAG, "Error writing export files", e)
            Toast.makeText(this, "Failed to write export files: $e", Toast.LENGTH_LONG).show()
        }
    }

    private fun shareResults() {
        val jsonFile = lastExportedJsonFile ?: return
        val echoFile = lastExportedEchoFile ?: return

        val uris = ArrayList<Uri>()
        uris.add(FileProvider.getUriForFile(this, "$packageName.fileprovider", jsonFile))
        uris.add(FileProvider.getUriForFile(this, "$packageName.fileprovider", echoFile))
        lastExportedSamplesFile?.let {
            uris.add(FileProvider.getUriForFile(this, "$packageName.fileprovider", it))
        }

        val shareIntent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "*/*"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(shareIntent, "Share Latency Probe Results"))
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRun(userCancelled = true)
        gattClient?.disconnect()
    }
}
