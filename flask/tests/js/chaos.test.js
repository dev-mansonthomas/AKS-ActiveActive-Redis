// Pure logic of the chaos console page (flask/static/chaos.js). Run: node --test flask/tests/js/
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../../static/chaos.js');

test('formatTimer', () => {
  assert.equal(C.formatTimer(0), '00:00');
  assert.equal(C.formatTimer(9.7), '00:09');
  assert.equal(C.formatTimer(61), '01:01');
  assert.equal(C.formatTimer(3599), '59:59');
  assert.equal(C.formatTimer(3661), '1:01:01');
  assert.equal(C.formatTimer(-5), '00:00');
  assert.equal(C.formatTimer(null), '00:00');
});

test('nextDelay: at most one request per second while a run is active', () => {
  assert.equal(C.nextDelay({ active: true, lastDurationMs: 300 }), 700);
  assert.equal(C.nextDelay({ active: true, lastDurationMs: 1500 }), 0);
  assert.equal(C.nextDelay({ active: true, lastDurationMs: 0 }), 1000);
});

test('nextDelay: every 10 s when no run is active', () => {
  assert.equal(C.nextDelay({ active: false, lastDurationMs: 300 }), 9700);
  assert.equal(C.nextDelay({ active: false, lastDurationMs: 12000 }), 0);
});

test('ageText', () => {
  assert.equal(C.ageText(0.4), 'updated just now');
  assert.equal(C.ageText(3.2), 'updated 3 s ago');
  assert.equal(C.ageText(75), 'updated 1 min 15 s ago');
  assert.equal(C.ageText(null), 'never updated');
});

const base = (over = {}) => ({
  server_time: 1000, active: true,
  run: Object.assign({
    run_id: 'r1', target: 'rec-a', witness: 'rec-b', status: 'RUNNING', phase: 'node',
    awaiting_operator: false, injected_at: 940, recovered_seconds: null, finished_at: null, failed: 0,
    steps: [], scenario: { title: 'Node failure', simulate: 'sim', actions: ['a1', 'a2'], expect: 'exp', typical: null },
  }, over),
});

test('bannerModel: no run yet', () => {
  const m = C.bannerModel({ server_time: 1, active: false, run: null }, 0);
  assert.equal(m.mode, 'idle');
  assert.equal(m.headline, 'No chaos run in progress');
  assert.equal(m.scenario, null);
});

test('bannerModel: ready, waiting for the presenter (timer not started)', () => {
  const m = C.bannerModel(base({ awaiting_operator: true, injected_at: null }), 0);
  assert.equal(m.mode, 'ready');
  assert.match(m.headline, /Ready — waiting for the presenter/);
  assert.equal(m.timer.text, '00:00');
  assert.equal(m.timer.running, false);
  assert.equal(m.scenario.title, 'Node failure');
  assert.deepEqual(m.scenario.actions, ['a1', 'a2']);
});

test('bannerModel: running timer counts from injection and follows the local clock', () => {
  const m = C.bannerModel(base(), 5);   // 1000-940 = 60 s on the server + 5 s since the fetch
  assert.equal(m.mode, 'running');
  assert.equal(m.timer.text, '01:05');
  assert.equal(m.timer.running, true);
});

test('bannerModel: recovery freezes the timer and says how long it took', () => {
  const m = C.bannerModel(base({ recovered_seconds: 42 }), 30);
  assert.equal(m.timer.running, false);
  assert.equal(m.timer.text, '00:42');
  assert.equal(m.recoveredText, 'Recovered in 42 s');
});

test('bannerModel: recovered but the final checks are still running (green, not "in progress")', () => {
  const m = C.bannerModel(base({ recovered_seconds: 59 }), 10);
  assert.equal(m.mode, 'verifying');
  assert.match(m.headline, /Pod|Node failure/);
  assert.match(m.headline, /recovered/i);
  assert.match(m.headline, /final checks running/i);
  assert.doesNotMatch(m.headline, /in progress/);
  assert.equal(m.timer.running, false);
  assert.equal(m.timer.text, '00:59');
  assert.equal(m.recoveredText, 'Recovered in 59 s');
  // once the run is over the headline is the final verdict
  assert.equal(C.bannerModel(base({ recovered_seconds: 59, status: 'PASS', finished_at: 990 }), 0).mode, 'done');
  // the next scenario starts clean
  assert.equal(C.bannerModel(base({ recovered_seconds: null }), 0).mode, 'running');
});

