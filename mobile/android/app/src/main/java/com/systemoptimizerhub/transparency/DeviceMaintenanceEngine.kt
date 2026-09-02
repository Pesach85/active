package com.systemoptimizerhub.transparency

import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Environment
import android.os.StatFs
import com.systemoptimizerhub.transparency.engine.AppTrustClassifier
import com.systemoptimizerhub.transparency.engine.BatteryPressureSignal
import com.systemoptimizerhub.transparency.engine.BootAppsAuditor
import com.systemoptimizerhub.transparency.engine.MemoryLiberationAdvisor
import com.systemoptimizerhub.transparency.engine.NetworkSnapshotService
import com.systemoptimizerhub.transparency.engine.ProcessPressureEngine
import com.systemoptimizerhub.transparency.engine.StorageHotspotAnalyzer
import com.systemoptimizerhub.transparency.engine.UsageStatsCollector
import com.systemoptimizerhub.transparency.engine.WasteResourceAnalyzer
import com.systemoptimizerhub.transparency.report.TransparencyReportBuilder
import kotlin.math.roundToInt

/**
 * On-device maintenance orchestrator — parity with desktop PPI / transparency / waste analysis.
 */
class DeviceMaintenanceEngine(private val context: Context) {

    private val activityManager =
        context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val packageManager = context.packageManager
    private val trust = AppTrustClassifier(context)
    private val usage = UsageStatsCollector(context)
    private val processEngine = ProcessPressureEngine(context, trust)
    private val storageAnalyzer = StorageHotspotAnalyzer(context, trust)
    private val batterySignal = BatteryPressureSignal(context)
    private val networkService = NetworkSnapshotService(context)
    private val bootAuditor = BootAppsAuditor(context)
    private val wasteAnalyzer = WasteResourceAnalyzer(trust, usage)
    private val memoryAdvisor = MemoryLiberationAdvisor(context)
    private val reportBuilder = TransparencyReportBuilder(context)

    fun analyze(topProcessLimit: Int = 12, exportReport: Boolean = false): DeviceSnapshot {
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

        val topProcesses = processEngine.topProcesses(topProcessLimit)
        val runningCount = activityManager.runningAppProcesses.orEmpty().size
        val cachedCount = processEngine.cachedProcessCount()
        val storageHotspots = storageAnalyzer.analyze()
        val storageApps = storageAnalyzer.topAppStorage(12)
        val battery = batterySignal.snapshot()
        val network = networkService.snapshot()
        val bootApps = bootAuditor.audit()
        val hasUsage = usage.hasUsageAccess()

        val topApps = buildTopApps(storageApps, usage.topApps(15))
        val wasteFindings = wasteAnalyzer.analyze(
            storageApps = storageApps,
            runningCachedCount = cachedCount,
            availRamMb = availRamMb,
            storageFreePercent = storageFreePercent
        )

        val (tier, score, bullets) = computePressure(
            availRamMb, totalRamMb, ramUsedPercent,
            freeStorageMb, totalStorageMb, storageFreePercent,
            mem.lowMemory, runningCount, cachedCount,
            wasteFindings.size, battery, network
        )

        val actions = memoryAdvisor.buildActions(
            tier, availRamMb, totalRamMb, storageFreePercent, wasteFindings, hasUsage
        )

        val posture = computeTransparencyPosture(
            hasUsage, wasteFindings, storageFreePercent, availRamMb, totalRamMb
        )

        var snap = DeviceSnapshot(
            generatedAtEpochMs = System.currentTimeMillis(),
            engineVersion = BuildConfig.ENGINE_VERSION,
            totalRamMb = totalRamMb,
            availRamMb = availRamMb,
            ramUsedPercent = ramUsedPercent,
            totalStorageMb = totalStorageMb,
            freeStorageMb = freeStorageMb,
            storageFreePercent = storageFreePercent,
            installedAppsCount = installedApps,
            runningProcessCount = runningCount,
            pressureTier = tier,
            pressureScore = score,
            summaryBullets = bullets,
            topProcesses = topProcesses,
            topApps = topApps,
            storageHotspots = storageHotspots,
            wasteFindings = wasteFindings,
            battery = battery,
            network = network,
            bootApps = bootApps,
            recommendedActions = actions,
            transparencyPostureScore = posture
        )

        if (exportReport) {
            val path = reportBuilder.export(snap)
            snap = snap.copy(reportPath = path)
        }
        return snap
    }

