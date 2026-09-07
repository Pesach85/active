package com.systemoptimizerhub.transparency

data class DeviceSnapshot(
    val schemaVersion: String = "DeviceSnapshot.v1",
    val generatedAtEpochMs: Long,
    val engineVersion: String,
    val totalRamMb: Long,
    val availRamMb: Long,
    val ramUsedPercent: Int,
    val totalStorageMb: Long,
    val freeStorageMb: Long,
    val storageFreePercent: Int,
    val installedAppsCount: Int,
    val runningProcessCount: Int,
    val pressureTier: PressureTier,
    val pressureScore: Int,
    val summaryBullets: List<String>,
    val topProcesses: List<ProcessEntry>,
    val topApps: List<AppPressureEntry>,
    val storageHotspots: List<StorageHotspot>,
    val wasteFindings: List<WasteFinding>,
    val battery: BatterySnapshot,
    val network: NetworkSnapshot,
    val bootApps: List<BootAppEntry>,
    val recommendedActions: List<MaintenanceAction>,
    val transparencyPostureScore: Int,
    val reportPath: String? = null
)

data class ProcessEntry(
    val processName: String,
    val pid: Int,
    val importanceLabel: String,
    val importance: Int,
    val isForeground: Boolean,
    val trustLabel: String,
    val dominantPressure: String,
    val score: Int,
    val advisory: String
)

data class AppPressureEntry(
    val packageName: String,
    val label: String,
    val cacheMb: Long,
    val dataMb: Long,
    val totalMb: Long,
    val foregroundMinutes: Long,
    val backgroundMinutes: Long,
    val trustLabel: String,
    val wasteScore: Int,
    val advisory: String
)

data class StorageHotspot(
    val label: String,
    val detail: String,
    val severity: String,
    val packageName: String? = null
)

data class WasteFinding(
    val category: String,
    val severity: String,
    val title: String,
    val detail: String,
    val packageName: String? = null
)

data class BatterySnapshot(
    val levelPercent: Int,
    val isCharging: Boolean,
    val powerSaveMode: Boolean,
    val healthHint: String
)

data class NetworkSnapshot(
    val activeType: String,
    val isMetered: Boolean,
    val rxMb: Long,
    val txMb: Long,
    val detail: String
)

data class BootAppEntry(
    val packageName: String,
    val label: String,
    val enabled: Boolean
)

enum class PressureTier { Low, Medium, High, Critical }

enum class MaintenanceActionKind {
    OpenStorageSettings,
    OpenAppSettings,
    OpenUsageAccessSettings,
    OpenBatterySettings,
    OpenAppDetail,
    ClearOwnCache,
    RequestMemoryTrim,
    ExportReport,
    AdvisoryOnly
}

data class MaintenanceAction(
    val title: String,
    val detail: String,
    val kind: MaintenanceActionKind,
    val packageName: String? = null
)
