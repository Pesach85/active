package com.systemoptimizerhub.transparency.engine

import android.app.usage.StorageStats
import android.app.usage.StorageStatsManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import com.systemoptimizerhub.transparency.StorageHotspot
import java.util.UUID

class StorageHotspotAnalyzer(
    private val context: Context,
    private val trust: AppTrustClassifier
) {
    private val mb = 1024L * 1024L

    fun analyze(priorityPackages: Collection<String> = emptyList()): List<StorageHotspot> {
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
        list.addAll(topAppStorageHotspots(priorityPackages))
        list.add(ownCacheHotspot())
        return list
    }

    fun topAppStorage(limit: Int = 12, priorityPackages: Collection<String> = emptyList()): List<AppStorageRow> {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return emptyList()
        val ssm = context.getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
        val pm = context.packageManager
        val uuid = StorageManager.UUID_DEFAULT
        val candidates = buildCandidatePackages(pm, priorityPackages)
        val rows = mutableListOf<AppStorageRow>()
        val seenUids = mutableSetOf<Int>()

        for (pkg in candidates) {
            try {
                val appInfo = pm.getApplicationInfo(pkg, 0)
                if (!seenUids.add(appInfo.uid)) continue
                val stats: StorageStats = ssm.queryStatsForUid(uuid, appInfo.uid)
                val cache = stats.cacheBytes / mb
                val data = stats.dataBytes / mb
                val total = (stats.appBytes + stats.dataBytes + stats.cacheBytes) / mb
                if (total < 5) continue
                val label = pm.getApplicationLabel(appInfo).toString()
                rows.add(
                    AppStorageRow(
                        packageName = appInfo.packageName,
                        label = label,
                        cacheMb = cache,
                        dataMb = data,
                        totalMb = total,
                        trustLabel = trust.classifyPackage(appInfo.packageName)
                    )
                )
            } catch (_: Exception) { }
        }
        return rows.sortedByDescending { it.totalMb }.take(limit)
    }

    private fun buildCandidatePackages(
        pm: PackageManager,
        priorityPackages: Collection<String>
    ): LinkedHashSet<String> {
        val candidates = LinkedHashSet<String>()
        priorityPackages.forEach { pkg ->
            if (pkg.isNotBlank()) candidates.add(pkg.substringBefore(':'))
        }
        candidates.add(context.packageName)

        val installed = try {
            pm.getInstalledApplications(PackageManager.MATCH_UNINSTALLED_PACKAGES)
        } catch (_: Exception) {
            pm.getInstalledApplications(0)
        }

        for (app in installed) {
            if (candidates.size >= MAX_STORAGE_CANDIDATES) break
            if ((app.flags and ApplicationInfo.FLAG_SYSTEM) == 0) {
                candidates.add(app.packageName)
            }
        }
        if (candidates.size < MAX_STORAGE_CANDIDATES) {
            for (app in installed) {
                if (candidates.size >= MAX_STORAGE_CANDIDATES) break
                candidates.add(app.packageName)
            }
        }
        return candidates
    }

    private fun topAppStorageHotspots(priorityPackages: Collection<String>): List<StorageHotspot> {
        return topAppStorage(5, priorityPackages).map { row ->
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
            context.cacheDir?.listFiles()?.sumOf { if (it.isFile) it.length() else 0L } ?: 0L
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

    companion object {
        private const val MAX_STORAGE_CANDIDATES = 48
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