    fun clearOwnCache(): Long = memoryAdvisor.clearOwnCache()

    fun requestMemoryTrim() = memoryAdvisor.requestMemoryTrim(activityManager)

    fun exportReport(): String {
        val snap = analyze(exportReport = true)
        return snap.reportPath ?: ""
    }

    private fun buildTopApps(
        storage: List<com.systemoptimizerhub.transparency.engine.AppStorageRow>,
        usageRows: List<com.systemoptimizerhub.transparency.engine.UsageAppRow>
    ): List<AppPressureEntry> {
        val usageByPkg = usageRows.associateBy { it.packageName }
        return storage.map { row ->
            val u = usageByPkg[row.packageName]
            val wasteScore = computeAppWasteScore(row.cacheMb, u?.backgroundMinutes ?: 0)
            AppPressureEntry(
                packageName = row.packageName,
                label = row.label,
                cacheMb = row.cacheMb,
                dataMb = row.dataMb,
                totalMb = row.totalMb,
                foregroundMinutes = u?.foregroundMinutes ?: 0,
                backgroundMinutes = u?.backgroundMinutes ?: 0,
                trustLabel = row.trustLabel,
                wasteScore = wasteScore,
                advisory = appAdvisory(row.trustLabel, row.cacheMb, wasteScore)
            )
        }
    }

    private fun computeAppWasteScore(cacheMb: Long, bgMinutes: Long): Int {
        var s = 0
        if (cacheMb >= trust.wasteThresholdCacheMb()) s += 30
        if (cacheMb >= trust.wasteThresholdCacheMb() * 2) s += 20
        if (bgMinutes >= trust.wasteBackgroundMinutes()) s += 25
        return s.coerceIn(0, 100)
    }

    private fun appAdvisory(trustLabel: String, cacheMb: Long, wasteScore: Int): String = when {
        trustLabel.startsWith("T1") -> "System/vital — do not remove"
        wasteScore >= 50 -> "High waste signal — review cache and background usage"
        cacheMb >= trust.wasteThresholdCacheMb() -> "Large cache — clear via Settings"
        else -> "Within normal range"
    }

    private fun computePressure(
        availRamMb: Long,
        totalRamMb: Long,
        ramUsedPercent: Int,
        freeStorageMb: Long,
        totalStorageMb: Long,
        storageFreePercent: Int,
        lowMemory: Boolean,
        runningCount: Int,
        cachedCount: Int,
        wasteCount: Int,
        battery: BatterySnapshot,
        network: NetworkSnapshot
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
        if (cachedCount >= 40) {
            score += 6
            bullets.add("Many cached processes ($cachedCount)")
        }
        if (wasteCount >= 3) {
            score += 8
            bullets.add("$wasteCount resource waste findings")
        }
        score += batterySignal.pressureBonus(battery)

        val tier = when {
            score >= 60 -> PressureTier.Critical
            score >= 35 -> PressureTier.High
            score >= 18 -> PressureTier.Medium
            else -> PressureTier.Low
        }
        if (bullets.isEmpty()) bullets.add("Device pressure within normal range")
        bullets.add(0, "Host RAM ${availRamMb}/${totalRamMb} MB · Storage ${freeStorageMb}/${totalStorageMb} MB")
        bullets.add("Battery ${battery.levelPercent}% · Network ${network.activeType}")
        return Triple(tier, score.coerceIn(0, 100), bullets)
    }

    private fun computeTransparencyPosture(
        hasUsage: Boolean,
        waste: List<WasteFinding>,
        storageFreePercent: Int,
        availRamMb: Long,
        totalRamMb: Long
    ): Int {
        var score = 70
        if (hasUsage) score += 15 else score -= 10
        val highWaste = waste.count { it.severity == "high" }
        score -= highWaste * 5
        if (storageFreePercent <= 10) score -= 10
        if (availRamMb < totalRamMb / 4) score -= 10
        return score.coerceIn(0, 100)
    }

    companion object {
        private const val MB = 1024L * 1024L
    }
}
