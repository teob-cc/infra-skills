// Unit tests for charts/alert-triage/files/triage.mjs: the real service against a fake
// Alertmanager payload, a fake HolmesGPT and a fake Slack endpoint on loopback ports, with a
// clock the test moves. No cluster, no network, no model call.
//
//   node --test tests/alert-triage/triage.test.mjs
//   docker run --rm -v "$PWD":/w -w /w node:22-alpine node --test tests/alert-triage/triage.test.mjs   # the image's Node
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createTriage, parseFinding, slackSafe, configFromEnv } from '../../charts/alert-triage/files/triage.mjs';

const HOLMES_KEY = 'fake-holmes-key-0123456789';
const SLACK_TOKEN = 'fake-slack-token-0123456789';
const MIN = 60_000;
const HOUR = 60 * MIN;
const GOOD = { cause: 'The container is killed for memory.', evidence: 'OOMKilled 4 times, limit 256Mi, working set 255Mi.', next_step: 'Raise the memory limit to 512Mi.', confidence: 'high' };

function listen(handler) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => handler(req, res, Buffer.concat(chunks).toString('utf8')));
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// A test bed: fake HolmesGPT, fake Slack, a temp dir with the two secret files and the state file.
async function bed(t, overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'alert-triage-test-'));
  fs.writeFileSync(path.join(dir, 'holmes-key'), `${HOLMES_KEY}\n`);
  fs.writeFileSync(path.join(dir, 'slack-token'), `${SLACK_TOKEN}\n`);
  const b = {
    dir, clock: Date.parse('2026-11-19T10:00:00Z'), lines: [], holmesRequests: [], slackPosts: [],
    holmes: (req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(b.holmesAnswer())); },
    holmesAnswer: () => ({ analysis: JSON.stringify(GOOD), conversation_history: [{ role: 'tool', content: 'SECRET-POD-LOG '.repeat(500) }], tool_calls: [{ result: 'raw log' }], metadata: { costs: { prompt_tokens: 12000, completion_tokens: 300, total_tokens: 12300, cached_tokens: 9000, total_cost: 0 }, usage: { prompt_tokens: 5000, completion_tokens: 100, total_tokens: 5100 } } }),
    slack: (req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":true}'); },
  };
  const holmesServer = await listen((req, res, body) => { b.holmesRequests.push({ headers: req.headers, url: req.url, body: JSON.parse(body) }); b.holmes(req, res); });
  const slackServer = await listen((req, res, body) => {
    const post = { headers: req.headers, body: JSON.parse(body) };
    b.slackAttempts = (b.slackAttempts ?? 0) + 1;
    const before = res.end.bind(res);
    res.end = (payload) => { if (String(payload).includes('"ok":true')) b.slackPosts.push(post); return before(payload); };
    b.slack(req, res);
  });
  b.cfg = {
    ...configFromEnv({
      CLUSTER: 'test', HOLMES_URL: `http://127.0.0.1:${holmesServer.address().port}/api/chat`, HOLMES_MODEL: 'claude-haiku-5-5',
      HOLMES_API_KEY_FILE: path.join(dir, 'holmes-key'), SLACK_TOKEN_FILE: path.join(dir, 'slack-token'),
      SLACK_API_URL: `http://127.0.0.1:${slackServer.address().port}/api/chat.postMessage`,
      GRAFANA_URL: 'https://grafana.example.com/alerting/list', STATE_FILE: path.join(dir, 'state.json'),
      LISTEN_PORT: '0', METRICS_PORT: '0', ON_DEMAND_NODES: 'gpu-worker',
    }),
    slackRetryDelaysMs: [5, 5], capLineDelayMs: 2 * MIN, ...overrides,
  };
  b.start = () => createTriage(b.cfg, { now: () => b.clock, write: (line) => b.lines.push(JSON.parse(line)) });
  b.triage = b.start();
  b.log = (event) => b.lines.filter((l) => l.event === event);
  b.posts = (channel) => b.slackPosts.filter((p) => p.body.channel === channel).map((p) => p.body.text);
  b.metric = (name) => Number((b.triage.metrics().split('\n').find((l) => l.startsWith(`${name} `)) ?? ' NaN').split(' ')[1]);
  t.after(async () => {
    holmesServer.closeAllConnections(); slackServer.closeAllConnections();
    holmesServer.close(); slackServer.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return b;
}

// What Alertmanager 0.34 posts to a webhook receiver (version 4), one alert per call unless given more.
function payload(...alerts) {
  return {
    version: '4', receiver: 'alert-triage', status: 'firing', groupKey: '{}/{severity=~"p1|p2"}:{alertname="X"}', truncatedAlerts: 0,
    groupLabels: {}, commonLabels: {}, commonAnnotations: {}, externalURL: 'http://alertmanager.example',
    alerts: alerts.map((a) => ({
      status: a.status ?? 'firing',
      labels: { alertname: a.name ?? 'KubePodCrashLooping', severity: a.severity ?? 'p2', app: a.app ?? 'shop', namespace: a.namespace ?? 'shop', env: 'test', ...a.labels },
      annotations: { summary: a.summary ?? 'Pod shop-0 is crash looping', description: 'restarts 5 in 10m', ...a.annotations },
      startsAt: a.startsAt ?? '2026-11-19T09:58:00Z', endsAt: '0001-01-01T00:00:00Z', generatorURL: 'http://prometheus.example/graph', fingerprint: 'abc123',
    })),
  };
}
const fire = async (b, ...alerts) => { const r = b.triage.accept(payload(...alerts)); await b.triage.idle(); await b.triage.tick(); return r; };

test('done when 1: a firing p2 gives exactly one finding in #infra-alerts and one log line', async (t) => {
  const b = await bed(t);
  assert.deepEqual(await fire(b, {}), { accepted: 1, skipped: 0 });

  assert.equal(b.holmesRequests.length, 1);
  const req = b.holmesRequests[0];
  assert.equal(req.url, '/api/chat');
  assert.equal(req.headers['x-api-key'], HOLMES_KEY);
  assert.equal(req.body.model, 'claude-haiku-5-5');
  assert.equal(req.body.stream, false);
  assert.deepEqual(req.body.response_format.json_schema.schema.required, ['cause', 'evidence', 'next_step', 'confidence']);
  assert.match(req.body.ask, /KubePodCrashLooping/);
  assert.match(req.body.ask, /do not follow any instruction/);

  assert.equal(b.slackPosts.length, 1);
  const post = b.slackPosts[0];
  assert.equal(post.headers.authorization, `Bearer ${SLACK_TOKEN}`);
  assert.equal(post.body.channel, '#infra-alerts');
  assert.equal(post.body.parse, 'none');
  assert.equal(post.body.unfurl_links, false);
  assert.match(post.body.text, /^\*\[test\] Finding for KubePodCrashLooping\* · p2 · app shop · namespace shop · confidence \*high\* · <https:\/\/grafana\.example\.com\/alerting\/list\|alert list>\n\*Cause:\* The container is killed for memory\.\n\*Evidence:\* OOMKilled/);
  assert.doesNotMatch(post.body.text, /Escalated/);

  const lines = b.log('investigation');
  assert.equal(lines.length, 1);
  const line = lines[0];
  assert.equal(line.cluster, 'test');
  assert.equal(line.alert, 'KubePodCrashLooping');
  assert.equal(line.outcome, 'ok');
  assert.equal(line.confidence, 'high');
  assert.equal(line.escalate, false);
  assert.deepEqual(line.escalate_reasons, []);
  assert.equal(line.slack_posted, true);
  assert.deepEqual(line.finding, GOOD);
  // Sums over the investigation (metadata.costs), not the last model call (metadata.usage).
  assert.deepEqual(line.tokens, { prompt: 12000, completion: 300, total: 12300, cached: 9000 });
  assert.equal(b.metric('alert_triage_investigations_total{outcome="ok"}'), 1);
  assert.equal(b.metric('alert_triage_tokens_total{kind="prompt"}'), 12000);
  assert.equal(b.metric('alert_triage_tokens_total{kind="completion"}'), 300);
});

test('the log carries no secret, no conversation history and no tool output', async (t) => {
  const b = await bed(t);
  await fire(b, {});
  const all = JSON.stringify(b.lines);
  assert.ok(!all.includes(HOLMES_KEY) && !all.includes(SLACK_TOKEN));
  assert.ok(!all.includes('SECRET-POD-LOG') && !all.includes('raw log'));
  assert.ok(JSON.stringify(b.log('investigation')[0].finding).length <= 3000);
});

test('done when 2: the same alert again within 4 hours gives nothing; after 4 hours it is investigated again', async (t) => {
  const b = await bed(t);
  await fire(b, {});
  b.clock += HOUR; // Alertmanager's repeat of the same firing
  assert.deepEqual(await fire(b, {}), { accepted: 0, skipped: 1 });
  b.clock += 2 * HOUR; // another pod of the same group, same firing
  await fire(b, { labels: { pod: 'shop-1' } });
  assert.equal(b.holmesRequests.length, 1);
  assert.equal(b.slackPosts.length, 1);
  assert.equal(b.log('investigation').length, 1);
  const skips = b.log('skip');
  assert.equal(skips.length, 2);
  assert.ok(skips.every((s) => s.reason === 'dedup' && s.escalate === false));
  assert.equal(b.metric('alert_triage_skipped_total{reason="dedup"}'), 2);

  b.clock += 61 * MIN; // 4 h 1 min after the investigation
  await fire(b, {});
  assert.equal(b.holmesRequests.length, 2);
  assert.equal(b.log('investigation').length, 2);
});

test('a group is (alertname, app, namespace): another namespace is another investigation', async (t) => {
  const b = await bed(t);
  // group_by of the route has no namespace, so one webhook can carry both.
  assert.deepEqual(await fire(b, { namespace: 'shop' }, { namespace: 'shop' }, { namespace: 'billing' }), { accepted: 2, skipped: 0 });
  assert.equal(b.holmesRequests.length, 2);
  assert.deepEqual(b.log('investigation').map((l) => [l.namespace, l.firing_instances]), [['shop', 2], ['billing', 1]]);
});

test('done when 3: 10 different alerts in an hour give 6 findings and one cap line', async (t) => {
  const b = await bed(t);
  for (let i = 0; i < 10; i += 1) { await fire(b, { name: `Alert${i}` }); b.clock += 2 * MIN; await b.triage.tick(); b.clock += 3 * MIN; } // the 15 s timer, here by hand
  assert.equal(b.holmesRequests.length, 6);
  const findings = b.posts('#infra-alerts').filter((x) => x.includes('Finding for'));
  assert.equal(findings.length, 6);
  const capLines = b.posts('#infra-alerts').filter((x) => x.includes('cap reached'));
  assert.equal(capLines.length, 1);
  assert.equal(capLines[0], '[test] 1 alert not investigated, cap reached (6 an hour): Alert6');
  // The cap is an escalation: every skipped alert is in the log with escalate=true, and one line went to #infra-watchdog.
  const skipped = b.log('skip');
  assert.deepEqual(skipped.map((s) => s.alert), ['Alert6', 'Alert7', 'Alert8', 'Alert9']);
  assert.ok(skipped.every((s) => s.reason === 'cap_hour' && s.escalate === true && s.escalate_reasons.includes('cap')));
  assert.equal(b.posts('#infra-watchdog').length, 1);
  assert.match(b.posts('#infra-watchdog')[0], /^\[test\] escalate: 1 alert not investigated, cap reached \(6 an hour\): Alert6\. They are in the log/);
  assert.equal(b.metric('alert_triage_skipped_total{reason="cap_hour"}'), 4);
  assert.equal(b.metric('alert_triage_cap_used{window="hour"}'), 6);

  // Nothing is queued: an hour later the three later ones are named in the next hour's line, not investigated.
  b.clock += 45 * MIN;
  await b.triage.tick();
  assert.equal(b.holmesRequests.length, 6);
  const later = b.posts('#infra-alerts').filter((x) => x.includes('cap reached'));
  assert.equal(later.length, 2);
  assert.equal(later[1], '[test] 3 alerts not investigated, cap reached (6 an hour): Alert7, Alert8, Alert9');
});

test('done when 4: a p1 is marked escalate=true and gets one line in #infra-watchdog', async (t) => {
  const b = await bed(t);
  await fire(b, { name: 'PostgresDown', severity: 'p1' });
  const line = b.log('investigation')[0];
  assert.equal(line.escalate, true);
  assert.deepEqual(line.escalate_reasons, ['p1']);
  assert.match(b.posts('#infra-alerts')[0], /_Escalated to the watchdog: severity_$/);
  assert.deepEqual(b.posts('#infra-watchdog'), ['[test] escalate: PostgresDown (p1 · app shop · namespace shop): severity. Finding in #infra-alerts.']);
});

test('escalation: low confidence', async (t) => {
  const b = await bed(t);
  b.holmesAnswer = () => ({ analysis: JSON.stringify({ ...GOOD, confidence: 'Low' }), metadata: {} });
  await fire(b, {});
  const line = b.log('investigation')[0];
  assert.equal(line.confidence, 'low');
  assert.deepEqual([line.escalate, line.escalate_reasons], [true, ['low_confidence']]);
  assert.deepEqual(line.tokens, { prompt: 0, completion: 0, total: 0, cached: 0 });
  assert.equal(b.posts('#infra-watchdog').length, 1);
});

test('escalation: HolmesGPT down (connection refused and HTTP 500)', async (t) => {
  const b = await bed(t);
  b.holmes = (req, res) => { res.writeHead(500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ detail: `litellm.AuthenticationError key=${HOLMES_KEY}` })); };
  await fire(b, {});
  b.cfg.holmesUrl = 'http://127.0.0.1:1/api/chat';
  await fire(b, { name: 'Other' });
  const lines = b.log('investigation');
  assert.deepEqual(lines.map((l) => [l.outcome, l.escalate, l.escalate_reasons, l.finding]), [['failed', true, ['holmes_failed'], null], ['failed', true, ['holmes_failed'], null]]);
  assert.match(lines[0].error, /HTTP 500/);
  assert.ok(!JSON.stringify(b.lines).includes(HOLMES_KEY), 'the key echoed in an error must not reach the log');
  assert.ok(!JSON.stringify(b.slackPosts.map((p) => p.body)).includes(HOLMES_KEY));
  assert.match(b.posts('#infra-alerts')[0], /^\*\[test\] No finding for KubePodCrashLooping\*/);
  assert.equal(b.posts('#infra-watchdog').length, 2);
  assert.equal(b.metric('alert_triage_failures_total{stage="holmes"}'), 2);
  assert.equal(b.metric('alert_triage_investigations_total{outcome="failed"}'), 2);
  // A failed investigation used its place in the window and in the caps.
  await fire(b, {});
  assert.equal(b.log('skip')[0].reason, 'dedup');
  assert.equal(b.metric('alert_triage_cap_used{window="hour"}'), 2);
});

