/* Chaos console — page logic that needs no browser to be tested.
 * Loaded as a classic <script> (exposes window.ChaosUI) and by `node --test` (module.exports).
 * Everything that shows event data goes through textContent: events come from chaos.sh,
 * but the page must stay inert whatever they contain. Spec: docs/specs/chaos-webui.md. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ChaosUI = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const ACTIVE_GAP_MS = 1000;     // at most one request per second per source during a run
  const IDLE_GAP_MS = 10000;      // data refresh when nothing is running
  const FINISHED = ['PASS', 'FAIL', 'ABORTED'];

  function formatTimer(seconds) {
    const s = Math.max(0, Math.floor(Number(seconds) || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    const two = (n) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${two(m)}:${two(sec)}` : `${two(m)}:${two(sec)}`;
  }

  // ms to wait AFTER a request that took lastDurationMs, so starts are spaced by the policy.
  function nextDelay({ active, lastDurationMs }) {
    const gap = active ? ACTIVE_GAP_MS : IDLE_GAP_MS;
    return Math.max(0, gap - (Number(lastDurationMs) || 0));
  }

  function ageText(seconds) {
    if (seconds === null || seconds === undefined) return 'never updated';
    const s = Math.floor(seconds);
    if (s < 1) return 'updated just now';
    if (s < 60) return `updated ${s} s ago`;
    return `updated ${Math.floor(s / 60)} min ${s % 60} s ago`;
  }

  function secondsText(v) {
    if (v === null || v === undefined || !Number(v)) return '';
    const n = Number(v);
    return `${Number.isInteger(n) ? n : n.toFixed(1)} s`;
  }

  const STEP_LABEL = { inject: 'Action played', action: 'Action' };

  function bannerModel(state, sinceFetchSec) {
    const since = Number(sinceFetchSec) || 0;
    const run = state && state.run;
    if (!run) {
      return { mode: 'idle', headline: 'No chaos run in progress', subline: '', scenario: null,
               currentAction: null, timer: { text: '00:00', running: false }, recoveredText: '', steps: [] };
    }
    const now = state.server_time;
    const finished = FINISHED.includes(run.status);
    const stale = run.status === 'STALE';
    const injected = run.injected_at !== null && run.injected_at !== undefined;

    let elapsed = 0, running = false;
    if (injected) {
      if (run.recovered_seconds !== null && run.recovered_seconds !== undefined) elapsed = run.recovered_seconds;
      else if (finished) elapsed = (run.finished_at || now) - run.injected_at;
      else if (stale) elapsed = now - run.injected_at;
      else { elapsed = now - run.injected_at + since; running = true; }
    }

    let mode, headline, subline = '';
    const title = run.scenario ? run.scenario.title : (run.phase || 'Chaos run');
    if (stale) { mode = 'stale'; headline = 'No update for a while — the run may have been interrupted'; }
    else if (finished) {
      mode = 'done';
      headline = `Run finished — ${run.status}`;
      subline = run.failed > 0 ? `${run.failed} check(s) failed` : (run.status === 'PASS' ? 'all checks passed' : '');
    } else if (run.awaiting_operator) {
      mode = 'ready'; headline = 'Ready — waiting for the presenter'; subline = `Next scenario: ${title}`;
    } else if (run.recovered_seconds !== null && run.recovered_seconds !== undefined) {
      mode = 'verifying'; headline = `${title} — recovered, final checks running…`;
    } else { mode = 'running'; headline = `${title} — in progress`; }

    const infos = (run.steps || []).filter((s) => s.status === 'INFO' && (s.name === 'inject' || s.name === 'action'));
    return {
      mode, headline, subline, result: run.status,
      scenario: run.scenario ? {
        title: run.scenario.title, simulate: run.scenario.simulate,
        actions: run.scenario.actions || [], expect: run.scenario.expect,
      } : null,
      currentAction: infos.length ? infos[infos.length - 1].note : null,
      timer: { text: formatTimer(elapsed), running },
      recoveredText: run.recovered_seconds !== null && run.recovered_seconds !== undefined
        ? `Recovered in ${secondsText(run.recovered_seconds) || '0 s'}` : '',
      steps: (run.steps || []).map((s) => ({
        status: s.status, label: STEP_LABEL[s.name] || s.name, secondsText: secondsText(s.seconds), note: s.note || '',
      })),
    };
  }

  function redisBadge(res, lastOkAgeSec) {
    if (!res) {
      const age = lastOkAgeSec === null || lastOkAgeSec === undefined ? '' : ` — last OK ${Math.floor(lastOkAgeSec)} s ago`;
      return { kind: 'unreachable', text: `unreachable${age}` };
    }
    if (String(res.message || '').includes('Error')) return { kind: 'error', text: 'Not available' };
    return { kind: 'ok', text: 'Connected' };
  }

  function clusterModel(data) {
    if (!data) return { error: 'unreachable', nodes: [] };
    if (data.message) return { error: data.message, nodes: [] };
    const nodes = Object.keys(data).sort((a, b) => (data[a].uid - data[b].uid) || a.localeCompare(b)).map((name) => {
      const n = data[name];
      const isPrimary = n.role === 'primary';
      return {
        name, status: n.status, kind: n.status === 'active' ? 'ok' : 'error',
        isPrimary, hostname: n.hostname || '',
        roleText: isPrimary ? 'PRIMARY' : (n.role === 'replica' ? 'replica' : ''),
        shards: (n.shards || []).map((s) => ({
          text: `db-${s.bdb_uid} ${s.role} ${s.detailed_status}`, kind: s.status === 'active' ? 'ok' : 'error',
        })),
      };
    });
    const primary = nodes.find((n) => n.isPrimary);
    const primaryText = primary ? `Cluster primary: ${primary.name}${primary.hostname ? ` (${primary.hostname})` : ''}` : '';
    return { error: null, nodes, primaryText };
  }

  // The Active-Active database as one cluster sees it: its status and each sync link.
  function aadbModel(data) {
    if (!data) return { error: 'unreachable' };
    if (data.message) return { error: data.message };
    const st = String(data.status || 'unknown');
    return {
      error: null, name: data.name, statusText: st.toUpperCase(),
      kind: st === 'active' ? 'ok' : (st.startsWith('active-') || st.endsWith('-pending') ? 'warn' : 'error'),
      links: (data.links || []).map((l) => ({
        text: `from ${l.source}: ${l.status}${l.lag !== null && l.lag !== undefined ? `, lag ${l.lag}` : ''}${l.error ? ` (${l.error})` : ''}`,
        kind: l.status === 'in-sync' ? 'ok' : 'error',
      })),
    };
  }

  function aadbView(data, lastGood) {
    const m = aadbModel(data);
    if (!m.error) return Object.assign({}, m, { stale: false, banner: '' });
    if (!lastGood || lastGood.error) return Object.assign({}, m, { stale: false, banner: '' });
    return Object.assign({}, lastGood, { kind: 'stale', stale: true, banner: `${m.error} — showing the last known state` });
  }

  // What the page shows for a cluster. When the REST API blips (pod churn behind the ingress) the
  // nodes seen last are kept, dimmed, with a warning, instead of the whole list disappearing.
  function clusterView(data, lastGood) {
    const m = clusterModel(data);
    if (!m.error) return Object.assign({}, m, { stale: false, banner: '' });
    if (!lastGood || !lastGood.nodes || !lastGood.nodes.length) return Object.assign({}, m, { stale: false, banner: '' });
    return {
      error: null, stale: true, banner: `${m.error} — showing the last known state`,
      primaryText: lastGood.primaryText,
      nodes: lastGood.nodes.map((n) => Object.assign({}, n, { kind: 'stale' })),
    };
  }

  // ---- DOM (document injected so tests can pass a fake; textContent only) -------------------
  function el(doc, tag, cls, text) {
    const e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function renderBanner(doc, rootEl, m) {
    const box = el(doc, 'div', `chaos-banner chaos-${m.mode}${m.result ? ' result-' + String(m.result).toLowerCase() : ''}`);
    // header row: headline on the left, timer (and "Recovered in …") top right
    const head = el(doc, 'div', 'chaos-head');
    const text = el(doc, 'div', 'chaos-head-text');
    text.appendChild(el(doc, 'h2', 'chaos-headline', m.headline));
    if (m.subline) text.appendChild(el(doc, 'p', 'chaos-subline', m.subline));
    head.appendChild(text);
    const clock = el(doc, 'div', 'chaos-clock');
    if (m.mode !== 'idle') {
      clock.appendChild(el(doc, 'div', `chaos-timer${m.timer.running ? ' running' : ''}`, m.timer.text));
      if (m.recoveredText) clock.appendChild(el(doc, 'div', 'chaos-recovered', m.recoveredText));
    }
    head.appendChild(clock);
    box.appendChild(head);
    if (m.scenario) {
      const sc = el(doc, 'div', 'chaos-scenario');
      if (m.mode === 'done' || m.mode === 'stale') sc.appendChild(el(doc, 'h3', null, m.scenario.title));
      sc.appendChild(el(doc, 'h4', null, 'What we simulate'));
      sc.appendChild(el(doc, 'p', null, m.scenario.simulate));
      sc.appendChild(el(doc, 'h4', null, 'Actions played'));
      const ul = el(doc, 'ol', 'chaos-actions');
      m.scenario.actions.forEach((a) => ul.appendChild(el(doc, 'li', a === m.currentAction ? 'current' : null, a)));
      sc.appendChild(ul);
      if (m.currentAction && m.mode === 'running' && !m.recoveredText) sc.appendChild(el(doc, 'p', 'chaos-current', `Now: ${m.currentAction}`));
      sc.appendChild(el(doc, 'h4', null, 'What to expect'));
      sc.appendChild(el(doc, 'p', null, m.scenario.expect));
      box.appendChild(sc);
    }
    if (m.steps.length) {
      const list = el(doc, 'ul', 'chaos-steps');
      m.steps.forEach((s) => {
        const li = el(doc, 'li', `step ${String(s.status).toLowerCase()}`);
        li.appendChild(el(doc, 'span', 'badge-status', s.status));
        li.appendChild(el(doc, 'span', 'step-label', s.label));
        if (s.secondsText) li.appendChild(el(doc, 'span', 'step-seconds', s.secondsText));
        if (s.note) li.appendChild(el(doc, 'span', 'step-note', s.note));
        list.appendChild(li);
      });
      box.appendChild(list);
    }
    rootEl.replaceChildren(box);
  }

  // ---- polling --------------------------------------------------------------------------------
  function withTimeout(makePromise, ms) {
    const ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    let timer;
    const cut = new Promise((_, reject) => {
      timer = setTimeout(() => { if (ctl) ctl.abort(); reject(new Error('timeout')); }, ms);
    });
    return Promise.race([makePromise(ctl && ctl.signal), cut]).finally(() => clearTimeout(timer));
  }

  // One source = one loop: the next request starts only after the previous one finished
  // (or timed out), and never sooner than the policy allows.
  async function runSource(deps) {
    const { fetchFn, onResult, onError, isActive, sleep, now, shouldStop, timeoutMs } = deps;
    while (!shouldStop()) {
      const t0 = now();
      try {
        onResult(await withTimeout(fetchFn, timeoutMs));
      } catch (e) {
        onError(e);
      }
      await sleep(nextDelay({ active: isActive(), lastDurationMs: now() - t0 }));
    }
  }

  return { formatTimer, nextDelay, ageText, bannerModel, redisBadge, clusterModel, clusterView, aadbModel, aadbView, renderBanner, runSource, withTimeout };
}));
