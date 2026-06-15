// Lightweight smoke test — no framework. Boots the server in-process and checks
// the HTTP endpoints (incl. the malformed-URL + traversal guards) and the full
// WebSocket signaling relay (join, offer/answer/ICE routing, stats, leave,
// broadcaster replacement, reconnect re-announce). Run: npm test
//
// This does NOT exercise real WebRTC media (that needs browsers + devices) — it
// verifies the server contract the browser clients depend on.

import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from 'ws';

const PORT = process.env.PORT || 4173;
process.env.PORT = String(PORT);
const BASE = `http://localhost:${PORT}`;
const WSURL = `ws://localhost:${PORT}/ws`;

let pass = 0, fail = 0;
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log('  \x1b[32m✓\x1b[0m', name); }
  else { fail++; console.error('  \x1b[31m✗\x1b[0m', name, detail); }
};

// Start the server in this process, then wait until it answers.
await import('../src/server.js');
let up = false;
for (let i = 0; i < 50; i++) {
  try { if ((await fetch(BASE + '/api/info')).ok) { up = true; break; } } catch {}
  await sleep(100);
}
ok('server boots and serves /api/info', up);

console.log('\nHTTP:');
{
  const r = await fetch(BASE + '/');
  ok('GET / -> 200 html', r.status === 200 && /text\/html/.test(r.headers.get('content-type')));
  ok('GET /broadcast -> 200', (await fetch(BASE + '/broadcast')).status === 200);
  const j = await (await fetch(BASE + '/api/info')).json();
  ok('GET /api/info has listenerUrl + lanIp', !!j.listenerUrl && !!j.lanIp);
  const qr = await fetch(BASE + '/qr.svg?text=http://x/');
  ok('GET /qr.svg -> svg', qr.status === 200 && (await qr.text()).startsWith('<svg'));
  const js = await fetch(BASE + '/js/listener.js');
  ok('GET /js/listener.js -> 200 js', js.status === 200 && /javascript/.test(js.headers.get('content-type')));
  ok('GET /css/style.css -> 200', (await fetch(BASE + '/css/style.css')).status === 200);
  ok('GET /nope.js -> 404', (await fetch(BASE + '/nope.js')).status === 404);
  // The guard: a single malformed %-sequence must NOT crash the process.
  ok('malformed %-encoding -> 400 (no crash)', (await fetch(BASE + '/%E0%A4%A')).status === 400);
  const trav = await fetch(BASE + '/..%2f..%2fpackage.json');
  ok('path traversal blocked', trav.status === 403 || trav.status === 404);
}

console.log('\nSignaling:');
const open = () => new Promise((res, rej) => {
  const ws = new WebSocket(WSURL);
  ws.inbox = [];
  ws.on('message', (d) => ws.inbox.push(JSON.parse(d)));
  ws.on('open', () => res(ws));
  ws.on('error', rej);
});
const send = (ws, o) => ws.send(JSON.stringify(o));
const has = (ws, t) => ws.inbox.some((m) => m.type === t);
const get = (ws, t) => ws.inbox.find((m) => m.type === t);
const lastCount = (ws) => (ws.inbox.filter((m) => m.type === 'listener-count').pop() || {}).count;

const b = await open();
send(b, { type: 'hello', role: 'broadcaster' });
await sleep(150);
ok('broadcaster gets welcome', has(b, 'welcome'));

const l = await open();
send(l, { type: 'hello', role: 'listener', house: false });
await sleep(150);
ok('listener gets welcome', has(l, 'welcome'));
ok('listener told broadcaster-available', has(l, 'broadcaster-available'));
ok('broadcaster told listener-joined', has(b, 'listener-joined'));
const lid = get(b, 'listener-joined').id;
ok('listener-count = 1', lastCount(b) === 1);

send(b, { type: 'signal', to: lid, data: { sdp: { type: 'offer', sdp: 'FAKE' } } });
await sleep(120);
ok('offer relayed broadcaster -> listener', get(l, 'signal')?.from === 'broadcaster');

send(l, { type: 'signal', to: 'broadcaster', data: { sdp: { type: 'answer', sdp: 'FAKE' } } });
await sleep(120);
ok('answer relayed listener -> broadcaster', get(b, 'signal')?.from === lid);

send(l, { type: 'signal', to: 'broadcaster', data: { candidate: { candidate: 'FAKE', sdpMid: '0' } } });
await sleep(120);
ok('ICE candidate relayed', b.inbox.filter((m) => m.type === 'signal').some((m) => m.data?.candidate));

send(l, { type: 'stats', stats: { latencyMs: 123, rttMs: 40 } });
await sleep(120);
ok('stats relayed as listener-stats', get(b, 'listener-stats')?.stats?.latencyMs === 123);

l.close();
await sleep(200);
ok('broadcaster told listener-left', has(b, 'listener-left'));
ok('listener-count back to 0', lastCount(b) === 0);

const b2 = await open();
send(b2, { type: 'hello', role: 'broadcaster' });
await sleep(150);
ok('first broadcaster gets replaced', has(b, 'replaced'));

// Reconnect re-announce: existing listener must be re-offered to a fresh broadcaster.
const l2 = await open();
send(l2, { type: 'hello', role: 'listener' });
await sleep(120);
const b3 = await open();
send(b3, { type: 'hello', role: 'broadcaster' });
await sleep(150);
ok('existing listener re-announced to new broadcaster', has(b3, 'listener-joined'));

for (const ws of [b, b2, b3, l2]) { try { ws.close(); } catch {} }
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
