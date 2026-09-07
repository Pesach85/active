package com.systemoptimizerhub.transparency.engine

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.util.Log
import com.systemoptimizerhub.transparency.NetworkSnapshot

class NetworkSnapshotService(private val context: Context) {

    fun snapshot(): NetworkSnapshot {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork
            val caps = network?.let { cm.getNetworkCapabilities(it) }
            val type = when {
                caps == null -> "None"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
                else -> "Other"
            }
            val metered = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
            val rx = TrafficStats.getTotalRxBytes().coerceAtLeast(0) / MB
            val tx = TrafficStats.getTotalTxBytes().coerceAtLeast(0) / MB
            val detail = buildString {
                append("Active: $type")
                if (metered) append(" · metered")
                append(" · device totals rx=${rx}MB tx=${tx}MB")
            }
            NetworkSnapshot(type, metered, rx, tx, detail)
        } catch (ex: Exception) {
            Log.w(TAG, "network snapshot fallback", ex)
            NetworkSnapshot(
                activeType = "Unknown",
                isMetered = false,
                rxMb = 0,
                txMb = 0,
                detail = "Network state unavailable (${ex.javaClass.simpleName})"
            )
        }
    }

    companion object {
        private const val TAG = "HubAndroid"
        private const val MB = 1024L * 1024L
    }
}