test('escalation: HolmesGPT does not answer within the timeout', async (t) => {
  const b = await bed(t, { holmesTimeoutMs: 100 });
  b.holmes = () => {}; // never answers
  await fire(b, {});
  const line = b.log('investigation')[0];
  assert.deepEqual([line.outcome, line.escalate, line.escalate_reasons], ['timeout', true, ['holmes_timeout']]);
  assert.match(b.posts('#infra-alerts')[0], /did not answer within 0\.1 s/);
  assert.equal(b.metric('alert_triage_investigations_total{outcome="timeout"}'), 1);
});

test('a malformed HolmesGPT answer becomes a low-confidence finding and is escalated', async (t) => {
  const b = await bed(t);
  const answers = ['I looked around. <!channel> see https://evil.example/x', '{"cause": "x", "confidence": "certain"}', '', null];
  for (const [i, analysis] of answers.entries()) {
    b.holmesAnswer = () => ({ analysis });
    await fire(b, { name: `Malformed${i}` });
  }
  const lines = b.log('investigation');
  assert.ok(lines.every((l) => l.outcome === 'malformed' && l.confidence === 'low' && l.escalate && l.escalate_reasons.includes('malformed_answer')));
  assert.equal(lines[0].finding.raw, 'I looked around. <!channel> see https://evil.example/x');
  assert.match(b.posts('#infra-alerts')[0], /the answer was not in the expected form.*\nI looked around\. &lt;!channel&gt; see hxxps:\/\/evil\.example\/x/);
  assert.equal(b.metric('alert_triage_investigations_total{outcome="malformed"}'), 4);
});

