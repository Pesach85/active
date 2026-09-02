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
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

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
    private lateinit var refreshBtn: Button
    private lateinit var wasteList: RecyclerView
    private lateinit var processList: RecyclerView
    private lateinit var actionList: RecyclerView
    private lateinit var storageList: RecyclerView
    private lateinit var appList: RecyclerView
    private lateinit var bootList: RecyclerView

    private val analyzeExecutor = Executors.newSingleThreadExecutor()
    private val analyzeGeneration = AtomicInteger(0)

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
        refreshBtn = findViewById(R.id.refreshBtn)
        wasteList = findViewById(R.id.wasteList)
        processList = findViewById(R.id.processList)
        actionList = findViewById(R.id.actionList)
        storageList = findViewById(R.id.storageList)
        appList = findViewById(R.id.appList)
        bootList = findViewById(R.id.bootList)

        listOf(wasteList, processList, actionList, storageList, appList, bootList).forEach {
            it.layoutManager = LinearLayoutManager(this)
            it.isNestedScrollingEnabled = false
        }

        refreshBtn.setOnClickListener { refresh() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        analyzeExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun refresh() {
        val gen = analyzeGeneration.incrementAndGet()
        progressBar.visibility = View.VISIBLE
        refreshBtn.isEnabled = false
        tierText.text = getString(R.string.analyzing)
        scoreText.text = ""
        summaryText.text = getString(R.string.analyzing_detail)

        analyzeExecutor.execute {
            val snap = try {
                val t0 = System.currentTimeMillis()
                val result = engine.analyze()
                android.util.Log.i("HubAndroid", "analyze ok in ${System.currentTimeMillis() - t0}ms tier=${result.pressureTier}")
                result
            } catch (ex: Exception) {
                android.util.Log.e("HubAndroid", "analyze failed", ex)
                null
            }
            runOnUiThread {
                if (gen != analyzeGeneration.get()) return@runOnUiThread
                progressBar.visibility = View.GONE
                refreshBtn.isEnabled = true
                if (snap != null) {
                    render(snap)
                } else {
                    tierText.text = getString(R.string.analyze_failed)
                    Toast.makeText(this, R.string.analyze_failed, Toast.LENGTH_LONG).show()
                }
            }
        }
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

        bindList(
            wasteList,
            WasteAdapter(
                snap.wasteFindings.ifEmpty {
                    listOf(WasteFinding("Info", "low", getString(R.string.empty_section), ""))
                }
            )
        )
        bindList(
            processList,
            ProcessAdapter(
                snap.topProcesses.ifEmpty {
                    listOf(
                        ProcessEntry(
                            processName = getString(R.string.empty_section),
                            pid = 0,
                            importanceLabel = "-",
                            importance = 0,
                            isForeground = false,
                            trustLabel = "-",
                            dominantPressure = "-",
                            score = 0,
                            advisory = "-"
                        )
                    )
                }
            )
        )
        bindList(
            storageList,
            StorageAdapter(
                snap.storageHotspots.ifEmpty {
                    listOf(StorageHotspot(getString(R.string.empty_section), "", "low"))
                }
            )
        )
        bindList(
            appList,
            AppAdapter(
                snap.topApps.ifEmpty {
                    listOf(
                        AppPressureEntry(
                            packageName = "",
                            label = getString(R.string.empty_section),
                            cacheMb = 0,
                            dataMb = 0,
                            totalMb = 0,
                            foregroundMinutes = 0,
                            backgroundMinutes = 0,
                            trustLabel = "-",
                            wasteScore = 0,
                            advisory = "-"
                        )
                    )
                }
            )
        )
        bindList(
            bootList,
            BootAdapter(
                snap.bootApps.ifEmpty {
                    listOf(BootAppEntry("", getString(R.string.empty_section), true))
                }
            )
        )
        bindList(actionList, ActionAdapter(snap.recommendedActions) { action -> onAction(action) })
    }

    private fun bindList(recyclerView: RecyclerView, adapter: RecyclerView.Adapter<*>) {
        recyclerView.adapter = adapter
        recyclerView.post { expandRecyclerView(recyclerView) }
    }

    private fun expandRecyclerView(recyclerView: RecyclerView) {
        val adapter = recyclerView.adapter ?: return
        if (adapter.itemCount == 0) {
            recyclerView.layoutParams.height = 0
            recyclerView.requestLayout()
            return
        }
        var totalHeight = 0
        val widthSpec = View.MeasureSpec.makeMeasureSpec(recyclerView.width, View.MeasureSpec.EXACTLY)
        val heightSpec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        for (i in 0 until adapter.itemCount) {
            val holder = adapter.createViewHolder(recyclerView, adapter.getItemViewType(i))
            adapter.onBindViewHolder(holder, i)
            holder.itemView.measure(widthSpec, heightSpec)
            totalHeight += holder.itemView.measuredHeight
        }
        recyclerView.layoutParams.height = totalHeight
        recyclerView.requestLayout()
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
