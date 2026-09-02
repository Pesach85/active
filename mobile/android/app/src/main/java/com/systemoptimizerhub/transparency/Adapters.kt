package com.systemoptimizerhub.transparency

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class ProcessAdapter(private val items: List<ProcessEntry>) :
    RecyclerView.Adapter<ProcessAdapter.VH>() {

    class VH(v: View) : RecyclerView.ViewHolder(v) {
        val name: TextView = v.findViewById(R.id.processName)
        val meta: TextView = v.findViewById(R.id.processMeta)
        val advisory: TextView = v.findViewById(R.id.processAdvisory)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context).inflate(R.layout.item_process, parent, false)
        return VH(v)
    }

    override fun getItemCount() = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val p = items[position]
        holder.name.text = p.processName
        holder.meta.text = "pid=${p.pid} · ${p.importanceLabel} · ${p.trustLabel}"
        holder.advisory.text = p.advisory
    }
}

class StorageAdapter(private val items: List<StorageHotspot>) :
    RecyclerView.Adapter<StorageAdapter.VH>() {

    class VH(v: View) : RecyclerView.ViewHolder(v) {
        val label: TextView = v.findViewById(R.id.storageLabel)
        val detail: TextView = v.findViewById(R.id.storageDetail)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context).inflate(R.layout.item_storage, parent, false)
        return VH(v)
    }

    override fun getItemCount() = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val s = items[position]
        holder.label.text = "${s.label} [${s.severity}]"
        holder.detail.text = s.detail
    }
}

class ActionAdapter(
    private val items: List<MaintenanceAction>,
    private val onClick: (MaintenanceAction) -> Unit
) : RecyclerView.Adapter<ActionAdapter.VH>() {

    class VH(v: View) : RecyclerView.ViewHolder(v) {
        val title: TextView = v.findViewById(R.id.actionTitle)
        val detail: TextView = v.findViewById(R.id.actionDetail)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context).inflate(R.layout.item_action, parent, false)
        return VH(v)
    }

    override fun getItemCount() = items.size

    override fun onBindViewHolder(holder: VH, position: Int) {
        val a = items[position]
        holder.title.text = a.title
        holder.detail.text = a.detail
        holder.itemView.setOnClickListener {
            if (a.kind != MaintenanceActionKind.AdvisoryOnly) onClick(a)
        }
    }
}
