package com.systemoptimizerhub.transparency.engine

import android.app.ActivityManager
import android.content.Context
import android.os.BatteryManager
import android.os.PowerManager
import com.systemoptimizerhub.transparency.BatterySnapshot

class BatteryPressureSignal(private val context: Context) {

    fun snapshot(): BatterySnapshot {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).coerceIn(0, 100)
        val charging = bm.isCharging
        val powerSave = pm.isPowerSaveMode
        val healthHint = when {
            powerSave -> "Power save mode active — background apps restricted"
            level <= 15 && !charging -> "Low battery — consider closing heavy apps"
            level <= 30 && !charging -> "Battery moderate — reduce background sync"
            else -> "Battery OK"
        }
        return BatterySnapshot(level, charging, powerSave, healthHint)
    }

    fun pressureBonus(snapshot: BatterySnapshot): Int {
        var bonus = 0
        if (snapshot.powerSaveMode) bonus += 5
        if (snapshot.levelPercent <= 15 && !snapshot.isCharging) bonus += 10
        return bonus
    }
}
