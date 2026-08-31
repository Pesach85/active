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