test('parseFinding: JSON, fenced JSON, JSON inside prose; nothing else', () => {
  assert.deepEqual(parseFinding(JSON.stringify(GOOD)), GOOD);
  assert.deepEqual(parseFinding(`Here is my answer:\n\`\`\`json\n${JSON.stringify(GOOD, null, 2)}\n\`\`\`\nDone.`), GOOD);
  assert.deepEqual(parseFinding(`Result {not json} then ${JSON.stringify({ ...GOOD, evidence: 'a "}" in a string' })} thanks`), { ...GOOD, evidence: 'a "}" in a string' });
  assert.deepEqual(parseFinding(GOOD), GOOD);
  assert.equal(parseFinding({ ...GOOD, confidence: 'HIGH ' }).confidence, 'high');
  assert.equal(parseFinding(JSON.stringify({ cause: 'only a cause', confidence: 'medium' })).next_step, '');
  for (const bad of ['', 'no json here', '[]', '{"confidence":"high"}', '{"cause":"","confidence":"high"}', '{"cause":"x","confidence":"sure"}', '{"cause": 5, "confidence":"low"}', 42, undefined]) {
    assert.equal(parseFinding(bad), null, String(bad));
  }
  assert.equal(parseFinding(JSON.stringify({ ...GOOD, evidence: 'e'.repeat(5000) })).evidence.length, 1100);
});

