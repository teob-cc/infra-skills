// Key portal for the AmneziaWG gateway. No dependencies: Node 22 standard library only.
//
// Sits behind Pomerium. Every request must carry Pomerium's signed identity assertion
// (X-Pomerium-Jwt-Assertion); the portal verifies it against Pomerium's JWKS and takes the
// user's email and groups from it. A user sees and manages their own devices; members of
// ADMIN_GROUPS see and can revoke every device.
//
// A device's private key is generated here, shown once in the client config and never stored.
// The state file keeps only public keys. Peers are pushed to the interface through the
// WireGuard cross-platform UAPI socket that amneziawg-go exposes.

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const env = (name, fallback) => {
  const v = process.env[name];
  if (v === undefined || v === '') {
    if (fallback === undefined) throw new Error(`missing env ${name}`);
    return fallback;
  }
  return v;
};

const cfg = {
  port: Number(env('PORT', '8080')),
  stateFile: env('STATE_FILE', '/data/peers.json'),
  uapiDirs: env('UAPI_DIRS', '/var/run/amneziawg').split(','),
  iface: env('IFACE', 'awg0'),
  serverConf: env('SERVER_CONF', '/etc/awg/awg0.conf'),
  endpoint: env('ENDPOINT'), // host:port the clients dial
  subnetPrefix: env('SUBNET_PREFIX', '10.77.0.'), // a /24; the gateway is .1
  clientAllowedIps: env('CLIENT_ALLOWED_IPS', '10.77.0.1/32'),
  clientMtu: env('CLIENT_MTU', '1280'),
  nexusUrl: env('NEXUS_URL', ''),
  publicHost: env('PUBLIC_HOST'), // the portal's own host: JWT audience and Origin check
  jwksUrl: env('JWKS_URL'),
  adminGroups: env('ADMIN_GROUPS', '').split(',').map((s) => s.trim()).filter(Boolean),
  maxDevices: Number(env('MAX_DEVICES', '5')),
  title: env('TITLE', 'VPN keys'),
  // Tests only: trust X-Test-Email / X-Test-Groups instead of the Pomerium assertion.
  insecureTestAuth: env('INSECURE_TEST_AUTH', '') === 'i-know-this-is-a-test',
};

// ---------------------------------------------------------------------------------------------
// Server interface config (the Secret the awg container also reads)
// ---------------------------------------------------------------------------------------------

const OBFUSCATION_KEYS = ['Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', 'H1', 'H2', 'H3', 'H4', 'I1', 'I2', 'I3', 'I4', 'I5'];

function readServerConf() {
  const out = {};
  for (const line of fs.readFileSync(cfg.serverConf, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Za-z0-9]+)\s*=\s*(.+?)\s*$/);
    if (m) out[m[1].toLowerCase()] = m[2];
  }
  if (!out.privatekey) throw new Error(`${cfg.serverConf}: no PrivateKey`);
  return out;
}

const PKCS8_X25519_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');

function publicKeyOf(privateKeyB64) {
  const raw = Buffer.from(privateKeyB64, 'base64');
  if (raw.length !== 32) throw new Error('server private key is not 32 bytes');
  const key = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, raw]), format: 'der', type: 'pkcs8' });
  return Buffer.from(crypto.createPublicKey(key).export({ format: 'jwk' }).x, 'base64url').toString('base64');
}

function newKeyPair() {
  const { privateKey } = crypto.generateKeyPairSync('x25519');
  const jwk = privateKey.export({ format: 'jwk' });
  return {
    privateKey: Buffer.from(jwk.d, 'base64url').toString('base64'),
    publicKey: Buffer.from(jwk.x, 'base64url').toString('base64'),
  };
}

// ---------------------------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------------------------

function loadState() {
  try {
    const s = JSON.parse(fs.readFileSync(cfg.stateFile, 'utf8'));
    if (!Array.isArray(s.peers)) throw new Error('peers is not an array');
    return s;
  } catch (e) {
    if (e.code === 'ENOENT') return { peers: [] };
    throw e; // a corrupt state file must not be silently replaced by an empty one
  }
}

