package com.systemoptimizerhub.transparency

import android.app.ActivityManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * On-device maintenance engine: RAM, storage, running processes/apps on THIS Android device.
 * Parity intent with Windows/Linux PPI — no remote PC monitoring.
 */
class DeviceMaintenanceEngine(private val context: Context) {

    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val packageManager = context.packageManager

    fun analyze(topProcessLimit: Int = 12): DeviceSnapshot {
        val mem = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(mem)

        val totalRamMb = mem.totalMem / MB
        val availRamMb = mem.availMem / MB
        val ramUsedPercent = if (totalRamMb > 0) {
            (((totalRamMb - availRamMb).toDouble() / totalRamMb) * 100).roundToInt()
        } else 0

        val dataDir = Environment.getDataDirectory()
        val stat = StatFs(dataDir.path)
        val blockSize = stat.blockSizeLong
        val totalStorageMb = (stat.blockCountLong * blockSize) / MB
        val freeStorageMb = (stat.availableBlocksLong * blockSize) / MB
        val storageFreePercent = if (totalStorageMb > 0) {
            ((freeStorageMb.toDouble() / totalStorageMb) * 100).roundToInt()
        } else 0

        val installedApps = try {
            packageManager.getInstalledApplications(PackageManager.GET_META_DATA).size
        } catch (_: Exception) { 0 }

        val running = activityManager.runningAppProcesses.orEmpty()
        val topProcesses = running
            .sortedWith(
                compareByDescending<ActivityManager.RunningAppProcessInfo> { it.importance }
                    .thenBy { it.processName }
            )
            .take(topProcessLimit)
            .map { p ->
                ProcessEntry(
                    processName = p.processName,
                    pid = p.pid,
                    importance = p.importance,
                    importanceLabel = importanceLabel(p.importance),
                    isForeground = p.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
                    trustLabel = classifyTrust(p.processName),
                    advisory = advisoryFor(p.processName, p.importance)
                )
            }

        val storageHotspots = buildStorageHotspots(freeStorageMb, totalStorageMb, storageFreePercent)
        val (tier, score, bullets) = computePressure(
            availRamMb, totalRamMb, ramUsedPercent,
            freeStorageMb, totalStorageMb, storageFreePercent,
            mem.lowMemory, running.size
        )
        val actions = buildActions(tier, storageFreePercent, availRamMb, totalRamMb)

        return DeviceSnapshot(
            generatedAtEpochMs = System.currentTimeMillis(),
            totalRamMb = totalRamMb,
            availRamMb = availRamMb,
            ramUsedPercent = ramUsedPercent,
            totalStorageMb = totalStorageMb,
            freeStorageMb = freeStorageMb,
            storageFreePercent = storageFreePercent,
            installedAppsCount = installedApps,
            runningProcessCount = running.size,
            pressureTier = tier,
            pressureScore = score,
            summaryBullets = bullets,
            topProcesses = topProcesses,
            storageHotspots = storageHotspots,
            recommendedActions = actions
        )
    }

    private fun computePressure(
        availRamMb: Long,
        totalRamMb: Long,
        ramUsedPercent: Int,
        freeStorageMb: Long,
        totalStorageMb: Long,
        storageFreePercent: Int,
        lowMemory: Boolean,
        runningCount: Int
    ): Triple<PressureTier, Int, List<String>> {
        var score = 0
        val bullets = mutableListOf<String>()

        if (lowMemory) {
            score += 35
            bullets.add("System lowMemory flag active")
        }
        if (availRamMb < 1024) {
            score += 25
            bullets.add("Available RAM below 1 GB (${availRamMb} MB free)")
        } else if (availRamMb < 2048) {
            score += 12
            bullets.add("Available RAM below 2 GB (${availRamMb} MB free)")
        }
        if (ramUsedPercent >= 90) {
            score += 20
            bullets.add("RAM usage at ${ramUsedPercent}%")
        }
        if (storageFreePercent <= 5) {
            score += 30
            bullets.add("Internal storage critically low (${storageFreePercent}% free)")
        } else if (storageFreePercent <= 10) {
            score += 15
            bullets.add("Internal storage below 10% free")
        }
        if (freeStorageMb < 2048) {
            score += 10
            bullets.add("Less than 2 GB storage free")
        }
        if (runningCount > 80) {
            score += 8
            bullets.add("High running process count ($runningCount)")
        }

        val tier = when {
            score >= 60 -> PressureTier.Critical
            score >= 35 -> PressureTier.High
            score >= 18 -> PressureTier.Medium
            else -> PressureTier.Low
        }
        if (bullets.isEmpty()) {
            bullets.add("Device pressure within normal range")
        }
        bullets.add(0, "Host RAM ${availRamMb}/${totalRamMb} MB · Storage ${freeStorageMb}/${totalStorageMb} MB")
        return Triple(tier, score.coerceIn(0, 100), bullets)
    }

