package com.systemoptimizerhub.transparency.engine

import android.app.AppOpsManager
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.util.concurrent.TimeUnit

class UsageStatsCollector(private val context: Context) {

    fun hasUsageAccess(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun topApps(limit: Int = 10): List<UsageAppRow> {
        if (!hasUsageAccess()) return emptyList()
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val end = System.currentTimeMillis()
        val start = end - TimeUnit.HOURS.toMillis(24)
        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, start, end) ?: return emptyList()
        val pm = context.packageManager
        return stats
            .filter { it.totalTimeInForeground > 0 || it.totalTimeVisible > 0 }
            .sortedByDescending { it.totalTimeInForeground + it.totalTimeVisible }
            .take(limit)
            .mapNotNull { s ->
                val pkg = s.packageName ?: return@mapNotNull null
                val label = try {
                    pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                } catch (_: PackageManager.NameNotFoundException) {
                    pkg
                }
                UsageAppRow(
                    packageName = pkg,
                    label = label,
                    foregroundMinutes = (s.totalTimeInForeground / 60000),
                    backgroundMinutes = estimateBackgroundMinutes(s)
                )
            }
    }

    private fun estimateBackgroundMinutes(stats: UsageStats): Long {
        val last = stats.lastTimeUsed
        val fg = stats.totalTimeInForeground
        if (last <= 0) return 0
        val window = System.currentTimeMillis() - last
        return if (window > fg) (window - fg) / 60000 else 0
    }
}

data class UsageAppRow(
    val packageName: String,
    val label: String,
    val foregroundMinutes: Long,
    val backgroundMinutes: Long
)