function saveState(state) {
  const tmp = `${cfg.stateFile}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, cfg.stateFile);
}

let state = loadState();

function allocateIp() {
  const used = new Set(state.peers.map((p) => p.ip));
  for (let i = 2; i <= 254; i++) {
    const ip = `${cfg.subnetPrefix}${i}`;
    if (!used.has(ip)) return ip;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// UAPI
// ---------------------------------------------------------------------------------------------

function socketPath() {
  for (const dir of cfg.uapiDirs) {
    const p = path.join(dir, `${cfg.iface}.sock`);
    if (fs.existsSync(p)) return p;
  }
  throw new Error(`no UAPI socket for ${cfg.iface} in ${cfg.uapiDirs.join(', ')}`);
}

function uapi(request) {
  return new Promise((resolve, reject) => {
    let sock;
    try {
      sock = net.createConnection(socketPath());
    } catch (e) {
      reject(e);
      return;
    }
    let buf = '';
    sock.setTimeout(5000, () => sock.destroy(new Error('UAPI timeout')));
    sock.on('connect', () => sock.write(`${request}\n\n`));
    sock.on('data', (d) => {
      buf += d.toString('utf8');
      if (buf.endsWith('\n\n')) sock.end();
    });
    sock.on('error', reject);
    sock.on('close', () => {
      const m = buf.match(/(?:^|\n)errno=(-?\d+)\n/);
      if (!m) reject(new Error('UAPI: no errno in reply'));
      else if (m[1] !== '0') reject(new Error(`UAPI errno=${m[1]}`));
      else resolve(buf);
    });
  });
}

const hexOf = (b64) => Buffer.from(b64, 'base64').toString('hex');
const b64Of = (hex) => Buffer.from(hex, 'hex').toString('base64');

async function livePeers() {
  const reply = await uapi('get=1');
  const peers = new Map();
  let cur = null;
  for (const line of reply.split('\n')) {
    const i = line.indexOf('=');
    if (i < 0) continue;
    const k = line.slice(0, i);
    const v = line.slice(i + 1);
    if (k === 'public_key') {
      cur = { allowedIps: [], lastHandshake: 0, rx: 0, tx: 0, endpoint: '' };
      peers.set(b64Of(v), cur);
    } else if (cur) {
      if (k === 'allowed_ip') cur.allowedIps.push(v);
      else if (k === 'last_handshake_time_sec') cur.lastHandshake = Number(v);
      else if (k === 'rx_bytes') cur.rx = Number(v);
      else if (k === 'tx_bytes') cur.tx = Number(v);
      else if (k === 'endpoint') cur.endpoint = v;
    }
  }
  return peers;
}

// Make the interface carry exactly the peers in the state file. Runs after every change and on
// a timer, so a restarted awg container (which comes up with no peers) is refilled.
async function reconcile() {
  const live = await livePeers();
  const want = new Map(state.peers.map((p) => [p.publicKey, `${p.ip}/32`]));
  let same = live.size === want.size;
  if (same) {
    for (const [key, ip] of want) {
      const l = live.get(key);
      if (!l || l.allowedIps.length !== 1 || l.allowedIps[0] !== ip) {
        same = false;
        break;
      }
    }
  }
  if (same) return live;
  const lines = ['set=1'];
  for (const key of live.keys()) {
    if (!want.has(key)) lines.push(`public_key=${hexOf(key)}`, 'remove=true');
  }
  for (const [key, ip] of want) {
    lines.push(`public_key=${hexOf(key)}`, 'replace_allowed_ips=true', `allowed_ip=${ip}`);
  }
  await uapi(lines.join('\n'));
  console.log(`reconciled interface: ${want.size} peer(s)`);
  return livePeers();
}

// One mutation at a time.
let chain = Promise.resolve();
const serial = (fn) => {
  const p = chain.then(fn, fn);
  chain = p.catch(() => {});
  return p;
};

// ---------------------------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------------------------

let jwks = { keys: [], fetchedAt: 0 };

async function jwkFor(kid) {
  let key = jwks.keys.find((k) => k.kid === kid);
  if (!key && Date.now() - jwks.fetchedAt > 10_000) {
    const res = await fetch(cfg.jwksUrl, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(`JWKS fetch: HTTP ${res.status}`);
    const body = await res.json();
    jwks = { keys: Array.isArray(body.keys) ? body.keys : [], fetchedAt: Date.now() };
    key = jwks.keys.find((k) => k.kid === kid);
  }
  return key;
}

async function identify(req) {
  if (cfg.insecureTestAuth) {
    const email = req.headers['x-test-email'];
    if (!email) return null;
    return { email: String(email).toLowerCase(), groups: String(req.headers['x-test-groups'] || '').split(',').filter(Boolean) };
  }
  const token = req.headers['x-pomerium-jwt-assertion'];
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  let header;
  let claims;
  try {
    header = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (header.alg !== 'ES256' || typeof header.kid !== 'string') return null;
  const jwk = await jwkFor(header.kid);
  if (!jwk || jwk.kty !== 'EC' || jwk.crv !== 'P-256') return null;
  const ok = crypto.verify(
    'sha256',
    Buffer.from(`${parts[0]}.${parts[1]}`),
    { key: crypto.createPublicKey({ key: jwk, format: 'jwk' }), dsaEncoding: 'ieee-p1363' },
    Buffer.from(parts[2], 'base64url'),
  );
  if (!ok) return null;
  const now = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp < now - 60) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.includes(cfg.publicHost)) return null;
  if (typeof claims.email !== 'string' || !claims.email) return null;
  return { email: claims.email.toLowerCase(), groups: Array.isArray(claims.groups) ? claims.groups.map(String) : [] };
}

const isAdmin = (user) => user.groups.some((g) => cfg.adminGroups.includes(g));

// ---------------------------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------------------------

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function clientConfig(peer, privateKey, server) {
  const lines = ['[Interface]', `PrivateKey = ${privateKey}`, `Address = ${peer.ip}/32`, `MTU = ${cfg.clientMtu}`];
  for (const k of OBFUSCATION_KEYS) {
    const v = server[k.toLowerCase()];
    if (v !== undefined) lines.push(`${k} = ${v}`);
  }
  lines.push('', '[Peer]', `PublicKey = ${publicKeyOf(server.privatekey)}`, `Endpoint = ${cfg.endpoint}`, `AllowedIPs = ${cfg.clientAllowedIps}`, 'PersistentKeepalive = 25', '');
  return lines.join('\n');
}

function ago(sec) {
  if (!sec) return 'never';
  const d = Math.max(0, Math.floor(Date.now() / 1000) - sec);
  if (d < 90) return `${d} s ago`;
  if (d < 5400) return `${Math.round(d / 60)} min ago`;
  if (d < 129600) return `${Math.round(d / 3600)} h ago`;
  return `${Math.round(d / 86400)} d ago`;
}

function page(user, { live, liveError, created, error } = {}) {
  const admin = isAdmin(user);
  const visible = state.peers.filter((p) => admin || p.owner === user.email);
  const mine = state.peers.filter((p) => p.owner === user.email).length;
  const rows = visible
    .map((p) => {
      const l = live?.get(p.publicKey);
      return `<tr>
        <td>${esc(p.name)}</td>${admin ? `<td>${esc(p.owner)}</td>` : ''}
        <td><code>${esc(p.ip)}</code></td>
        <td>${esc(p.createdAt.slice(0, 10))}</td>
        <td>${liveError ? '?' : esc(ago(l?.lastHandshake))}</td>
        <td><form method="post" action="/devices/${esc(p.id)}/delete"><button class="danger">Revoke</button></form></td>
      </tr>`;
    })
    .join('\n');
  const createdBlock = created
    ? `<section class="new">
        <h2>Config for “${esc(created.peer.name)}”</h2>
        <p><strong>Save it now.</strong> The private key is not stored and this is the only time it is shown.
        If you lose it, revoke the device and add it again.</p>
        <pre id="conf">${esc(created.config)}</pre>
        <p><a class="button" download="${esc(created.fileName)}" href="data:text/plain;base64,${Buffer.from(created.config).toString('base64')}">Download ${esc(created.fileName)}</a></p>
        <p>Next: <a href="#install">install the AmneziaWG client</a> and import this file.</p>
      </section>`
    : '';
  const gatewayIp = cfg.clientAllowedIps.split('/')[0];
  const nexusHost = cfg.nexusUrl ? new URL(cfg.nexusUrl).host : '';
  const install = `<section id="install"><h2>Install a client</h2>
    <p>The config is for <strong>AmneziaWG</strong>, a WireGuard variant that gets through networks where WireGuard is blocked.
    The standard WireGuard app cannot open it. Use the app called <strong>AmneziaWG</strong>, not AmneziaVPN:
    this tunnel carries one address only, and AmneziaVPN may try to send all your traffic into it.</p>
    <div class="scroll"><table><thead><tr><th>System</th><th>Get the app</th><th>Import the config</th></tr></thead><tbody>
      <tr><td>macOS 12+, iPhone, iPad</td>
          <td><a href="https://apps.apple.com/app/amneziawg/id6478942365" rel="noopener">App Store: AmneziaWG</a></td>
          <td>Import tunnel(s) from file, pick the .conf, allow the VPN configuration, then Activate.</td></tr>
      <tr><td>Windows 10/11</td>
          <td><a href="https://github.com/amnezia-vpn/amneziawg-windows-client/releases/latest" rel="noopener">GitHub: amneziawg-windows-client</a> (the installer for your CPU, usually amd64)</td>
          <td>Import tunnel(s) from file, pick the .conf, then Activate.</td></tr>
      <tr><td>Android</td>
          <td><a href="https://play.google.com/store/apps/details?id=org.amnezia.awg" rel="noopener">Google Play: AmneziaWG</a></td>
          <td>Plus button, Import from file or archive, pick the .conf, then switch it on.</td></tr>
      <tr><td>Linux, CI machines</td>
          <td><a href="https://github.com/amnezia-vpn/amneziawg-tools" rel="noopener">amneziawg-tools</a> plus the
              <a href="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module" rel="noopener">kernel module</a> or
              <a href="https://github.com/amnezia-vpn/amneziawg-go" rel="noopener">amneziawg-go</a></td>
          <td>Save the file as <code>/etc/amnezia/amneziawg/nexus.conf</code>, then <code>sudo awg-quick up nexus</code>.</td></tr>
    </tbody></table></div>
    ${cfg.nexusUrl ? `<h2>Check that it works</h2>
    <p>With the tunnel active, this must print <code>HTTP/2 200</code>:</p>
    <pre>curl -sI ${esc(cfg.nexusUrl)}/service/rest/v1/status | head -1</pre>
    <ul>
      <li><strong>Could not resolve host</strong>, or the name resolves to a public address: your router or DNS filters names that
          point at private addresses. Add this line to <code>/etc/hosts</code>
          (Windows: <code>C:\\Windows\\System32\\drivers\\etc\\hosts</code>): <code>${esc(gatewayIp)} ${esc(nexusHost)}</code></li>
      <li><strong>Timeout</strong>: the tunnel is not up. In the app the tunnel should show a recent handshake; on this page
          “Last connected” should stop saying “never”. If it does not, your network may block UDP to <code>${esc(cfg.endpoint)}</code>.</li>
      <li><strong>Everything else on your machine stops working</strong> while connected: you imported the file into AmneziaVPN
          or changed AllowedIPs. Use the AmneziaWG app with the file unchanged.</li>
    </ul>` : ''}
    <p class="muted">One config per machine: the same file on two machines makes both connections drop in turns.
    Lost the file or the machine? Revoke the device above and create a new one.</p></section>`;
  const nexus = cfg.nexusUrl
    ? `<section><h2>Nexus over the VPN</h2>
        <p>While connected, <code>${esc(cfg.nexusUrl)}</code> serves the repositories read-only with no credentials.
        Use the same repository paths as on the public API host and remove the username and password for it
        from your Maven, sbt or npm settings. Publishing still goes through the public host with your own login.</p>
        <p>The tunnel carries traffic to that one address only; everything else on your machine stays off the VPN.</p></section>`
    : '';
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(cfg.title)}</title>
<style>
  :root { color-scheme: light dark; --fg:#1b1f24; --bg:#fff; --muted:#5b6570; --line:#d7dce1; --accent:#0b5fd1; --danger:#b3261e; --box:#f4f6f8; }
  @media (prefers-color-scheme: dark) { :root { --fg:#e6e9ec; --bg:#14171a; --muted:#9aa4ae; --line:#30363d; --accent:#6aa7ff; --danger:#ff8a80; --box:#1d2227; } }
  body { font: 15px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg); max-width: 820px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 22px; margin: 0 0 4px; } h2 { font-size: 17px; margin: 28px 0 8px; }
  .who { color: var(--muted); margin: 0 0 16px; }
  .scroll { overflow-x: auto; } table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
  th { color: var(--muted); font-weight: 600; font-size: 13px; }
  pre { background: var(--box); border: 1px solid var(--line); border-radius: 6px; padding: 12px; overflow-x: auto; font-size: 13px; }
  code { font-size: 13px; }
  a { color: var(--accent); } li { margin: 6px 0; } td { white-space: normal; } th, td:first-child { white-space: nowrap; }
  input[type=text] { font: inherit; padding: 6px 8px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--fg); min-width: 220px; }
  button, .button { font: inherit; padding: 6px 12px; border-radius: 6px; border: 1px solid var(--accent); background: var(--accent); color: #fff; cursor: pointer; text-decoration: none; display: inline-block; }
  button.danger { background: transparent; color: var(--danger); border-color: var(--danger); }
  .new { border: 1px solid var(--accent); border-radius: 8px; padding: 4px 16px 8px; margin-top: 20px; }
  .error { border: 1px solid var(--danger); color: var(--danger); border-radius: 6px; padding: 8px 12px; }
  .muted { color: var(--muted); }
</style></head><body>
<h1>${esc(cfg.title)}</h1>
<p class="who">Signed in as ${esc(user.email)}${admin ? ' · admin: all devices shown' : ''}</p>
${error ? `<p class="error">${esc(error)}</p>` : ''}
${liveError ? `<p class="error">The VPN gateway is not answering (${esc(liveError)}). Devices are listed from the saved state.</p>` : ''}
${createdBlock}
<h2>${admin ? 'Devices' : 'Your devices'}</h2>
${visible.length ? `<div class="scroll"><table><thead><tr><th>Name</th>${admin ? '<th>Owner</th>' : ''}<th>Address</th><th>Added</th><th>Last connected</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : '<p class="muted">No devices yet.</p>'}
<h2>Add a device</h2>
${mine >= cfg.maxDevices
    ? `<p class="muted">You have ${mine} devices, which is the limit. Revoke one to add another.</p>`
    : `<form method="post" action="/devices"><input type="text" name="name" required maxlength="40" pattern="[A-Za-z0-9 ._\\-]{1,40}" placeholder="e.g. work-laptop"> <button>Create key</button></form>
       <p class="muted">One key per machine. Letters, digits, space, dot, dash and underscore.</p>`}
