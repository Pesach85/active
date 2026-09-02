package com.systemoptimizerhub.transparency.engine

import android.app.usage.StorageStats
import android.app.usage.StorageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.os.Process
import com.systemoptimizerhub.transparency.StorageHotspot
import java.util.UUID

class StorageHotspotAnalyzer(
    private val context: Context,
    private val trust: AppTrustClassifier
) {
    private val mb = 1024L * 1024L

    fun analyze(): List<StorageHotspot> {
        val list = mutableListOf<StorageHotspot>()
        val dataDir = Environment.getDataDirectory()
        val stat = StatFs(dataDir.path)
        val totalMb = (stat.blockCountLong * stat.blockSizeLong) / mb
        val freeMb = (stat.availableBlocksLong * stat.blockSizeLong) / mb
        val freePercent = if (totalMb > 0) ((freeMb * 100) / totalMb).toInt() else 0
        list.add(
            StorageHotspot(
                label = "Internal data partition",
                detail = "$freeMb MB free of $totalMb MB ($freePercent%)",
                severity = severityForPercent(freePercent)
            )
        )
        list.addAll(topAppStorageHotspots())
        list.add(ownCacheHotspot())
        return list
    }

    fun topAppStorage(limit: Int = 12): List<AppStorageRow> {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return emptyList()
        val ssm = context.getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
        val pm = context.packageManager
        val uuid = StorageManager.UUID_DEFAULT
        val rows = mutableListOf<AppStorageRow>()
        for (app in pm.getInstalledApplications(PackageManager.GET_META_DATA)) {
            if (app.uid < Process.SYSTEM_UID) continue
            try {
                val stats: StorageStats = ssm.queryStatsForUid(uuid, app.uid)
                val cache = stats.cacheBytes / mb
                val data = stats.dataBytes / mb
                val total = (stats.appBytes + stats.dataBytes + stats.cacheBytes) / mb
                if (total < 5) continue
                val label = pm.getApplicationLabel(app).toString()
                rows.add(
                    AppStorageRow(
                        packageName = app.packageName,
                        label = label,
                        cacheMb = cache,
                        dataMb = data,
                        totalMb = total,
                        trustLabel = trust.classifyPackage(app.packageName)
                    )
                )
            } catch (_: Exception) { }
        }
        return rows.sortedByDescending { it.totalMb }.take(limit)
    }

    private fun topAppStorageHotspots(): List<StorageHotspot> {
        return topAppStorage(5).map { row ->
            StorageHotspot(
                label = row.label,
                detail = "cache ${row.cacheMb} MB · data ${row.dataMb} MB · total ${row.totalMb} MB",
                severity = when {
                    row.cacheMb >= trust.wasteThresholdCacheMb() * 2 -> "high"
                    row.cacheMb >= trust.wasteThresholdCacheMb() -> "medium"
                    else -> "low"
                },
                packageName = row.packageName
            )
        }
    }

    private fun ownCacheHotspot(): StorageHotspot {
        val cache = try {
            context.cacheDir?.walkTopDown()?.filter { it.isFile }?.sumOf { it.length() } ?: 0L
        } catch (_: Exception) { 0L }
        val cacheMb = cache / mb
        return StorageHotspot(
            label = "This app cache",
            detail = "$cacheMb MB in cache dir",
            severity = if (cacheMb > 64) "medium" else "low",
            packageName = context.packageName
        )
    }

    private fun severityForPercent(freePercent: Int) = when {
        freePercent <= 5 -> "critical"
        freePercent <= 10 -> "high"
        freePercent <= 20 -> "medium"
        else -> "low"
    }
}

data class AppStorageRow(
    val packageName: String,
    val label: String,
    val cacheMb: Long,
    val dataMb: Long,
    val totalMb: Long,
    val trustLabel: String
)
