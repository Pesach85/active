package com.systemoptimizerhub.transparency.engine

import android.app.ActivityManager
import com.systemoptimizerhub.transparency.WasteFinding

class WasteResourceAnalyzer(
    private val trust: AppTrustClassifier,
    private val usage: UsageStatsCollector
) {

    fun analyze(
        storageApps: List<AppStorageRow>,
        runningCachedCount: Int,
        availRamMb: Long,
        storageFreePercent: Int
    ): List<WasteFinding> {
        val findings = mutableListOf<WasteFinding>()
        val cacheThreshold = trust.wasteThresholdCacheMb()
        val bgThreshold = trust.wasteBackgroundMinutes()

        storageApps.filter { it.cacheMb >= cacheThreshold && !it.trustLabel.startsWith("T1") }
            .take(5)
            .forEach { app ->
                findings.add(
                    WasteFinding(
                        category = "StorageWaste",
                        severity = if (app.cacheMb >= cacheThreshold * 2) "high" else "medium",
                        title = "Large app cache: ${app.label}",
                        detail = "${app.cacheMb} MB cache — clear via Settings → Apps → Storage",
                        packageName = app.packageName
                    )
                )
            }

        if (usage.hasUsageAccess()) {
            usage.topApps(15)
                .filter { it.backgroundMinutes >= bgThreshold && it.foregroundMinutes < 30 }
                .take(5)
                .forEach { row ->
                    findings.add(
                        WasteFinding(
                            category = "BackgroundComputeWaste",
                            severity = "medium",
                            title = "Heavy background: ${row.label}",
                            detail = "Background ~${row.backgroundMinutes} min vs foreground ${row.foregroundMinutes} min (24h window)",
                            packageName = row.packageName
                        )
                    )
                }
        } else {
            findings.add(
                WasteFinding(
                    category = "UsageAccess",
                    severity = "low",
                    title = "Usage access not granted",
                    detail = "Enable usage access for per-app background waste detection"
                )
            )
        }

        if (runningCachedCount >= 40) {
            findings.add(
                WasteFinding(
                    category = "MemoryWaste",
                    severity = "medium",
                    title = "Many cached processes ($runningCachedCount)",
                    detail = "Android keeps apps cached; system will trim under pressure — review background apps"
                )
            )
        }

        if (availRamMb < 1024) {
            findings.add(
                WasteFinding(
                    category = "MemoryPressure",
                    severity = "high",
                    title = "Low free RAM (${availRamMb} MB)",
                    detail = "Close unused apps or use memory trim action below"
                )
            )
        }

        if (storageFreePercent <= 10) {
            findings.add(
                WasteFinding(
                    category = "StoragePressure",
                    severity = "high",
                    title = "Storage critically low ($storageFreePercent% free)",
                    detail = "Remove large files and clear app caches"
                )
            )
        }

        return findings
    }
}