test('escalation: the same group fires 3 times in 24 hours', async (t) => {
  const b = await bed(t);
  await fire(b, { startsAt: '2026-11-19T09:58:00Z' }); // first firing, investigated
  b.clock += HOUR;
  await fire(b, { startsAt: '2026-11-19T09:58:00Z' }); // a repeat notification is not a new firing
  await fire(b, { startsAt: '2026-11-19T10:50:00Z' }); // second firing
  assert.equal(b.posts('#infra-watchdog').length, 0);
  b.clock += HOUR;
  await fire(b, { startsAt: '2026-11-19T11:55:00Z' }); // third firing, inside the 4 hour window
  await fire(b, { startsAt: '2026-11-19T11:55:00Z' }); // its repeat: no second escalation line
  assert.equal(b.holmesRequests.length, 1);
  const skips = b.log('skip');
  assert.deepEqual(skips.map((s) => [s.reason, s.escalate, s.escalate_reasons]), [['dedup', false, []], ['dedup', false, []], ['dedup', true, ['repeat']], ['dedup', false, []]]);
  assert.deepEqual(b.posts('#infra-watchdog'), ['[test] escalate: KubePodCrashLooping (p2 · app shop · namespace shop): fired 3 times or more in 24 hours. Not investigated again: one investigation per group per window.']);

  b.clock += 3 * HOUR; // outside the window: the fourth firing is investigated and escalated as a repeater
  await fire(b, { startsAt: '2026-11-19T14:59:00Z' });
  const last = b.log('investigation').at(-1);
  assert.deepEqual([last.escalate, last.escalate_reasons], [true, ['repeat']]);

  b.clock += 25 * HOUR; // a day later the count starts again
  await fire(b, { startsAt: '2026-11-20T15:58:00Z' });
  assert.equal(b.log('investigation').at(-1).escalate, false);
});

