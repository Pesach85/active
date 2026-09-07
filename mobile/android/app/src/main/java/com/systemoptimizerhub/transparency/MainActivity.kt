package com.systemoptimizerhub.transparency

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.systemoptimizerhub.transparency.ui.UiPresenter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : AppCompatActivity() {

    private lateinit var engine: DeviceMaintenanceEngine
    private lateinit var statusCard: MaterialCardView
    private lateinit var statusHeadline: TextView
    private lateinit var statusSubtitle: TextView
    private lateinit var updatedText: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var refreshBtn: MaterialButton
    private lateinit var toggleDetailsBtn: MaterialButton
    private lateinit var detailsPanel: LinearLayout
    private lateinit var findingsText: TextView
    private lateinit var appsText: TextView
    private lateinit var noActionsHint: TextView
    private lateinit var primaryActionsContainer: LinearLayout
    private lateinit var secondaryActionsContainer: LinearLayout

    private lateinit var metricMemory: MetricViews
    private lateinit var metricStorage: MetricViews
    private lateinit var metricBattery: MetricViews

    private val analyzeExecutor = Executors.newSingleThreadExecutor()
    private val analyzeGeneration = AtomicInteger(0)
    private var detailsVisible = false
    private var lastSnapshot: DeviceSnapshot? = null

    private data class MetricViews(
        val label: TextView,
        val value: TextView,
        val bar: LinearProgressIndicator
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        engine = DeviceMaintenanceEngine(applicationContext)
        statusCard = findViewById(R.id.statusCard)
        statusHeadline = findViewById(R.id.statusHeadline)
        statusSubtitle = findViewById(R.id.statusSubtitle)
        updatedText = findViewById(R.id.updatedText)
        progressBar = findViewById(R.id.progressBar)
        refreshBtn = findViewById(R.id.refreshBtn)
        toggleDetailsBtn = findViewById(R.id.toggleDetailsBtn)
        detailsPanel = findViewById(R.id.detailsPanel)
        findingsText = findViewById(R.id.findingsText)
        appsText = findViewById(R.id.appsText)
        noActionsHint = findViewById(R.id.noActionsHint)
        primaryActionsContainer = findViewById(R.id.primaryActionsContainer)
        secondaryActionsContainer = findViewById(R.id.secondaryActionsContainer)

        metricMemory = bindMetric(R.id.metricMemory)
        metricStorage = bindMetric(R.id.metricStorage)
        metricBattery = bindMetric(R.id.metricBattery)

        metricMemory.label.text = getString(R.string.metric_memory)
        metricStorage.label.text = getString(R.string.metric_storage)
        metricBattery.label.text = getString(R.string.metric_battery)

        refreshBtn.setOnClickListener { refresh() }
        toggleDetailsBtn.setOnClickListener { toggleDetails() }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    override fun onDestroy() {
        analyzeExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun bindMetric(rootId: Int): MetricViews {
        val root = findViewById<View>(rootId)
        return MetricViews(
            label = root.findViewById(R.id.metricLabel),
            value = root.findViewById(R.id.metricValue),
            bar = root.findViewById(R.id.metricBar)
        )
    }

    private fun refresh() {
        val gen = analyzeGeneration.incrementAndGet()
        progressBar.visibility = View.VISIBLE
        refreshBtn.isEnabled = false
        statusHeadline.text = getString(R.string.analyzing)
        statusSubtitle.text = getString(R.string.analyzing_detail)

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
                    lastSnapshot = snap
                    render(snap)
                } else {
                    statusHeadline.text = getString(R.string.analyze_failed)
                    statusSubtitle.text = getString(R.string.analyzing_detail)
                    Toast.makeText(this, R.string.analyze_failed, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun render(snap: DeviceSnapshot) {
        val status = UiPresenter.status(this, snap.pressureTier)
        statusCard.setCardBackgroundColor(ContextCompat.getColor(this, status.cardBgRes))
        statusHeadline.text = status.title
        statusSubtitle.text = status.subtitle

        updatedText.text = getString(
            R.string.updated_at,
            SimpleDateFormat("dd/MM/yyyy HH:mm", Locale.getDefault()).format(Date(snap.generatedAtEpochMs))
        )

        renderMetric(
            metricMemory,
            getString(
                R.string.metric_memory_value,
                UiPresenter.formatSize(this, snap.availRamMb),
                UiPresenter.formatSize(this, snap.totalRamMb)
            ),
            UiPresenter.memoryPercentFree(snap),
            UiPresenter.barColorForPercent(UiPresenter.memoryPercentFree(snap))
        )

        renderMetric(
            metricStorage,
            getString(
                R.string.metric_storage_value,
                UiPresenter.formatSize(this, snap.freeStorageMb),
                UiPresenter.formatSize(this, snap.totalStorageMb)
            ),
            UiPresenter.storagePercentFree(snap),
            UiPresenter.barColorForPercent(UiPresenter.storagePercentFree(snap))
        )

        val batteryState = when {
            snap.battery.powerSaveMode -> getString(R.string.battery_saving)
            snap.battery.isCharging -> getString(R.string.battery_charging)
            else -> getString(R.string.battery_on_battery)
        }
        renderMetric(
            metricBattery,
            getString(R.string.metric_battery_value, snap.battery.levelPercent, batteryState),
            snap.battery.levelPercent,
            UiPresenter.barColorForPercent(snap.battery.levelPercent)
        )

        val primary = if (snap.pressureTier == PressureTier.Low &&
            snap.wasteFindings.none { it.severity == "high" || it.severity == "critical" }
        ) {
            emptyList()
        } else {
            UiPresenter.primaryActions(snap.recommendedActions)
        }
        val secondary = UiPresenter.secondaryActions(snap.recommendedActions, primary)

        primaryActionsContainer.removeAllViews()
        if (primary.isEmpty()) {
            noActionsHint.visibility = View.VISIBLE
        } else {
            noActionsHint.visibility = View.GONE
            primary.forEach { addActionCard(primaryActionsContainer, it, status.accentColorRes) }
        }

        findingsText.text = UiPresenter.findingsText(this, snap.wasteFindings)
        appsText.text = UiPresenter.heavyAppsText(this, snap)

        secondaryActionsContainer.removeAllViews()
        secondary.forEach { addActionCard(secondaryActionsContainer, it, R.color.text_secondary) }

        toggleDetailsBtn.visibility = View.VISIBLE
        if (!detailsVisible) {
            detailsPanel.visibility = View.GONE
            toggleDetailsBtn.text = getString(R.string.show_details)
        }
    }

    private fun renderMetric(views: MetricViews, valueText: String, freePercent: Int, colorRes: Int) {
        views.value.text = valueText
        views.bar.max = 100
        views.bar.progress = freePercent
        views.bar.setIndicatorColor(ContextCompat.getColor(this, colorRes))
    }

    private fun addActionCard(container: LinearLayout, action: MaintenanceAction, strokeColorRes: Int) {
        val card = LayoutInflater.from(this).inflate(R.layout.item_primary_action, container, false) as MaterialCardView
        val (title, detail) = UiPresenter.friendlyAction(this, action)
        card.findViewById<TextView>(R.id.actionTitle).text = title
        card.findViewById<TextView>(R.id.actionDetail).text = detail
        card.strokeColor = ContextCompat.getColor(this, strokeColorRes)
        if (action.kind == MaintenanceActionKind.AdvisoryOnly) {
            card.setOnClickListener(null)
            card.isClickable = false
        } else {
            card.setOnClickListener { onAction(action) }
        }
        container.addView(card)
    }

    private fun toggleDetails() {
        detailsVisible = !detailsVisible
        detailsPanel.visibility = if (detailsVisible) View.VISIBLE else View.GONE
        toggleDetailsBtn.text = getString(if (detailsVisible) R.string.hide_details else R.string.show_details)
    }

    private fun onAction(action: MaintenanceAction) {
        when (action.kind) {
            MaintenanceActionKind.OpenStorageSettings ->
                startActivity(Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS))
            MaintenanceActionKind.OpenAppSettings ->
                startActivity(Intent(Settings.ACTION_APPLICATION_SETTINGS))
            MaintenanceActionKind.OpenUsageAccessSettings ->
                startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            MaintenanceActionKind.OpenBatterySettings ->
                startActivity(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
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
            MaintenanceActionKind.AdvisoryOnly -> { }
        }
    }
}
