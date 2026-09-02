package com.systemoptimizerhub.transparency.engine

import android.app.ActivityManager
import android.content.Context
import com.systemoptimizerhub.transparency.ProcessEntry

class ProcessPressureEngine(
    private val context: Context,
    private val trust: AppTrustClassifier
) {
    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager

    fun topProcesses(limit: Int = 12): List<ProcessEntry> {
        val running = activityManager.runningAppProcesses.orEmpty()
        return running
            .map { p -> scoreProcess(p) }
            .sortedByDescending { it.score }
            .take(limit)
    }

    fun cachedProcessCount(): Int {
        return activityManager.runningAppProcesses.orEmpty()
            .count { it.importance >= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED }
    }

    private fun scoreProcess(p: ActivityManager.RunningAppProcessInfo): ProcessEntry {
        val trustLabel = trust.classifyProcess(p.processName)
        var score = 0
        val dominant = when {
            p.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> {
                score += 5
                "Foreground"
            }
            p.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> {
                score += 15
                "Visible"
            }
            p.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> {
                score += 25
                "Service"
            }
            p.importance >= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> {
                score += 35
                "Cached"
            }
            else -> {
                score += 20
                "Background"
            }
        }
        if (trustLabel.startsWith("T3")) score += 10
        if (trustLabel.startsWith("T2")) score += 5
        return ProcessEntry(
            processName = p.processName,
            pid = p.pid,
            importance = p.importance,
            importanceLabel = importanceLabel(p.importance),
            isForeground = p.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
            trustLabel = trustLabel,
            dominantPressure = dominant,
            score = score.coerceIn(0, 100),
            advisory = advisoryFor(trustLabel, p.importance)
        )
    }

    private fun importanceLabel(importance: Int): String = when (importance) {
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "Foreground"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "Visible"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "Service"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "Cached"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "Gone"
        else -> "Other ($importance)"
    }

    private fun advisoryFor(trustLabel: String, importance: Int): String {
        if (importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) {
            return "Foreground — do not stop while in use"
        }
        if (trustLabel.startsWith("T1")) return "System process — keep"
        if (importance >= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED) {
            return "Cached — safe to trim via system memory manager"
        }
        return "Review in app settings before force-stop"
    }
}