    private fun buildStorageHotspots(
        freeMb: Long,
        totalMb: Long,
        freePercent: Int
    ): List<StorageHotspot> {
        val list = mutableListOf<StorageHotspot>()
        list.add(
            StorageHotspot(
                label = "Internal data partition",
                detail = "${freeMb} MB free of ${totalMb} MB (${freePercent}%)",
                severity = when {
                    freePercent <= 5 -> "critical"
                    freePercent <= 10 -> "high"
                    freePercent <= 20 -> "medium"
                    else -> "low"
                }
            )
        )
        val cacheSize = estimateCacheBytes()
        if (cacheSize > 0) {
            list.add(
                StorageHotspot(
                    label = "App cache (this app)",
                    detail = "${cacheSize / MB} MB in cache dir",
                    severity = if (cacheSize > 256 * MB) "medium" else "low"
                )
            )
        }
        return list
    }

    private fun estimateCacheBytes(): Long {
        return try {
            context.cacheDir?.walkTopDown()?.filter { it.isFile }?.map { it.length() }?.sum() ?: 0L
        } catch (_: Exception) { 0L }
    }

    private fun buildActions(
        tier: PressureTier,
        storageFreePercent: Int,
        availRamMb: Long,
        totalRamMb: Long
    ): List<MaintenanceAction> {
        val actions = mutableListOf<MaintenanceAction>()
        if (storageFreePercent <= 15) {
            actions.add(
                MaintenanceAction(
                    title = "Free storage",
                    detail = "Open system storage settings to remove files and clear app caches.",
                    kind = MaintenanceActionKind.OpenStorageSettings
                )
            )
        }
        if (tier >= PressureTier.Medium || availRamMb < totalRamMb / 4) {
            actions.add(
                MaintenanceAction(
                    title = "Review background apps",
                    detail = "Open app settings to restrict background activity or force-stop non-essential apps.",
                    kind = MaintenanceActionKind.OpenAppSettings
                )
            )
        }
        actions.add(
            MaintenanceAction(
                title = "Enable usage access (optional)",
                detail = "Grants richer per-app storage/usage stats for deeper analysis.",
                kind = MaintenanceActionKind.OpenUsageAccessSettings
            )
        )
        if (tier >= PressureTier.High) {
            actions.add(
                MaintenanceAction(
                    title = "Reboot advisory",
                    detail = "High pressure detected. Reboot clears transient RAM pressure when safe.",
                    kind = MaintenanceActionKind.AdvisoryOnly
                )
            )
        }
        return actions
    }

    private fun importanceLabel(importance: Int): String = when (importance) {
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "Foreground"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "Visible"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "Service"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "Cached"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "Gone"
        else -> "Other ($importance)"
    }

    private fun classifyTrust(processName: String): String {
        val systemPrefixes = listOf(
            "system", "com.android.", "android.", "com.google.android.gms",
            "com.motorola.", "com.qualcomm.", "vendor."
        )
        if (systemPrefixes.any { processName.startsWith(it, ignoreCase = true) }) return "T1-System"
        if (processName.contains("systemui", ignoreCase = true)) return "T1-System"
        return "T3-Unknown"
    }

    private fun advisoryFor(processName: String, importance: Int): String {
        if (importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) {
            return "Foreground — do not stop while in use"
        }
        if (classifyTrust(processName).startsWith("T1")) {
            return "System process — keep"
        }
        if (importance >= ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED) {
            return "Cached — safe to trim via system memory manager"
        }
        return "Review in app settings before force-stop"
    }

    companion object {
        private const val MB = 1024L * 1024L
    }
}