test('renderBanner: the verifying state has its own class (green)', () => {
  const doc = fakeDoc();
  const root = doc.createElement('div');
  C.renderBanner(doc, root, C.bannerModel(base({ recovered_seconds: 59 }), 0));
  assert.match(root.children[0].className, /chaos-verifying/);
});

test('bannerModel: finished runs', () => {
  const pass = C.bannerModel(base({ status: 'PASS', finished_at: 990 }), 0);
  assert.equal(pass.mode, 'done');
  assert.match(pass.headline, /PASS/);
  const fail = C.bannerModel(base({ status: 'FAIL', failed: 2, finished_at: 990 }), 0);
  assert.match(fail.headline, /FAIL/);
  assert.match(fail.subline, /2 check\(s\) failed/);
  const ab = C.bannerModel(base({ status: 'ABORTED', finished_at: 990 }), 0);
  assert.match(ab.headline, /ABORTED/);
  assert.equal(pass.timer.running, false);
});

test('bannerModel: stale run', () => {
  const m = C.bannerModel(base({ status: 'STALE' }), 0);
  assert.equal(m.mode, 'stale');
  assert.match(m.headline, /may have been interrupted/);
});

test('bannerModel: current action is the last INFO step or the inject note', () => {
  const steps = [
    { name: 'inject', status: 'INFO', note: 'reset vm', seconds: null },
    { name: 'action', status: 'INFO', note: 'Cluster recovery', seconds: null },
  ];
  assert.equal(C.bannerModel(base({ steps }), 0).currentAction, 'Cluster recovery');
});

test('bannerModel: timeline rows', () => {
  const steps = [
    { name: 'inject', status: 'INFO', note: 'reset vm', seconds: null },
    { name: 'node-recovery', status: 'PASS', note: 'node back', seconds: 61 },
    { name: 'node-data', status: 'FAIL', note: '', seconds: 0 },
  ];
  const m = C.bannerModel(base({ steps }), 0);
  assert.deepEqual(m.steps.map(s => s.status), ['INFO', 'PASS', 'FAIL']);
  assert.equal(m.steps[1].label, 'node-recovery');
  assert.equal(m.steps[1].secondsText, '61 s');
  assert.equal(m.steps[0].label, 'Action played');
  assert.equal(m.steps[0].note, 'reset vm');
  assert.equal(m.steps[2].secondsText, '');
});

test('redisBadge', () => {
  assert.deepEqual(C.redisBadge({ message: 'Connected to Redis successfully' }, null), { kind: 'ok', text: 'Connected' });
  assert.equal(C.redisBadge({ message: 'Error: Redis is not available' }, null).kind, 'error');
  const u = C.redisBadge(null, 12);
  assert.equal(u.kind, 'unreachable');
  assert.match(u.text, /unreachable/);
  assert.match(u.text, /last OK 12 s ago/);
  assert.equal(C.redisBadge(null, null).text, 'unreachable');
});

test('clusterModel: shows which node is the cluster primary', () => {
  const data = {
    node_1: { status: 'active', uid: 1, role: 'replica', hostname: 'rec-a-0', shards: [] },
    node_2: { status: 'active', uid: 2, role: 'primary', hostname: 'rec-a-1', shards: [] },
    node_3: { status: 'active', uid: 3, role: null, hostname: null, shards: [] },
  };
  const m = C.clusterModel(data);
  assert.deepEqual(m.nodes.map(n => n.isPrimary), [false, true, false]);
  assert.equal(m.nodes[1].hostname, 'rec-a-1');
  assert.equal(m.nodes[0].roleText, 'replica');
  assert.equal(m.nodes[1].roleText, 'PRIMARY');
  assert.equal(m.nodes[2].roleText, '');
  assert.equal(m.primaryText, 'Cluster primary: node_2 (rec-a-1)');
  assert.equal(C.clusterModel({ node_1: { status: 'active', uid: 1, shards: [] } }).primaryText, '');
});

