// nudisco server: serves the static broadcaster/listener pages and runs the
// WebSocket signaling endpoint at /ws. No framework — tiny static handler keeps
// dependencies to just `ws` (signaling) and `qrcode` (join QR).
//
// Default: plain HTTP on the LAN. getUserMedia (broadcaster) only needs a secure
// context, and the broadcaster runs on http://localhost which counts as secure.
// Listeners only RECEIVE audio. If a phone browser refuses WebRTC over plain
// http, run with --https (see `npm run gen-cert` and the README).

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { WebSocketServer } from 'ws';
import { SignalingHub } from './signaling.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const CERT_DIR = path.join(__dirname, '..', 'certs');

// ---- args ----------------------------------------------------------------
const argv = process.argv.slice(2);
const hasFlag = (name) => argv.includes('--' + name);
const getOpt = (name, def) => {
  const i = argv.indexOf('--' + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};

const useHttps = hasFlag('https');
const PORT = parseInt(getOpt('port', process.env.PORT || (useHttps ? '8443' : '3000')), 10);
const HOST = getOpt('host', '0.0.0.0');

// ---- LAN IP detection ----------------------------------------------------
function lanIp() {
  const ifaces = os.networkInterfaces();
  const found = [];
  for (const [name, addrs] of Object.entries(ifaces)) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal) found.push({ name, address: a.address });
    }
  }
  // Prefer en0 (typical Mac Wi-Fi), then any other non-internal IPv4.
  const en0 = found.find((c) => c.name === 'en0');
  return (en0 || found[0] || { address: '127.0.0.1' }).address;
}

// ---- static + small API --------------------------------------------------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.ttf': 'font/ttf',
};

function send(res, code, body, headers = {}) {
  res.writeHead(code, headers);
  res.end(body);
}

async function handleRequest(req, res) {
  const u = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  let pathname;
  try { pathname = decodeURIComponent(u.pathname); }
  catch { return send(res, 400, 'bad request'); }  // malformed %-encoding

  // JSON: canonical listener URL (always the LAN IP, never localhost).
  if (pathname === '/api/info') {
    const ip = lanIp();
    const scheme = useHttps ? 'https' : 'http';
    return send(res, 200, JSON.stringify({
      lanIp: ip,
      port: PORT,
      scheme,
      secure: useHttps,
      listenerUrl: `${scheme}://${ip}:${PORT}/`,
    }), { 'content-type': MIME['.json'], 'cache-control': 'no-store' });
  }

  // QR for the join URL.
  if (pathname === '/qr.svg') {
    const text = u.searchParams.get('text') || '';
    try {
      const svg = await QRCode.toString(String(text), {
        type: 'svg', margin: 1, width: 320,
        color: { dark: '#0b0d12', light: '#ffffff' },
      });
      return send(res, 200, svg, { 'content-type': MIME['.svg'], 'cache-control': 'no-store' });
    } catch {
      return send(res, 400, 'bad qr request');
    }
  }

  // Page routes.
  if (pathname === '/') pathname = '/index.html';
  else if (pathname === '/broadcast' || pathname === '/broadcast/') pathname = '/broadcast.html';

  // Static file (path-traversal safe — compare the resolved relative path, not a
  // raw string prefix, so a sibling dir like `public-data` can't sneak through).
  const filePath = path.join(PUBLIC_DIR, path.normalize(pathname));
  const rel = path.relative(PUBLIC_DIR, filePath);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return send(res, 403, 'forbidden');

  fs.readFile(filePath, (err, data) => {
    if (err) return send(res, 404, 'not found');
    const ext = path.extname(filePath).toLowerCase();
    send(res, 200, data, { 'content-type': MIME[ext] || 'application/octet-stream' });
  });
}

// ---- create server -------------------------------------------------------
let server;
if (useHttps) {
  const keyPath = path.join(CERT_DIR, 'key.pem');
  const certPath = path.join(CERT_DIR, 'cert.pem');
  if (!fs.existsSync(keyPath) || !fs.existsSync(certPath)) {
    console.error('\n  --https was passed but certs/key.pem + certs/cert.pem are missing.');
    console.error('  Generate them first:  npm run gen-cert\n');
    process.exit(1);
  }
  server = https.createServer(
    { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) },
    handleRequest
  );
} else {
  server = http.createServer(handleRequest);
}

// ---- signaling -----------------------------------------------------------
const wss = new WebSocketServer({ server, path: '/ws' });
const hub = new SignalingHub();
wss.on('connection', (ws) => hub.handleConnection(ws));

// Heartbeat: drop sockets that stopped answering (Wi-Fi dropouts, sleep).
const heartbeat = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) return ws.terminate();
    ws.isAlive = false;
    try { ws.ping(); } catch {}
  });
}, 15000);
wss.on('close', () => clearInterval(heartbeat));

// ---- go ------------------------------------------------------------------
server.listen(PORT, HOST, () => {
  const ip = lanIp();
  const scheme = useHttps ? 'https' : 'http';
  const line = '─'.repeat(54);
  console.log('\n  \x1b[1m\x1b[35mnudisco\x1b[0m  silent-disco server  (' + scheme.toUpperCase() + ')');
  console.log('  ' + line);
  console.log('  DJ / broadcaster (this Mac):  ' + scheme + '://localhost:' + PORT + '/broadcast');
  console.log('  Listeners (phones):           \x1b[1m' + scheme + '://' + ip + ':' + PORT + '/\x1b[0m');
  console.log('  House Speaker (this Mac):      ' + scheme + '://localhost:' + PORT + '/?house=1');
  console.log('  ' + line);
  if (useHttps) {
    console.log('  HTTPS uses a self-signed cert — trust it on each phone (see README).');
  } else {
    console.log('  If a phone refuses to connect over http, try: npm run gen-cert && npm run start:https');
  }
  console.log('  Press Ctrl+C to stop.\n');
});

// Never let one bad request (or a future async throw in a handler) take down the
// single broadcast server for the whole room.
process.on('unhandledRejection', (err) => console.error('unhandledRejection:', err));
server.on('clientError', (err, socket) => { try { socket.destroy(); } catch {} });

process.on('SIGINT', () => { console.log('\n  bye 👋'); process.exit(0); });
