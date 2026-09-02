package com.systemoptimizerhub.transparency.engine

import android.content.Context
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader

class AppTrustClassifier(context: Context) {

    private val config: JSONObject

    init {
        context.assets.open("process-intelligence-android.json").use { stream ->
            val text = BufferedReader(InputStreamReader(stream)).readText()
            config = JSONObject(text)
        }
    }

    fun classifyPackage(packageName: String): String {
        val vital = config.optJSONArray("vitalExactPackages") ?: return classifyByPrefix(packageName)
        for (i in 0 until vital.length()) {
            if (packageName == vital.getString(i)) return "T1-Vital"
        }
        return classifyByPrefix(packageName)
    }

    fun classifyProcess(processName: String): String {
        val pkg = processName.substringBefore(':')
        return classifyPackage(pkg)
    }

    private fun classifyByPrefix(packageName: String): String {
        val prefixes = config.optJSONArray("systemPackagePrefixes") ?: return "T3-Unknown"
        for (i in 0 until prefixes.length()) {
            if (packageName.startsWith(prefixes.getString(i))) return "T1-System"
        }
        val tunable = config.optJSONObject("tunableCategories")
        if (tunable != null) {
            val keys = tunable.keys()
            while (keys.hasNext()) {
                val cat = keys.next()
                val arr = tunable.optJSONArray(cat) ?: continue
                for (j in 0 until arr.length()) {
                    if (packageName.startsWith(arr.getString(j))) return "T2-Tune"
                }
            }
        }
        return "T3-Unknown"
    }

    fun wasteThresholdCacheMb(): Long =
        config.optJSONObject("wasteSignals")?.optLong("cacheHotspotMb", 128) ?: 128

    fun wasteBackgroundMinutes(): Long =
        config.optJSONObject("wasteSignals")?.optLong("backgroundHeavyMinutes", 120) ?: 120
}
