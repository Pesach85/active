package com.systemoptimizerhub.transparency.ui

import android.content.Context
import com.systemoptimizerhub.transparency.DeviceSnapshot
import com.systemoptimizerhub.transparency.MaintenanceAction
import com.systemoptimizerhub.transparency.MaintenanceActionKind
import com.systemoptimizerhub.transparency.PressureTier
import com.systemoptimizerhub.transparency.R
import com.systemoptimizerhub.transparency.WasteFinding
import java.util.Locale
import kotlin.math.roundToInt

object UiPresenter {

    data class StatusCopy(val title: String, val subtitle: String, val cardBgRes: Int, val accentColorRes: Int)

    fun status(context: Context, tier: PressureTier): StatusCopy = when (tier) {
        PressureTier.Low -> StatusCopy(
            context.getString(R.string.status_ok_title),
            context.getString(R.string.status_ok_sub),
            R.color.status_ok_bg,
            R.color.tier_low
        )
        PressureTier.Medium -> StatusCopy(
            context.getString(R.string.status_attention_title),
            context.getString(R.string.status_attention_sub),
            R.color.status_warn_bg,
            R.color.tier_medium
        )
        PressureTier.High -> StatusCopy(
            context.getString(R.string.status_urgent_title),
            context.getString(R.string.status_urgent_sub),
            R.color.status_warn_bg,
            R.color.tier_high
        )
        PressureTier.Critical -> StatusCopy(
            context.getString(R.string.status_critical_title),
            context.getString(R.string.status_critical_sub),
            R.color.status_bad_bg,
            R.color.tier_critical
        )
    }

    fun formatSize(context: Context, mb: Long): String {
        return if (mb >= 1024) {
            val gb = mb / 1024.0
            String.format(Locale.getDefault(), "%.1f GB", gb)
        } else {
            "$mb MB"
        }
    }

    fun memoryPercentFree(snap: DeviceSnapshot): Int {
        if (snap.totalRamMb <= 0) return 0
        return ((snap.availRamMb * 100.0) / snap.totalRamMb).roundToInt().coerceIn(0, 100)
    }

    fun storagePercentFree(snap: DeviceSnapshot): Int =
        snap.storageFreePercent.coerceIn(0, 100)

    fun barColorForPercent(freePercent: Int): Int = when {
        freePercent <= 10 -> R.color.tier_critical
        freePercent <= 25 -> R.color.tier_high
        freePercent <= 40 -> R.color.tier_medium
        else -> R.color.tier_low
    }

    fun friendlyAction(context: Context, action: MaintenanceAction): Pair<String, String> = when (action.kind) {
        MaintenanceActionKind.ClearOwnCache ->
            context.getString(R.string.action_clear_cache) to context.getString(R.string.action_clear_cache_sub)
        MaintenanceActionKind.RequestMemoryTrim ->
            context.getString(R.string.action_memory_trim) to context.getString(R.string.action_memory_trim_sub)
        MaintenanceActionKind.OpenStorageSettings ->
            context.getString(R.string.action_storage) to context.getString(R.string.action_storage_sub)
        MaintenanceActionKind.OpenAppSettings ->
            context.getString(R.string.action_apps) to context.getString(R.string.action_apps_sub)
        MaintenanceActionKind.OpenUsageAccessSettings ->
            context.getString(R.string.action_usage) to context.getString(R.string.action_usage_sub)
        MaintenanceActionKind.OpenBatterySettings ->
            context.getString(R.string.action_battery) to context.getString(R.string.action_battery_sub)
        MaintenanceActionKind.ExportReport ->
            context.getString(R.string.action_export) to context.getString(R.string.action_export_sub)
        MaintenanceActionKind.AdvisoryOnly ->
            context.getString(R.string.action_reboot) to context.getString(R.string.action_reboot_sub)
        MaintenanceActionKind.OpenAppDetail ->
            (action.title.ifBlank { context.getString(R.string.action_app_detail) }) to action.detail
    }

    fun primaryActions(actions: List<MaintenanceAction>, max: Int = 3): List<MaintenanceAction> {
        val priority = listOf(
            MaintenanceActionKind.OpenStorageSettings,
            MaintenanceActionKind.RequestMemoryTrim,
            MaintenanceActionKind.ClearOwnCache,
            MaintenanceActionKind.OpenUsageAccessSettings,
            MaintenanceActionKind.OpenAppSettings,
            MaintenanceActionKind.OpenBatterySettings,
            MaintenanceActionKind.OpenAppDetail,
            MaintenanceActionKind.ExportReport,
            MaintenanceActionKind.AdvisoryOnly
        )
        val sorted = actions.sortedBy { priority.indexOf(it.kind).let { i -> if (i < 0) 99 else i } }
        return sorted.filter { it.kind != MaintenanceActionKind.AdvisoryOnly }.take(max)
    }

    fun secondaryActions(actions: List<MaintenanceAction>, primary: List<MaintenanceAction>): List<MaintenanceAction> {
        val primarySet = primary.toSet()
        return actions.filter { it !in primarySet }
    }

    fun findingsText(context: Context, findings: List<WasteFinding>): String {
        if (findings.isEmpty()) return context.getString(R.string.no_findings)
        return findings.take(6).joinToString("\n\n") { f ->
            val icon = when (f.severity) {
                "high", "critical" -> "⚠"
                "medium" -> "•"
                else -> "·"
            }
            "$icon ${f.title}\n${f.detail}"
        }
    }

    fun heavyAppsText(context: Context, snap: DeviceSnapshot): String {
        if (snap.topApps.isEmpty()) return context.getString(R.string.no_heavy_apps)
        return snap.topApps.take(5).joinToString("\n\n") { app ->
            "${app.label}\n${formatSize(context, app.totalMb)} totali · cache ${app.cacheMb} MB"
        }
    }
}