test('clusterView: keeps the last known nodes (dimmed) when the API blips', () => {
  const good = C.clusterModel({
    node_1: { status: 'active', uid: 1, role: 'replica', hostname: 'rec-a-0', shards: [] },
    node_2: { status: 'active', uid: 2, role: 'primary', hostname: 'rec-a-1', shards: [] },
  });
  const fresh = C.clusterView({ node_1: { status: 'active', uid: 1, shards: [] } }, good);
  assert.equal(fresh.stale, false);
  assert.equal(fresh.nodes.length, 1);

  const blip = C.clusterView({ message: 'Error: Cannot connect to Redis Enterprise cluster' }, good);
  assert.equal(blip.stale, true);
  assert.deepEqual(blip.nodes.map((n) => n.name), ['node_1', 'node_2']);
  assert.ok(blip.nodes.every((n) => n.kind === 'stale'));
  assert.equal(blip.primaryText, good.primaryText);
  assert.match(blip.banner, /last known state/);

  const timeout = C.clusterView(null, good);
  assert.equal(timeout.stale, true);

  const nothing = C.clusterView(null, null);
  assert.equal(nothing.stale, false);
  assert.equal(nothing.error, 'unreachable');
  assert.equal(nothing.nodes.length, 0);
});

test('clusterModel', () => {
  const data = {
    node_2: { status: 'down', uid: 2, shards: [] },
    node_1: { status: 'active', uid: 1, shards: [{ status: 'active', role: 'primary', bdb_uid: 1, detailed_status: 'ok' }] },
  };
  const m = C.clusterModel(data);
  assert.deepEqual(m.nodes.map(n => n.name), ['node_1', 'node_2']);
  assert.equal(m.nodes[0].kind, 'ok');
  assert.equal(m.nodes[1].kind, 'error');
  assert.equal(m.nodes[0].shards[0].text, 'db-1 primary ok');
  assert.equal(C.clusterModel({ message: 'Error: Cannot connect' }).error, 'Error: Cannot connect');
  assert.equal(C.clusterModel(null).error, 'unreachable');
});

test('aadbModel / aadbView', () => {
  const ok = { name: 'aadb', status: 'active', links: [{ source: 'rec-b', status: 'in-sync', lag: 0, error: '' }] };
  const m = C.aadbModel(ok);
  assert.equal(m.name, 'aadb');
  assert.equal(m.statusText, 'ACTIVE');
  assert.equal(m.kind, 'ok');
  assert.deepEqual(m.links, [{ text: 'from rec-b: in-sync, lag 0', kind: 'ok' }]);

  const bad = C.aadbModel({ name: 'aadb', status: 'active', links: [{ source: 'rec-b', status: 'disconnected', lag: 12, error: 'timeout' }] });
  assert.equal(bad.links[0].kind, 'error');
  assert.match(bad.links[0].text, /disconnected/);
  assert.match(bad.links[0].text, /timeout/);
  assert.equal(C.aadbModel({ name: 'aadb', status: 'active-change-pending', links: [] }).kind, 'warn');
  assert.equal(C.aadbModel({ name: 'aadb', status: 'down', links: [] }).kind, 'error');
  assert.equal(C.aadbModel(null).error, 'unreachable');
  assert.equal(C.aadbModel({ message: 'Error: x' }).error, 'Error: x');

  const stale = C.aadbView({ message: 'Error: x' }, m);
  assert.equal(stale.stale, true);
  assert.equal(stale.name, 'aadb');
  assert.equal(stale.kind, 'stale');
  assert.match(stale.banner, /last known state/);
  assert.equal(C.aadbView(ok, m).stale, false);
  assert.equal(C.aadbView(null, null).error, 'unreachable');
});

// --- DOM rendering never goes through innerHTML
function fakeDoc() {
  const mk = (tag) => {
    const el = { tag, children: [], className: '', _text: '' };
    Object.defineProperty(el, 'innerHTML', { set() { throw new Error('innerHTML must not be used'); }, get() { return ''; } });
    Object.defineProperty(el, 'textContent', { set(v) { el._text = String(v); el.children = []; }, get() { return el._text; } });
    el.appendChild = (c) => { el.children.push(c); return c; };
    el.replaceChildren = (...cs) => { el.children = cs; };
    el.setAttribute = () => {};
    return el;
  };
  return { createElement: mk };
}
function flatten(el) { return [el._text, ...el.children.flatMap(flatten)]; }

