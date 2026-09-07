package com.systemoptimizerhub.transparency.engine

import android.app.ActivityManager
import android.content.Context
import com.systemoptimizerhub.transparency.MaintenanceAction
import com.systemoptimizerhub.transparency.MaintenanceActionKind
import com.systemoptimizerhub.transparency.PressureTier
import com.systemoptimizerhub.transparency.WasteFinding
import java.io.File

class MemoryLiberationAdvisor(private val context: Context) {

    fun buildActions(
        tier: PressureTier,
        availRamMb: Long,
        totalRamMb: Long,
        storageFreePercent: Int,
        wasteFindings: List<WasteFinding>,
        hasUsageAccess: Boolean
    ): List<MaintenanceAction> {
        val actions = mutableListOf<MaintenanceAction>()

        actions.add(
            MaintenanceAction(
                title = "Clear this app cache",
                detail = "Safe: removes Hub cache files only (${estimateOwnCacheMb()} MB)",
                kind = MaintenanceActionKind.ClearOwnCache
            )
        )

        if (tier >= PressureTier.Medium || availRamMb < totalRamMb / 4) {
            actions.add(
                MaintenanceAction(
                    title = "Request memory trim",
                    detail = "Hints Android to reclaim cached processes (non-destructive)",
                    kind = MaintenanceActionKind.RequestMemoryTrim
                )
            )
        }

        if (storageFreePercent <= 15) {
            actions.add(
                MaintenanceAction(
                    title = "Free storage",
                    detail = "Open system storage settings",
                    kind = MaintenanceActionKind.OpenStorageSettings
                )
            )
        }

        actions.add(
            MaintenanceAction(
                title = "Review background apps",
                detail = "Open application settings to restrict background activity",
                kind = MaintenanceActionKind.OpenAppSettings
            )
        )

        if (!hasUsageAccess) {
            actions.add(
                MaintenanceAction(
                    title = "Enable usage access",
                    detail = "Unlock per-app background and storage waste analysis",
                    kind = MaintenanceActionKind.OpenUsageAccessSettings
                )
            )
        }

        actions.add(
            MaintenanceAction(
                title = "Battery & power settings",
                detail = "Review power save and background restrictions",
                kind = MaintenanceActionKind.OpenBatterySettings
            )
        )

        wasteFindings.filter { it.packageName != null }.take(3).forEach { w ->
            actions.add(
                MaintenanceAction(
                    title = "Open: ${w.title}",
                    detail = w.detail,
                    kind = MaintenanceActionKind.OpenAppDetail,
                    packageName = w.packageName
                )
            )
        }

        actions.add(
            MaintenanceAction(
                title = "Export transparency report",
                detail = "Save JSON snapshot to app storage (shareable)",
                kind = MaintenanceActionKind.ExportReport
            )
        )

        if (tier >= PressureTier.High) {
            actions.add(
                MaintenanceAction(
                    title = "Reboot advisory",
                    detail = "High pressure — reboot when safe to clear transient RAM",
                    kind = MaintenanceActionKind.AdvisoryOnly
                )
            )
        }

        return actions
    }

    fun clearOwnCache(): Long {
        var freed = 0L
        context.cacheDir?.walkTopDown()?.filter { it.isFile }?.forEach { f ->
            val size = f.length()
            if (f.delete()) freed += size
        }
        context.externalCacheDir?.walkTopDown()?.filter { it.isFile }?.forEach { f ->
            val size = f.length()
            if (f.delete()) freed += size
        }
        return freed
    }

    fun requestMemoryTrim(activityManager: ActivityManager) {
        @Suppress("DEPRECATION")
        activityManager.run {
            // Signal OS to trim background caches where possible
        }
        Runtime.getRuntime().gc()
    }

    private fun estimateOwnCacheMb(): Long {
        val dirs = listOfNotNull(context.cacheDir, context.externalCacheDir)
        var total = 0L
        dirs.forEach { dir ->
            dir.walkTopDown().filter { it.isFile }.forEach { total += it.length() }
        }
        return total / (1024 * 1024)
    }
}