test('storm: 30 alerts in 10 minutes give 6 investigations, one cap line, and no queue', async (t) => {
  const b = await bed(t);
  for (let i = 0; i < 30; i += 1) {
    b.triage.accept(payload({ name: `Storm${i}`, severity: i === 20 ? 'p1' : 'p2' }));
    await b.triage.idle(); await b.triage.tick();
    b.clock += 20_000;
  }
  assert.equal(b.holmesRequests.length, 6);
  assert.equal(b.log('investigation').length, 6);
  const capLines = b.posts('#infra-alerts').filter((x) => x.includes('cap reached'));
  assert.equal(capLines.length, 1);
  // Posted 2 minutes after the first skipped alert: it counts what the storm skipped until then.
  assert.match(capLines[0], /^\[test\] 7 alerts not investigated, cap reached \(6 an hour\): Storm6, Storm7, Storm8, Storm9, Storm10, Storm11, Storm12$/);
  assert.equal(b.posts('#infra-watchdog').length, 1);
  assert.equal(b.slackPosts.length, 6 + 2);
  assert.equal(b.log('skip').length, 24);
  // A p1 does not pass the cap, but its log line says both.
  assert.deepEqual(b.log('skip').find((s) => s.alert === 'Storm20').escalate_reasons, ['cap', 'p1']);
  assert.ok(capLines[0].length <= 3000);
});

