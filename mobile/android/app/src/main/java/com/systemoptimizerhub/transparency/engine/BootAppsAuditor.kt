package com.systemoptimizerhub.transparency.engine

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import com.systemoptimizerhub.transparency.BootAppEntry

class BootAppsAuditor(private val context: Context) {

    fun audit(limit: Int = 15): List<BootAppEntry> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_BOOT_COMPLETED)
        val receivers = pm.queryBroadcastReceivers(intent, PackageManager.GET_META_DATA)
        return receivers
            .mapNotNull { ri ->
                val appInfo = ri.activityInfo?.applicationInfo ?: return@mapNotNull null
                val pkg = appInfo.packageName
                val label = pm.getApplicationLabel(appInfo).toString()
                val enabled = appInfo.enabled
                BootAppEntry(pkg, label, enabled)
            }
            .distinctBy { it.packageName }
            .sortedBy { it.label.lowercase() }
            .take(limit)
    }
}