${install}
${nexus}
</body></html>`;
}

// ---------------------------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------------------------

function send(res, status, body, type = 'text/html; charset=utf-8', extra = {}) {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    // Not no-referrer: that makes browsers send "Origin: null" on this page's own form posts.
    'referrer-policy': 'same-origin',
    'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    ...extra,
  });
  res.end(body);
}

function readForm(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 4096) {
        reject(new Error('body too large'));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => resolve(new URLSearchParams(Buffer.concat(chunks).toString('utf8'))));
    req.on('error', reject);
  });
}

// A state-changing request must come from this page: browsers send Origin on every POST.
function sameOrigin(req) {
  // Sec-Fetch-Site is set by the browser and cannot be set or changed by page script.
  const site = req.headers['sec-fetch-site'];
  if (typeof site === 'string') return site === 'same-origin';
  const origin = req.headers.origin;
  if (typeof origin !== 'string') return false;
  try {
    return new URL(origin).host === cfg.publicHost;
  } catch {
    return false;
  }
}

async function liveOrError() {
  try {
    return { live: await reconcile() };
  } catch (e) {
    return { liveError: e.message };
  }
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && url.pathname === '/healthz') {
    send(res, 200, 'ok\n', 'text/plain');
    return;
  }
  const user = await identify(req);
  if (!user) {
    send(res, 401, 'No valid Pomerium identity on this request.\n', 'text/plain');
    return;
  }

  if (req.method === 'GET' && url.pathname === '/') {
    send(res, 200, page(user, await liveOrError()));
    return;
  }

  if (req.method !== 'POST') {
    send(res, 404, 'Not found\n', 'text/plain');
    return;
  }
  if (!sameOrigin(req)) {
    send(res, 403, 'Cross-origin request refused.\n', 'text/plain');
    return;
  }

  if (url.pathname === '/devices') {
    const form = await readForm(req);
    const name = (form.get('name') || '').trim();
    if (!/^[A-Za-z0-9 ._-]{1,40}$/.test(name)) {
      send(res, 400, page(user, { ...(await liveOrError()), error: 'Device name: 1–40 letters, digits, space, dot, dash or underscore.' }));
      return;
    }
    const result = await serial(async () => {
      const mine = state.peers.filter((p) => p.owner === user.email);
      if (mine.length >= cfg.maxDevices) return { error: `You already have ${mine.length} devices, which is the limit.` };
      if (mine.some((p) => p.name === name)) return { error: `You already have a device named “${name}”.` };
      const ip = allocateIp();
      if (!ip) return { error: 'The address pool is full. Ask an admin to revoke unused devices.' };
      const keys = newKeyPair();
      const peer = { id: crypto.randomBytes(8).toString('hex'), owner: user.email, name, publicKey: keys.publicKey, ip, createdAt: new Date().toISOString() };
      const next = { peers: [...state.peers, peer] };
      saveState(next);
      state = next;
      console.log(`device added: ${peer.owner} "${peer.name}" ${peer.ip}`);
      const config = clientConfig(peer, keys.privateKey, readServerConf());
      const fileName = `${name.replace(/[^A-Za-z0-9._-]+/g, '-')}.conf`;
      return { created: { peer, config, fileName } };
    });
    send(res, result.error ? 400 : 200, page(user, { ...(await liveOrError()), ...result }));
    return;
  }

  const del = url.pathname.match(/^\/devices\/([0-9a-f]{16})\/delete$/);
  if (del) {
    const result = await serial(async () => {
      const peer = state.peers.find((p) => p.id === del[1]);
      if (!peer || (peer.owner !== user.email && !isAdmin(user))) return { error: 'No such device.' };
      const next = { peers: state.peers.filter((p) => p.id !== peer.id) };
      saveState(next);
      state = next;
      console.log(`device revoked: ${peer.owner} "${peer.name}" ${peer.ip} by ${user.email}`);
      return {};
    });
    if (result.error) {
      send(res, 404, page(user, { ...(await liveOrError()), ...result }));
      return;
    }
    await liveOrError(); // push the removal to the interface before answering
    send(res, 303, '', 'text/plain', { location: '/' });
    return;
  }

  send(res, 404, 'Not found\n', 'text/plain');
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.error(`${req.method} ${req.url}: ${e.stack || e}`);
    if (!res.headersSent) send(res, 500, 'Internal error\n', 'text/plain');
    else res.end();
  });
});

readServerConf(); // fail at start, not at the first key request
server.listen(cfg.port, () => console.log(`portal listening on :${cfg.port}, ${state.peers.length} device(s) in state`));

setInterval(() => {
  serial(reconcile).catch((e) => console.error(`reconcile: ${e.message}`));
}, 20_000).unref();
serial(reconcile).catch((e) => console.error(`reconcile: ${e.message}`));

for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => server.close(() => process.exit(0)));
