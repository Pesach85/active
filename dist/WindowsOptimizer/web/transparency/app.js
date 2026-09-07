let reportData = null;
let wizardTarget = null;
let wizardPayload = null;
let wizardOpen = false;
let refreshTimer = null;
let lastDeepScan = null;

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

function parseEndpoint(value) {
  if (!value) return { host: '', port: 0 };
  const idx = value.lastIndexOf(':');
  if (idx <= 0) return { host: value, port: 0 };
  return { host: value.slice(0, idx), port: parseInt(value.slice(idx + 1), 10) || 0 };
}

async function loadDeepScanLatest() {
  try {
    const res = await fetch('/api/network/deep-scan/latest');
    if (res.ok) {
      lastDeepScan = await res.json();
      renderDeepScanFindings();
    }
  } catch (_) { /* optional */ }
}

async function postNetworkAction(action, fields = {}) {
  const sessionToken = await ensureHitlSession();
  if (!sessionToken) return null;
  const status = document.getElementById('networkDeepStatus');
  if (status) status.textContent = 'Azione rete in corso…';
  const body = { action, sessionToken, understandRisk: true, ...fields };
  const res = await fetch('/api/network/action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data.message || data.result?.Message || data.error || 'Azione fallita';
    if (status) status.textContent = msg;
    if (data.error === 'auth_failed' || /session expired/i.test(msg)) clearHitlSession();
    return null;
  }
  if (status) status.textContent = data.Message || data.message || 'OK';
  await load(true);
  return data;
}

