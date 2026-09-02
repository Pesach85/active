package com.systemoptimizerhub.transparency.report

import android.content.Context
import com.systemoptimizerhub.transparency.DeviceSnapshot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class TransparencyReportBuilder(private val context: Context) {

    fun export(snapshot: DeviceSnapshot): String {
        val dir = File(context.filesDir, "logs").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(dir, "transparency-report-$stamp.json")
        file.writeText(toJson(snapshot).toString(2))
        return file.absolutePath
    }

    fun toJson(s: DeviceSnapshot): JSONObject {
        val root = JSONObject()
        root.put("SchemaVersion", "AndroidTransparencyReport.v1")
        root.put("GeneratedAt", s.generatedAtEpochMs)
        root.put("EngineVersion", s.engineVersion)
        root.put("PressureTier", s.pressureTier.name)
        root.put("PressureScore", s.pressureScore)
        root.put("TransparencyPostureScore", s.transparencyPostureScore)
        root.put("Host", JSONObject().apply {
            put("RamAvailMb", s.availRamMb)
            put("RamTotalMb", s.totalRamMb)
            put("StorageFreeMb", s.freeStorageMb)
            put("StorageTotalMb", s.totalStorageMb)
            put("InstalledApps", s.installedAppsCount)
            put("RunningProcesses", s.runningProcessCount)
        })
        root.put("SummaryBullets", JSONArray(s.summaryBullets))
        root.put("Battery", JSONObject().apply {
            put("LevelPercent", s.battery.levelPercent)
            put("Charging", s.battery.isCharging)
            put("PowerSave", s.battery.powerSaveMode)
            put("Hint", s.battery.healthHint)
        })
        root.put("Network", JSONObject().apply {
            put("Type", s.network.activeType)
            put("Metered", s.network.isMetered)
            put("RxMb", s.network.rxMb)
            put("TxMb", s.network.txMb)
            put("Detail", s.network.detail)
        })
        root.put("WasteFindings", JSONArray().apply {
            s.wasteFindings.forEach { w ->
                put(JSONObject().apply {
                    put("Category", w.category)
                    put("Severity", w.severity)
                    put("Title", w.title)
                    put("Detail", w.detail)
                    put("PackageName", w.packageName)
                })
            }
        })
        root.put("TopApps", JSONArray().apply {
            s.topApps.forEach { a ->
                put(JSONObject().apply {
                    put("Package", a.packageName)
                    put("Label", a.label)
                    put("CacheMb", a.cacheMb)
                    put("TotalMb", a.totalMb)
                    put("WasteScore", a.wasteScore)
                    put("Trust", a.trustLabel)
                })
            }
        })
        return root
    }
}
