async function fetchReport(refresh = false) {
  const url = refresh ? '/api/refresh' : '/api/report.json';
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) throw new Error('Report unavailable');
  if (refresh) {
    const r2 = await fetch('/api/report.json', { cache: 'no-store' });
    return r2.json();
  }
  return res.json();
}

function trustClass(level) {
  return 'trust-' + (level || 'T3_Unknown');
}

function renderReport(data) {
  document.getElementById('postureScore').textContent = data.Posture?.Score ?? '—';
  const gradeEl = document.getElementById('postureGrade');
  const grade = data.Posture?.Grade ?? '';
  gradeEl.textContent = grade;
  gradeEl.className = 'grade ' + (grade === 'Good' ? 'good' : grade === 'Review' ? 'review' : 'alert');

  const notes = document.getElementById('postureNotes');
  notes.innerHTML = '';
  (data.Posture?.Notes || []).forEach(n => {
    const li = document.createElement('li');
    li.textContent = n;
    notes.appendChild(li);
  });

  const host = document.getElementById('hostStats');
  host.innerHTML = '';
  const h = data.Host || {};
  const pairs = [
    ['Tier / Profile', `${h.Tier} / ${h.Profile}`],
    ['RAM libera', `${h.FreeRamMb} MB / ${h.TotalRamGb} GB`],
    ['Top-N RAM usata', `${h.UsedRamMbTopN} MB`],
    ['Disco C: libero', `${h.DriveCFreePercent}%`],
    ['CPU logiche', h.LogicalProcessors]
  ];
  pairs.forEach(([k, v]) => {
    const dt = document.createElement('dt'); dt.textContent = k;
    const dd = document.createElement('dd'); dd.textContent = v ?? '—';
    host.appendChild(dt); host.appendChild(dd);
  });

  const ramBody = document.getElementById('ramBody');
  ramBody.innerHTML = '';
  (data.RamConsumers || []).forEach(p => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${p.Name} <span class="muted">(${p.PID})</span></td>
      <td>${p.RamMb}</td>
      <td class="${trustClass(p.TrustLevel)}">${p.TrustLevel}</td>
      <td>${p.TrustReason || ''}</td>`;
    ramBody.appendChild(tr);
  });

  const agentsBody = document.getElementById('agentsBody');
  agentsBody.innerHTML = '';
  (data.RegisteredAgents || []).forEach(a => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${a.DisplayName}</td><td>${a.TaskState}</td>
      <td class="${trustClass(a.ControlLevel)}">${a.ControlLevel}</td>`;
    agentsBody.appendChild(tr);
  });

  const actionsList = document.getElementById('actionsList');
  actionsList.innerHTML = '';
  (data.RecentAutomatedActions || []).slice().reverse().forEach(a => {
    const li = document.createElement('li');
    li.innerHTML = `<span class="ts">${a.Timestamp || ''} · ${a.Source || ''}</span>
      <strong>${a.Action || ''}</strong> — ${a.Detail || ''}`;
    actionsList.appendChild(li);
  });

  const net = data.Network;
  const netSummary = document.getElementById('networkSummary');
  const networkBody = document.getElementById('networkBody');
  const hiddenNetList = document.getElementById('hiddenNetList');
  networkBody.innerHTML = '';
  hiddenNetList.innerHTML = '';
  if (net && net.Available !== false && net.Summary) {
    const s = net.Summary;
    netSummary.textContent = `${s.Established} established · ${s.Listen} listen · loopback ${s.LoopbackOnly} · public ${s.PublicRemote} · T3 ${s.UnknownTrustCount}`;
    const rows = (net.Connections || []).filter(c => c.TrustLevel === 'T3_Unknown' || c.TrustLevel === 'T2_Review').slice(0, 20);
    if (!rows.length) {
      rows.push(...(net.Connections || []).slice(0, 12));
    }
    rows.forEach(c => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${c.ProcessName} (${c.PID})</td><td>${c.Local}</td><td>${c.Remote}</td>
        <td class="${trustClass(c.TrustLevel)}">${c.TrustLevel}</td>`;
      networkBody.appendChild(tr);
    });
    (net.HiddenNetworkProcesses || []).forEach(h => {
      const li = document.createElement('li');
      li.innerHTML = `<strong>${h.Name}</strong> PID ${h.PID} · ${h.RamMb}MB · ext=${h.ExternalConnections} — ${h.TrustReason}`;
      hiddenNetList.appendChild(li);
    });
  } else {
    netSummary.textContent = net && net.Error ? `Network unavailable: ${net.Error}` : 'Network data not collected';
  }

  const hintsList = document.getElementById('hintsList');
  hintsList.innerHTML = '';
  (data.ClassificationHints || []).forEach(h => {
    const li = document.createElement('li');
    li.innerHTML = `<strong>${h.ProcessName}</strong> · ${h.SuggestedCategory} / ${h.SuggestedPriority}
      · conf ${h.Confidence} · ${h.TrustLevel}<br>
      <span class="muted">${h.WhatItIs}</span><br>${h.WhatItDoes}`;
    hintsList.appendChild(li);
  });

  const dm = data.DelegationManifest || {};
  fillList('policyPrinciples', dm.Principles);
  fillList('policyHuman', dm.HumanOnly);
  fillList('policyAi', dm.AiDelegatedWhenEnabled);

  const levels = document.getElementById('controlLevels');
  levels.innerHTML = '';
  const cl = data.ControlLevels || {};
  Object.keys(cl).forEach(k => {
    const span = document.createElement('span');
    span.innerHTML = `<strong class="${trustClass(k)}">${k}</strong>: ${cl[k]} · `;
    levels.appendChild(span);
  });

  document.getElementById('lastUpdate').textContent = 'Aggiornato: ' + (data.GeneratedAt || new Date().toLocaleString());
}

function fillList(id, items) {
  const ul = document.getElementById(id);
  ul.innerHTML = '';
  (items || []).forEach(t => {
    const li = document.createElement('li');
    li.textContent = t;
    ul.appendChild(li);
  });
}

async function load(refresh = false) {
  try {
    const data = await fetchReport(refresh);
    renderReport(data);
  } catch (e) {
    document.getElementById('postureScore').textContent = '!';
    document.getElementById('postureGrade').textContent = 'Errore caricamento';
  }
}

document.getElementById('btnRefresh').addEventListener('click', () => load(true));
load(false);
setInterval(() => load(false), 30000);
