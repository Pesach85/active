package com.systemoptimizerhub.transparency

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : AppCompatActivity() {

    private lateinit var engine: DeviceMaintenanceEngine
    private lateinit var tierText: TextView
    private lateinit var scoreText: TextView
    private lateinit var postureText: TextView
    private lateinit var summaryText: TextView
    private lateinit var hostText: TextView
    private lateinit var batteryNetworkText: TextView
    private lateinit var updatedText: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var wasteList: RecyclerView
    private lateinit var processList: RecyclerView
    private lateinit var actionList: RecyclerView
    private lateinit var storageList: RecyclerView
    private lateinit var appList: RecyclerView
    private lateinit var bootList: RecyclerView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        engine = DeviceMaintenanceEngine(applicationContext)
        tierText = findViewById(R.id.tierText)
        scoreText = findViewById(R.id.scoreText)
        postureText = findViewById(R.id.postureText)
        summaryText = findViewById(R.id.summaryText)
        hostText = findViewById(R.id.hostText)
        batteryNetworkText = findViewById(R.id.batteryNetworkText)
        updatedText = findViewById(R.id.updatedText)
        progressBar = findViewById(R.id.progressBar)
        wasteList = findViewById(R.id.wasteList)
        processList = findViewById(R.id.processList)
        actionList = findViewById(R.id.actionList)
        storageList = findViewById(R.id.storageList)
        appList = findViewById(R.id.appList)
        bootList = findViewById(R.id.bootList)

        listOf(wasteList, processList, actionList, storageList, appList, bootList).forEach {
            it.layoutManager = LinearLayoutManager(this)
        }

        findViewById<Button>(R.id.refreshBtn).setOnClickListener { refresh() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        progressBar.visibility = View.VISIBLE
        Thread {
            val snap = try {
                engine.analyze()
            } catch (ex: Exception) {
                android.util.Log.e("HubAndroid", "analyze failed", ex)
                null
            }
            runOnUiThread {
                if (snap != null) render(snap)
                progressBar.visibility = View.GONE
            }
        }.start()
    }

    private fun render(snap: DeviceSnapshot) {
        tierText.text = getString(R.string.pressure_tier, snap.pressureTier.name)
        scoreText.text = getString(R.string.pressure_score, snap.pressureScore)
        postureText.text = getString(R.string.posture_score, snap.transparencyPostureScore)
        val tierColor = when (snap.pressureTier) {
            PressureTier.Low -> R.color.tier_low
            PressureTier.Medium -> R.color.tier_medium
            PressureTier.High -> R.color.tier_high
            PressureTier.Critical -> R.color.tier_critical
        }
        tierText.setTextColor(ContextCompat.getColor(this, tierColor))

        hostText.text = getString(
            R.string.host_summary,
            snap.availRamMb,
            snap.totalRamMb,
            snap.freeStorageMb,
            snap.totalStorageMb,
            snap.installedAppsCount,
            snap.runningProcessCount
        )

        val charging = if (snap.battery.isCharging) getString(R.string.charging) else getString(R.string.not_charging)
        val metered = if (snap.network.isMetered) getString(R.string.metered) else ""
        batteryNetworkText.text = getString(
            R.string.battery_network,
            snap.battery.levelPercent,
            charging,
            snap.battery.healthHint,
            snap.network.activeType,
            metered
        )

        summaryText.text = snap.summaryBullets.joinToString("\n") { "• $it" }
        updatedText.text = getString(
            R.string.updated_at,
            SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(snap.generatedAtEpochMs))
        )

        wasteList.adapter = WasteAdapter(snap.wasteFindings)
        processList.adapter = ProcessAdapter(snap.topProcesses)
        storageList.adapter = StorageAdapter(snap.storageHotspots)
        appList.adapter = AppAdapter(snap.topApps)
        bootList.adapter = BootAdapter(snap.bootApps)
        actionList.adapter = ActionAdapter(snap.recommendedActions) { action -> onAction(action) }
    }

    private fun onAction(action: MaintenanceAction) {
        when (action.kind) {
            MaintenanceActionKind.OpenStorageSettings -> {
                startActivity(Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS))
            }
            MaintenanceActionKind.OpenAppSettings -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_SETTINGS))
            }
            MaintenanceActionKind.OpenUsageAccessSettings -> {
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            }
            MaintenanceActionKind.OpenBatterySettings -> {
                startActivity(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
            }
            MaintenanceActionKind.OpenAppDetail -> {
                val pkg = action.packageName ?: return
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$pkg")
                })
            }
            MaintenanceActionKind.ClearOwnCache -> {
                val freed = engine.clearOwnCache()
                Toast.makeText(this, getString(R.string.cache_cleared, freed / (1024 * 1024)), Toast.LENGTH_SHORT).show()
                refresh()
            }
            MaintenanceActionKind.RequestMemoryTrim -> {
                engine.requestMemoryTrim()
                Toast.makeText(this, R.string.memory_trim_requested, Toast.LENGTH_SHORT).show()
                refresh()
            }
            MaintenanceActionKind.ExportReport -> {
                val path = engine.exportReport()
                Toast.makeText(this, getString(R.string.report_exported, path), Toast.LENGTH_LONG).show()
            }
            MaintenanceActionKind.AdvisoryOnly -> { /* display only */ }
        }
    }
}
