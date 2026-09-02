package com.systemoptimizerhub.transparency

data class DeviceSnapshot(
    val generatedAtEpochMs: Long,
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
    val storageHotspots: List<StorageHotspot>,
    val recommendedActions: List<MaintenanceAction>
)

data class ProcessEntry(
    val processName: String,
    val pid: Int,
    val importanceLabel: String,
    val importance: Int,
    val isForeground: Boolean,
    val trustLabel: String,
    val advisory: String
)

data class StorageHotspot(
    val label: String,
    val detail: String,
    val severity: String
)

enum class PressureTier { Low, Medium, High, Critical }

enum class MaintenanceActionKind {
    OpenStorageSettings,
    OpenAppSettings,
    OpenUsageAccessSettings,
    AdvisoryOnly
}

data class MaintenanceAction(
    val title: String,
    val detail: String,
    val kind: MaintenanceActionKind,
    val packageName: String? = null
)
