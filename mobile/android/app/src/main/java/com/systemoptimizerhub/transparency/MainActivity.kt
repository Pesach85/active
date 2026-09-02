package com.systemoptimizerhub.transparency

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
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
    private lateinit var summaryText: TextView
    private lateinit var hostText: TextView
    private lateinit var updatedText: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var processList: RecyclerView
    private lateinit var actionList: RecyclerView
    private lateinit var storageList: RecyclerView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        engine = DeviceMaintenanceEngine(applicationContext)
        tierText = findViewById(R.id.tierText)
        scoreText = findViewById(R.id.scoreText)
        summaryText = findViewById(R.id.summaryText)
        hostText = findViewById(R.id.hostText)
        updatedText = findViewById(R.id.updatedText)
        progressBar = findViewById(R.id.progressBar)
        processList = findViewById(R.id.processList)
        actionList = findViewById(R.id.actionList)
        storageList = findViewById(R.id.storageList)

        processList.layoutManager = LinearLayoutManager(this)
        actionList.layoutManager = LinearLayoutManager(this)
        storageList.layoutManager = LinearLayoutManager(this)

        findViewById<Button>(R.id.refreshBtn).setOnClickListener { refresh() }
        refresh()
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        progressBar.visibility = View.VISIBLE
        findViewById<View>(R.id.contentScroll).post {
            val snap = engine.analyze()
            render(snap)
            progressBar.visibility = View.GONE
        }
    }

    private fun render(snap: DeviceSnapshot) {
        tierText.text = getString(R.string.pressure_tier, snap.pressureTier.name)
        scoreText.text = getString(R.string.pressure_score, snap.pressureScore)
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
        summaryText.text = snap.summaryBullets.joinToString("\n") { "• $it" }
        updatedText.text = getString(
            R.string.updated_at,
            SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(snap.generatedAtEpochMs))
        )

        processList.adapter = ProcessAdapter(snap.topProcesses)
        storageList.adapter = StorageAdapter(snap.storageHotspots)
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
            MaintenanceActionKind.AdvisoryOnly -> { /* display only */ }
        }
    }
}