function renderReport(data) {
  reportData = data;
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
      <td>${p.TrustReason || ''}</td>
      <td class="btn-row">
        <button type="button" class="btn-mini" data-action="resolve" data-pid="${p.PID}" data-name="${p.Name}">Risolvi</button>
        <button type="button" class="btn-mini" data-action="identify" data-pid="${p.PID}" data-name="${p.Name}">Identifica</button>
      </td>`;
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
  const networkListenersBody = document.getElementById('networkListenersBody');
  const hiddenNetList = document.getElementById('hiddenNetList');
  networkBody.innerHTML = '';
  if (networkListenersBody) networkListenersBody.innerHTML = '';
  hiddenNetList.innerHTML = '';
  if (net && net.Available !== false && net.Summary) {
    const s = net.Summary;
    netSummary.textContent = `${s.Established} established · ${s.Listen} listen · loopback ${s.LoopbackOnly} · public ${s.PublicRemote} · T3 ${s.UnknownTrustCount} · hidden ${s.HiddenNetworkProcessCount || 0}`;
    const rows = (net.Connections || []).filter(c => c.TrustLevel === 'T3_Unknown' || c.TrustLevel === 'T2_Review').slice(0, 20);
    if (!rows.length) {
      rows.push(...(net.Connections || []).slice(0, 12));
    }
    rows.forEach(c => {
      const ep = parseEndpoint(c.Local || '');
      const er = parseEndpoint(c.Remote || '');
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${c.ProcessName} (${c.PID})</td><td>${c.Local}</td><td>${c.Remote}</td>
        <td class="${trustClass(c.TrustLevel)}">${c.TrustLevel}</td>
        <td class="btn-row net-actions">
          <button type="button" class="btn-mini" data-action="resolve" data-pid="${c.PID}" data-name="${c.ProcessName}">Risolvi</button>
          <button type="button" class="btn-mini" data-net-action="kill" data-pid="${c.PID}" data-name="${c.ProcessName}"
            data-local="${ep.host}" data-local-port="${ep.port}" data-remote="${er.host}" data-remote-port="${er.port}">Kill conn</button>
          <button type="button" class="btn-mini" data-net-action="block" data-remote="${er.host}">Block IP</button>
          <button type="button" class="btn-mini" data-net-action="terminate" data-pid="${c.PID}" data-name="${c.ProcessName}">Termina</button>
        </td>`;
      networkBody.appendChild(tr);
    });
    (net.Listeners || []).slice(0, 30).forEach(c => {
      if (!networkListenersBody) return;
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${c.ProcessName} (${c.PID})</td><td>${c.Local}</td><td class="${trustClass(c.TrustLevel)}">${c.TrustLevel}</td>`;
      networkListenersBody.appendChild(tr);
    });
    (net.HiddenNetworkProcesses || []).forEach(hn => {
      const li = document.createElement('li');
      li.innerHTML = `<strong>${hn.Name}</strong> PID ${hn.PID} · ${hn.RamMb}MB · ext=${hn.ExternalConnections} — ${hn.TrustReason}
        <button type="button" class="btn-mini" data-action="resolve" data-pid="${hn.PID}" data-name="${hn.Name}">Risolvi</button>`;
      hiddenNetList.appendChild(li);
    });
  } else {
    netSummary.textContent = net && net.Error ? `Network unavailable: ${net.Error}` : 'Network data not collected';
  }
  renderDeepScanFindings();

  const hintsList = document.getElementById('hintsList');
  hintsList.innerHTML = '';
  (data.ClassificationHints || []).forEach(hint => {
    const li = document.createElement('li');
    let forensicsLine = '';
    if (hint.Forensics && hint.Forensics.Inferences && hint.Forensics.Inferences.length) {
      forensicsLine = `<br><span class="muted">Forensics: ${hint.Forensics.Inferences.join(' · ')}</span>`;
    }
    li.innerHTML = `<strong>${hint.ProcessName}</strong> · ${hint.SuggestedCategory} / ${hint.SuggestedPriority}
      · conf ${hint.Confidence} · ${hint.TrustLevel}<br>
      <span class="muted">${hint.WhatItIs}</span><br>${hint.WhatItDoes}${forensicsLine}`;
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
  if (wizardOpen && !refresh) return;
  const banner = document.getElementById('offlineBanner');
  try {
    const data = await fetchReport(refresh);
    if (banner) banner.classList.add('hidden');
    renderReport(data);
  } catch (e) {
    document.getElementById('postureScore').textContent = '!';
    document.getElementById('postureGrade').textContent = 'Server non avviato';
    document.getElementById('postureNotes').innerHTML =
      '<li><strong>ERR_CONNECTION_REFUSED</strong> — nessun listener su :8765.</li>' +
      '<li>GUI → Control → <strong>Web Dashboard</strong></li>' +
      '<li>CMD: <code>scripts\\run-transparency-web.bat</code></li>' +
      '<li>PS: <code>powershell -File scripts\\run-transparency-web.ps1 -OpenBrowser</code></li>' +
      '<li>Non usare <code>pwsh -File *.bat</code>.</li>';
    if (banner) banner.classList.remove('hidden');
  }
}

function setWizardStatus(msg, isError = false) {
  const el = document.getElementById('wizardStatus');
  el.textContent = msg || '';
  el.style.color = isError ? 'var(--red)' : 'var(--muted)';
}

async function updateHitlSessionUi() {
  const token = sessionStorage.getItem('hubHitlSessionToken');
  const locked = document.getElementById('authLocked');
  const loggedIn = document.getElementById('authLoggedIn');
  const msgEl = document.getElementById('sessionLoggedInMsg');
  if (!token) {
    locked?.classList.remove('hidden');
    loggedIn?.classList.add('hidden');
    return false;
  }
  try {
    const res = await fetch(`/api/operator/session/status?token=${encodeURIComponent(token)}`, { cache: 'no-store' });
    const data = await res.json();
    if (data.active) {
      locked?.classList.add('hidden');
      loggedIn?.classList.remove('hidden');
      const exp = data.expiresAt ? new Date(data.expiresAt).toLocaleTimeString() : '';
      msgEl.textContent = exp ? `Sessione attiva fino alle ${exp}` : 'Sessione HITL attiva';
      return true;
    }
  } catch { /* offline or stale */ }
  sessionStorage.removeItem('hubHitlSessionToken');
  locked?.classList.remove('hidden');
  loggedIn?.classList.add('hidden');
  return false;
}

function clearHitlSession() {
  sessionStorage.removeItem('hubHitlSessionToken');
  const pwd = document.getElementById('operatorPassword');
  if (pwd) pwd.value = '';
  updateHitlSessionUi();
}

function getSessionToken() {
  const stored = sessionStorage.getItem('hubHitlSessionToken');
  if (stored) return stored;
  const pwd = document.getElementById('operatorPassword')?.value;
  if (!pwd) {
    setWizardStatus('Sblocca sessione HITL (password una volta).', true);
    return null;
  }
  return null;
}

async function ensureHitlSession() {
  const stored = sessionStorage.getItem('hubHitlSessionToken');
  if (stored && await updateHitlSessionUi()) return stored;
  const pwd = document.getElementById('operatorPassword')?.value;
  if (!pwd) {
    setWizardStatus('Inserisci password e clicca Sblocca sessione.', true);
    return null;
  }
  const res = await fetch('/api/operator/session/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: pwd, humanPresent: true, riskAcknowledged: true })
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    setWizardStatus(data.message || 'Sessione HITL fallita', true);
    return null;
  }
  sessionStorage.setItem('hubHitlSessionToken', data.sessionToken);
  document.getElementById('operatorPassword').value = '';
  await updateHitlSessionUi();
  setWizardStatus('');
  return data.sessionToken;
}

function getPassword() {
  return document.getElementById('operatorPassword')?.value || null;
}

function formatAdvisory(payload) {
  const p = payload.Process || {};
  const adv = payload.Advisory || {};
  const hint = payload.KnowledgeHint || {};
  const lines = [];
  lines.push(`PROCESS: ${p.ProcessName} PID=${p.PID} RAM=${p.RamMb}MB`);
  if (p.NotRunning) lines.push('⚠ Processo non in esecuzione');
  lines.push('');
  lines.push('AI / KB:', adv.AiAidedSummary || '—');
  if (hint.WhatItIs) lines.push('WhatItIs:', hint.WhatItIs);
  if (hint.WhatItDoes) lines.push('WhatItDoes:', hint.WhatItDoes);
  lines.push('');
  lines.push('RECOMMENDED:', adv.RecommendedActionId);
  (adv.Warnings || []).forEach(w => lines.push('•', w));
  (adv.Options || []).forEach(o => lines.push(`[${o.ActionId}] ${o.Label} (cost=${o.EfficiencyCost})`));
  return lines.join('\n');
}

async function openWizard(target, identifyTab = false) {
  wizardOpen = true;
  wizardTarget = target;
  wizardPayload = null;
  setWizardStatus('');
  document.getElementById('operatorPassword').value = '';
  await updateHitlSessionUi();
  document.getElementById('wizardOverlay').classList.remove('hidden');
  document.getElementById('wizardOverlay').setAttribute('aria-hidden', 'false');
  document.getElementById('wizardTitle').textContent = identifyTab
    ? `Identifica: ${target.name} (${target.pid})`
    : `Risolvi: ${target.name} (${target.pid})`;

  try {
    const res = await fetch('/api/operator-identity');
    if (res.ok) {
      const id = await res.json();
      document.getElementById('operatorUser').textContent = `Utente: ${id.Domain}\\${id.UserName}`;
    }
  } catch { }

  const advRes = await fetch('/api/process/advisory', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ processId: target.pid, processName: target.name, offline: true })
  });
  if (!advRes.ok) {
    const errData = await advRes.json().catch(() => ({}));
    setWizardStatus(errData.message || errData.error || 'Impossibile caricare advisory.', true);
    return;
  }
  wizardPayload = await advRes.json();
  document.getElementById('wizardAdvisory').textContent = formatAdvisory(wizardPayload);

  try {
    const fr = await fetch('/api/process/forensics', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ processId: target.pid, processName: target.name, includeMemory: false })
    });
    if (fr.ok) {
      const fp = await fr.json();
      if (fp.Inferences && fp.Inferences.length) {
        document.getElementById('wizardAdvisory').textContent +=
          '\n\n=== FORENSICS (PE / moduli / memoria) ===\n' + fp.Inferences.join('\n');
      }
    }
  } catch { }

  const hint = wizardPayload.KnowledgeHint || {};
  document.getElementById('idWhatIs').value = hint.WhatItIs || '';
  document.getElementById('idWhatDoes').value = hint.WhatItDoes || '';
  document.getElementById('idBusiness').value = hint.BusinessHint || '';
  if (hint.SuggestedCategory) document.getElementById('idCategory').value = hint.SuggestedCategory;
  if (hint.SuggestedPriority) document.getElementById('idPriority').value = hint.SuggestedPriority;

  const notRunning = wizardPayload.Process?.NotRunning;
  const blocked = new Set(wizardPayload.Advisory?.BlockedActionIds || []);
  document.getElementById('btnThrottle').disabled = !!notRunning || blocked.has('ThrottleBelowNormal');
  document.getElementById('btnStop').disabled = !!notRunning || blocked.has('Terminate');
  if (wizardPayload.CatalogNecessity?.Priority === 'Keep') {
    setWizardStatus('Priority=Keep: Throttle/Stop bloccati. Usa Osserva o tuning schedule/scope.', false);
  }

  switchTab(identifyTab ? 'identify' : 'advisory');
}

function closeWizard() {
  wizardOpen = false;
  document.getElementById('wizardOverlay').classList.add('hidden');
  document.getElementById('wizardOverlay').setAttribute('aria-hidden', 'true');
  wizardTarget = null;
  wizardPayload = null;
}

function switchTab(name) {
  document.querySelectorAll('.modal-tabs .tab').forEach(t => {
    t.classList.toggle('active', t.dataset.tab === name);
  });
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.getElementById(name === 'identify' ? 'tabIdentify' : 'tabAdvisory').classList.add('active');
}

async function postAction(action, extra = {}) {
  const sessionToken = await ensureHitlSession();
  if (!sessionToken) return null;
  setWizardStatus('Elaborazione…');
  const body = {
    processId: wizardTarget.pid,
    processName: wizardTarget.name,
    action,
    sessionToken,
    ...extra
  };
  const res = await fetch('/api/process/action', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg = data.message || data.result?.Message || data.error || 'Azione fallita';
    if (data.error === 'auth_failed' || data.error === 'session_required' || /session expired|unlock from hitl/i.test(msg)) {
      clearHitlSession();
      setWizardStatus('Sessione scaduta — sblocca di nuovo.', true);
    } else {
      setWizardStatus(msg, true);
    }
    return null;
  }
  if (data.Outcome === 'ActionBlocked') {
    setWizardStatus(data.Message || 'Azione bloccata dal catalogo.', true);
    return data;
  }
  setWizardStatus(data.Message || 'OK');
  await load(true);
  return data;
}

document.getElementById('btnUnlockSession')?.addEventListener('click', async () => {
  const tok = await ensureHitlSession();
  if (tok) setWizardStatus('');
});

document.getElementById('btnEndSession')?.addEventListener('click', () => {
  clearHitlSession();
  setWizardStatus('Sessione terminata.');
});

document.getElementById('btnRefresh').addEventListener('click', () => load(true));
document.getElementById('btnWizardClose').addEventListener('click', closeWizard);

document.querySelectorAll('.modal-tabs .tab').forEach(tab => {
  tab.addEventListener('click', () => switchTab(tab.dataset.tab));
});

document.getElementById('ramBody').addEventListener('click', e => {
  const btn = e.target.closest('button[data-action]');
  if (!btn) return;
  openWizard({ pid: parseInt(btn.dataset.pid, 10), name: btn.dataset.name }, btn.dataset.action === 'identify');
});

document.getElementById('btnObserve').addEventListener('click', async () => {
  await postAction('Observe');
});

document.getElementById('btnThrottle').addEventListener('click', async () => {
  if (!confirm('Impostare priorità BelowNormal? (reversibile)')) return;
  await postAction('ThrottleBelowNormal');
});

document.getElementById('btnKeep').addEventListener('click', async () => {
  const phrase = prompt('Digita esattamente: KEEP FOR WORK');
  if (phrase !== 'KEEP FOR WORK') return;
  await postAction('MarkWorkNecessary', { confirmPhrase: phrase });
});

document.getElementById('btnStop').addEventListener('click', async () => {
  if (!confirm('ATTENZIONE: chiudere il processo può causare perdita dati. Continuare?')) return;
  const phrase = prompt('Digita esattamente: STOP UNKNOWN');
  if (phrase !== 'STOP UNKNOWN') return;
  await postAction('Terminate', { confirmPhrase: phrase });
});

document.getElementById('btnSaveIdentify').addEventListener('click', async () => {
  const whatItIs = document.getElementById('idWhatIs').value.trim();
  const whatItDoes = document.getElementById('idWhatDoes').value.trim();
  if (!whatItIs || !whatItDoes) {
    setWizardStatus('Compila Cos\'è e Cosa fa.', true);
    return;
  }
  const sessionToken = await ensureHitlSession();
  if (!sessionToken) return;
  setWizardStatus('Salvataggio identificazione…');
  const res = await fetch('/api/process/identify', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      processId: wizardTarget.pid,
      processName: wizardTarget.name,
      whatItIs,
      whatItDoes,
      category: document.getElementById('idCategory').value,
      priority: document.getElementById('idPriority').value,
      businessHint: document.getElementById('idBusiness').value.trim(),
      note: document.getElementById('idNote').value.trim(),
      sessionToken
    })
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = data.message || data.result?.Message || data.error || 'Identificazione fallita';
    if (data.error === 'auth_failed' || data.error === 'session_required' || /session expired|unlock from hitl/i.test(detail)) {
      clearHitlSession();
      setWizardStatus('Sessione scaduta — sblocca di nuovo.', true);
    } else {
      setWizardStatus(detail, true);
    }
    return;
  }
  setWizardStatus(data.Message || 'Identificazione salvata. Trust T1 aggiornato nel catalogo.');
  await load(true);
});

function switchNetworkTab(name) {
  document.querySelectorAll('.net-tab').forEach(t => t.classList.toggle('active', t.dataset.nettab === name));
  document.getElementById('networkConnectionsPanel')?.classList.toggle('hidden', name !== 'connections');
  document.getElementById('networkListenersPanel')?.classList.toggle('hidden', name !== 'listeners');
  document.getElementById('networkFindingsPanel')?.classList.toggle('hidden', name !== 'findings');
}

function renderDeepScanFindings() {
  const list = document.getElementById('networkFindingsList');
  const status = document.getElementById('networkDeepStatus');
  if (!list) return;
  list.innerHTML = '';
  if (!lastDeepScan) {
    if (status && !status.textContent) status.textContent = '';
    return;
  }
  const s = lastDeepScan.Summary || {};
  if (status) {
    status.textContent = `Deep scan: ${s.FindingCount || 0} findings (${s.CriticalCount || 0} critical) — ${lastDeepScan.GeneratedAt || ''}`;
  }
  (lastDeepScan.Findings || []).forEach(f => {
    const li = document.createElement('li');
    li.innerHTML = `<strong>[${f.Severity}] ${f.Layer}</strong> — ${f.Detail}`;
    if (f.Layer === 'GhostPid' || f.Severity === 'Critical' || f.Severity === 'High') {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn-mini';
      btn.textContent = 'Investiga';
      btn.addEventListener('click', () => switchNetworkTab('connections'));
      li.appendChild(document.createTextNode(' '));
      li.appendChild(btn);
    }
    list.appendChild(li);
  });
}

async function runNetworkDeepScan() {
  const status = document.getElementById('networkDeepStatus');
  if (status) status.textContent = 'Deep scan in corso (multi-layer)…';
  try {
    const res = await fetch('/api/network/deep-scan', { method: 'POST' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.message || data.error || 'Deep scan failed');
    lastDeepScan = data;
    renderDeepScanFindings();
    switchNetworkTab('findings');
  } catch (e) {
    if (status) status.textContent = String(e.message || e);
  }
}

document.getElementById('btnNetworkDeepScan')?.addEventListener('click', runNetworkDeepScan);
document.querySelectorAll('.net-tab').forEach(tab => {
  tab.addEventListener('click', () => switchNetworkTab(tab.dataset.nettab));
});
document.getElementById('cardNetwork')?.addEventListener('click', async e => {
  const btn = e.target.closest('button');
  if (!btn) return;
  if (btn.dataset.action === 'resolve') {
    openWizard({ pid: parseInt(btn.dataset.pid, 10), name: btn.dataset.name }, false);
    return;
  }
  const netAction = btn.dataset.netAction;
  if (!netAction) return;
  if (netAction === 'kill') {
    if (!confirm('Reset connessione TCP? Richiede admin.')) return;
    await postNetworkAction('KillConnection', {
      processId: parseInt(btn.dataset.pid, 10),
      processName: btn.dataset.name,
      localAddress: btn.dataset.local,
      localPort: parseInt(btn.dataset.localPort, 10),
      remoteAddress: btn.dataset.remote,
      remotePort: parseInt(btn.dataset.remotePort, 10)
    });
  } else if (netAction === 'block') {
    const ip = btn.dataset.remote;
    if (!ip || ip.startsWith('127.') || ip.startsWith('10.') || ip.startsWith('192.168.')) {
      alert('Block IP rifiutato su indirizzi privati/loopback.');
      return;
    }
    const phrase = prompt('Digita esattamente: BLOCK-REMOTE-IP');
    if (phrase !== 'BLOCK-REMOTE-IP') return;
    await postNetworkAction('BlockRemoteIp', { remoteAddress: ip, confirmPhrase: phrase });
  } else if (netAction === 'terminate') {
    if (!confirm('Terminare il processo? Perdita dati possibile.')) return;
    const phrase = prompt('Digita esattamente: TERMINATE-NETWORK-PROCESS');
    if (phrase !== 'TERMINATE-NETWORK-PROCESS') return;
    await postNetworkAction('TerminateProcess', {
      processId: parseInt(btn.dataset.pid, 10),
      processName: btn.dataset.name,
      confirmPhrase: phrase
    });
  }
});

loadDeepScanLatest();
load(false);
updateHitlSessionUi();
refreshTimer = setInterval(() => load(false), 30000);