test('renderBanner uses text nodes only (markup in events stays inert)', () => {
  const doc = fakeDoc();
  const root = doc.createElement('div');
  const evil = '<img src=x onerror=alert(1)>';
  const m = C.bannerModel(base({ steps: [{ name: 'node-data', status: 'FAIL', note: evil, seconds: 1 }] }), 0);
  C.renderBanner(doc, root, m);
  assert.ok(flatten(root).some(t => t.includes(evil)), 'the note is shown as text');
});

test('renderBanner: the timer sits in the header row, top right (saves vertical space)', () => {
  const doc = fakeDoc();
  const root = doc.createElement('div');
  C.renderBanner(doc, root, C.bannerModel(base({ recovered_seconds: 42 }), 0));
  const box = root.children[0];
  const head = box.children[0];
  assert.equal(head.className, 'chaos-head');
  assert.equal(head.children.length, 2);
  const [left, clock] = head.children;
  assert.equal(left.className, 'chaos-head-text');
  assert.equal(clock.className, 'chaos-clock');
  assert.ok(flatten(clock).includes('00:42'));
  assert.ok(flatten(clock).includes('Recovered in 42 s'));
  assert.ok(!box.children.slice(1).some((c) => /chaos-timer|chaos-recovered/.test(c.className)), 'no separate timer row');
});

test('renderBanner: the scenario title is not repeated when the headline already carries it', () => {
  const titles = (m) => { const d = fakeDoc(); const r = d.createElement('div'); C.renderBanner(d, r, m); return flatten(r).filter((t) => t === 'Node failure').length; };
  assert.equal(titles(C.bannerModel(base(), 0)), 0, 'running: the headline says it');
  assert.equal(titles(C.bannerModel(base({ awaiting_operator: true, injected_at: null }), 0)), 0, 'ready: the subline says it');
  assert.equal(titles(C.bannerModel(base({ status: 'PASS', finished_at: 990 }), 0)), 1, 'finished: the headline does not, so the title is shown');
});

// --- the loops never overlap and follow the delay policy
test('runSource: strictly sequential, spaced by nextDelay, stops on request', async () => {
  const log = [];
  let inFlight = 0, maxInFlight = 0, n = 0;
  const deps = {
    fetchFn: async () => { inFlight++; maxInFlight = Math.max(maxInFlight, inFlight); log.push('fetch'); await null; inFlight--; return { n: ++n }; },
    onResult: () => log.push('result'),
    onError: () => log.push('error'),
    isActive: () => true,
    sleep: async (ms) => { log.push(`sleep:${ms}`); },
    now: (() => { let t = 0; return () => (t += 100); })(),   // every call advances 100 ms: each fetch "lasts" 100 ms
    shouldStop: () => n >= 3,
    timeoutMs: 8000,
  };
  await C.runSource(deps);
  assert.equal(maxInFlight, 1);
  assert.deepEqual(log.filter(x => x.startsWith('sleep')), ['sleep:900', 'sleep:900', 'sleep:900']);
  assert.equal(log.filter(x => x === 'result').length, 3);
});

test('runSource: a hanging fetch is cut at the timeout and reported as an error', async () => {
  const log = [];
  let calls = 0;
  const deps = {
    fetchFn: () => new Promise(() => {}),    // never answers
    onResult: () => log.push('result'),
    onError: (e) => log.push('error:' + e.message),
    isActive: () => false,
    sleep: async (ms) => { log.push(`sleep:${ms}`); },
    now: (() => { let t = 0; return () => (t += 50); })(),
    shouldStop: () => ++calls > 1,
    timeoutMs: 20,
  };
  await C.runSource(deps);
  assert.ok(log.some(x => x.startsWith('error:timeout')), 'timeout reported');
  assert.ok(!log.includes('result'));
  assert.ok(log.some(x => x.startsWith('sleep:')));
});