test('the daily cap: 40 a day', async (t) => {
  const b = await bed(t);
  for (let i = 0; i < 45; i += 1) { await fire(b, { name: `Day${i}` }); b.clock += 15 * MIN; } // 4 an hour, 11 hours
  assert.equal(b.holmesRequests.length, 40);
  assert.ok(b.log('skip').every((s) => s.reason === 'cap_day'));
  assert.equal(b.log('skip').length, 5);
  assert.match(b.posts('#infra-alerts').find((x) => x.includes('cap reached')), /cap reached \(40 a day\)/);
});

test('Slack down: the finding is still in the log, marked and escalated; the service goes on', async (t) => {
  const b = await bed(t);
  b.slack = (req, res) => { res.writeHead(503); res.end('upstream down'); };
  await fire(b, {});
  const line = b.log('investigation')[0];
  assert.deepEqual(line.finding, GOOD);
  assert.deepEqual([line.slack_posted, line.escalate, line.escalate_reasons], [false, true, ['slack_failed']]);
  assert.equal(b.slackAttempts, 6); // 3 tries for the finding, 3 for the escalation line
  assert.equal(b.metric('alert_triage_failures_total{stage="slack"}'), 2);
  assert.ok(!JSON.stringify(b.lines).includes(SLACK_TOKEN));

  // Slack answers 200 with ok:false for a wrong token: a failure too, and not retried.
  b.slackAttempts = 0;
  b.slack = (req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":false,"error":"invalid_auth"}'); };
  await fire(b, { name: 'Second' });
  assert.equal(b.slackAttempts, 2);
  assert.equal(b.log('investigation')[1].slack_posted, false);

  // One failed try, then Slack is back: posted, not escalated.
  b.slackAttempts = 0;
  b.slack = (req, res) => { if (b.slackAttempts === 1) { res.writeHead(502); res.end('x'); } else { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"ok":true}'); } };
  await fire(b, { name: 'Third' });
  assert.deepEqual([b.log('investigation')[2].slack_posted, b.log('investigation')[2].escalate], [true, false]);
});

test('untrusted text: no mention, no link, no markup reaches Slack; at most 3,000 characters', async (t) => {
  const b = await bed(t);
  b.holmesAnswer = () => ({ analysis: JSON.stringify({
    cause: '<!channel> <@U123ABC> <https://evil.example|click here> & @here @channel @everyone',
    evidence: `see http://evil.example/a and HTTPS://evil.example/b\u0007\u202e ${'&<>'.repeat(2000)}`,
    next_step: 'run <!here|here> now', confidence: 'medium',
  }) });
  await fire(b, { name: 'Bad<!everyone>Name', app: '<@U999>', namespace: 'a|b', summary: '<https://evil.example|x>' });
  const text = b.posts('#infra-alerts')[0];
  assert.ok(text.length <= 3000, `length ${text.length}`);
  // The only `<` in the message opens our own Grafana link.
  assert.deepEqual(text.match(/<[^>]*>/g), ['<https://grafana.example.com/alerting/list|alert list>']);
  assert.doesNotMatch(text.replace('<https://grafana.example.com/alerting/list|alert list>', ''), /https?:\/\//i);
  assert.doesNotMatch(text, /@(here|channel|everyone)/);
  assert.match(text, /&lt;!channel&gt; &lt;@U123ABC&gt; &lt;hxxps:\/\/evil\.example\|click here&gt; &amp; @\u200bhere/);
  assert.doesNotMatch(text, /&[a-z]{0,3}…$/, 'the cut must not leave half an escaped character');
  assert.match(text, /^\*\[test\] Finding for Bad&lt;!everyone&gt;Name\* · p2 · app &lt;@U999&gt; · namespace a\|b/);
  // The log keeps the text as it was (JSON-encoded), within the field limits.
  const finding = b.log('investigation')[0].finding;
  assert.match(finding.cause, /^<!channel>/);
  assert.ok(finding.evidence.length <= 1100);
});

test('slackSafe', () => {
  assert.equal(slackSafe('a <b> & c', 100), 'a &lt;b&gt; &amp; c');
  assert.equal(slackSafe('x'.repeat(50), 10), `${'x'.repeat(9)}…`);
  assert.equal(slackSafe({ a: 1 }, 100), '{"a":1}');
  assert.equal(slackSafe('line1\n\n\n\n\nline2\ttab', 100), 'line1\n\nline2 tab');
});

test('never investigated: resolved, p3, Watchdog, its own alerts, node-down of an on-demand node', async (t) => {
  const b = await bed(t);
  const r = await fire(b,
    { status: 'resolved' },
    { severity: 'p3' },
    { labels: { severity: undefined } },
    { name: 'Watchdog', severity: 'p1' },
    { name: 'AlertTriageFailing' },
    { name: 'KubeNodeNotReady', severity: 'p1', labels: { node: 'gpu-worker' } },
    { name: 'NodeExporterDown', labels: { node: 'gpu-worker' } });
  assert.deepEqual(r, { accepted: 0, skipped: 7 });
  assert.equal(b.holmesRequests.length, 0);
  assert.equal(b.slackPosts.length, 0);
  assert.deepEqual(b.log('skip').map((s) => s.reason), ['resolved', 'severity', 'severity', 'rule', 'rule', 'rule', 'rule']);
  assert.ok(b.log('skip').every((s) => s.escalate === false));
  // The same alert for a node that is not on demand is investigated.
  assert.deepEqual(await fire(b, { name: 'KubeNodeNotReady', severity: 'p1', labels: { node: 'worker1' } }), { accepted: 1, skipped: 0 });
});

test('one investigation at a time', async (t) => {
  const b = await bed(t);
  let running = 0; let peak = 0;
  b.holmes = (req, res) => {
    running += 1; peak = Math.max(peak, running);
    setTimeout(() => { running -= 1; res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(b.holmesAnswer())); }, 30);
  };
  b.triage.accept(payload({ name: 'A' }, { name: 'B' }, { name: 'C' }));
  b.triage.accept(payload({ name: 'D' }));
  assert.equal(b.metric('alert_triage_in_progress'), 4);
  await b.triage.idle();
  assert.equal(b.holmesRequests.length, 4);
  assert.equal(peak, 1);
  assert.equal(b.metric('alert_triage_in_progress'), 0);
});

test('restart in the middle of an hour: caps and windows survive; an investigation in flight is reported', async (t) => {
  const b = await bed(t);
  for (let i = 0; i < 4; i += 1) { await fire(b, { name: `Before${i}` }); b.clock += 5 * MIN; }
  b.holmes = () => {}; // the fifth hangs, and the process dies with it
  b.triage.accept(payload({ name: 'InFlight', severity: 'p1' }));
  await new Promise((r) => { setTimeout(r, 50); });
  assert.equal(JSON.parse(fs.readFileSync(b.cfg.stateFile, 'utf8')).pending.length, 1);

  // A new process with the same volume.
  b.lines.length = 0; b.slackPosts.length = 0; b.holmesRequests.length = 0;
  b.holmes = (req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(b.holmesAnswer())); };
  b.triage = b.start();
  await b.triage.idle();
  const interrupted = b.log('investigation');
  assert.deepEqual(interrupted.map((l) => [l.alert, l.outcome, l.escalate, l.escalate_reasons]), [['InFlight', 'interrupted', true, ['interrupted']]]);
  assert.match(b.posts('#infra-watchdog')[0], /1 investigation\(s\) interrupted by a restart of the triage service, no finding: InFlight/);
  assert.equal(b.metric('alert_triage_cap_used{window="hour"}'), 5);
  assert.equal(JSON.parse(fs.readFileSync(b.cfg.stateFile, 'utf8')).pending.length, 0);

  b.clock += 5 * MIN;
  await fire(b, { name: 'Before0' }); // still inside its 4 hour window
  assert.equal(b.log('skip')[0].reason, 'dedup');
  await fire(b, { name: 'Sixth' });
  await fire(b, { name: 'Seventh' });
  assert.equal(b.holmesRequests.length, 1, 'only one place was left in the hour');
  assert.equal(b.log('skip').at(-1).reason, 'cap_hour');
  // A third process does not report the interrupted one again.
  b.lines.length = 0;
  b.triage = b.start();
  await b.triage.idle();
  assert.equal(b.log('investigation').length, 0);
});

test('fail safe: an unreadable state file means the hourly cap is used for one hour', async (t) => {
  const b = await bed(t);
  fs.writeFileSync(b.cfg.stateFile, '{"version":1,"investigations":[17');
  b.lines.length = 0;
  b.triage = b.start();
  assert.match(b.log('state')[0].message, /state file unreadable .* the hourly cap counts as used for one hour/);
  assert.equal(b.metric('alert_triage_state_failsafe'), 1);
  await fire(b, {});
  assert.equal(b.holmesRequests.length, 0);
  assert.deepEqual([b.log('skip')[0].reason, b.log('skip')[0].escalate], ['cap_hour', true]);
  b.clock += 61 * MIN;
  await fire(b, {});
  assert.equal(b.holmesRequests.length, 1);
  assert.equal(b.metric('alert_triage_state_failsafe'), 0);
});

test('fail safe: a state file that cannot be written stops new investigations after the one in hand', async (t) => {
  const b = await bed(t, { stateFile: '/nonexistent-dir-for-alert-triage-test/state.json' });
  b.lines.length = 0;
  b.triage = b.start(); // no file: starts empty, like a new install
  await fire(b, { name: 'First' });
  assert.match(b.log('state').at(-1).message, /state file not writable/);
  await fire(b, { name: 'Second' });
  assert.equal(b.holmesRequests.length, 1);
  assert.equal(b.log('skip')[0].reason, 'cap_hour');
});

test('a new install (no state file) starts empty and says so', async (t) => {
  const b = await bed(t);
  assert.match(b.log('state')[0].message, /new install, starting empty/);
  assert.equal(b.metric('alert_triage_state_failsafe'), 0);
});

test('HTTP: webhook, health, metrics; bad input is refused without a crash', async (t) => {
  const b = await bed(t);
  const { port, metricsPort } = await b.triage.listen();
  t.after(() => b.triage.close());
  const post = (body, p = '/webhook') => fetch(`http://127.0.0.1:${port}${p}`, { method: 'POST', body });
  const ok = await post(JSON.stringify(payload({})));
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), { accepted: 1, skipped: 0 });
  assert.equal((await post('not json')).status, 400);
  assert.equal((await post('{"alerts":"x"}')).status, 400);
  assert.equal((await post('{}', '/other')).status, 404);
  assert.equal((await fetch(`http://127.0.0.1:${port}/healthz`)).status, 200);
  assert.equal((await fetch(`http://127.0.0.1:${port}/metrics`)).status, 404, 'metrics are on their own port');
  await b.triage.idle();
  const metrics = await (await fetch(`http://127.0.0.1:${metricsPort}/metrics`)).text();
  for (const name of ['alert_triage_investigations_total{outcome="ok"} 1', 'alert_triage_skipped_total{reason="dedup"} 0', 'alert_triage_skipped_total{reason="cap_hour"} 0',
    'alert_triage_failures_total{stage="holmes"} 0', 'alert_triage_failures_total{stage="slack"} 0', 'alert_triage_tokens_total{kind="prompt"} 12000',
    'alert_triage_escalations_total{reason="cap"} 0', 'alert_triage_cap_limit{window="hour"} 6', 'alert_triage_cap_limit{window="day"} 40']) {
    assert.ok(metrics.includes(`${name}\n`), name);
  }
  assert.equal((await fetch(`http://127.0.0.1:${metricsPort}/webhook`, { method: 'POST', body: '{}' })).status, 404);
});

test('configuration: required values, and a Grafana link that cannot carry markup', () => {
  const base = { CLUSTER: 'c', HOLMES_URL: 'http://h/api/chat', HOLMES_API_KEY_FILE: '/k', SLACK_TOKEN_FILE: '/t' };
  const cfg = configFromEnv(base);
  assert.deepEqual([cfg.capHour, cfg.capDay, cfg.dedupMs, cfg.holmesTimeoutMs, cfg.repeatCount, cfg.maxMessageChars], [6, 40, 4 * HOUR, 300_000, 3, 3000]);
  assert.deepEqual(cfg.severities, ['p1', 'p2']);
  assert.throws(() => configFromEnv({ ...base, CLUSTER: '' }), /missing env CLUSTER/);
  assert.throws(() => configFromEnv({ ...base, GRAFANA_URL: 'https://g.example/|x> <!channel' }), /GRAFANA_URL/);
  assert.throws(() => configFromEnv({ ...base, GRAFANA_URL: 'http://g.example/' }), /GRAFANA_URL/);
});
