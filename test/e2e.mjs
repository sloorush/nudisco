// End-to-end test in REAL Chromium with a fake mic. Exercises the actual browser
// pipeline the phones use — real WebRTC negotiation, Opus SDP munging, host-ICE,
// and audio actually flowing — driven through the real UI with REAL trusted
// clicks under the REAL autoplay policy (no override). This is deliberately
// faithful: a covering overlay, a hidden Start button, or a blocked autoplay
// would all fail the test the way they'd fail a real guest.
//
// Run: npm run test:e2e   (needs Google Chrome; uses puppeteer-core)

import { setTimeout as sleep } from 'node:timers/promises';
import { existsSync } from 'node:fs';
import puppeteer from 'puppeteer-core';

const PORT = process.env.PORT || 4174;
process.env.PORT = String(PORT);

const CHROME = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
].find(existsSync);
if (!CHROME) { console.error('No Chrome/Chromium/Edge found.'); process.exit(2); }

let pass = 0, fail = 0;
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log('  \x1b[32m✓\x1b[0m', name); }
  else { fail++; console.error('  \x1b[31m✗\x1b[0m', name, detail ? '— ' + detail : ''); }
};

async function waitFor(label, fn, { timeout = 20000, interval = 300 } = {}) {
  const start = Date.now();
  let last;
  while (Date.now() - start < timeout) {
    try { last = await fn(); } catch { last = undefined; }
    if (last) return last;
    await sleep(interval);
  }
  throw new Error(`timeout: ${label}` + (last !== undefined ? ` (last=${JSON.stringify(last)})` : ''));
}

// A REAL trusted click (CDP mouse input). Unlike el.click(), this is blocked by
// a covering overlay and counts as a user gesture for autoplay — so it tests
// what a real finger tap does.
async function tap(page, sel, timeout = 10000) {
  const h = await page.waitForSelector(sel, { visible: true, timeout });
  await h.evaluate((el) => el.scrollIntoView({ block: 'center' }));
  await h.click();
  return h;
}

// What element actually sits on top at the center of `sel`? Catches invisible
// overlays that would swallow taps.
const topAt = (page, sel) => page.evaluate((s) => {
  const b = document.querySelector(s);
  const r = b.getBoundingClientRect();
  const el = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  return el ? (el.id || el.className || el.tagName) : null;
}, sel);

const TAP_PCS = () => {
  const O = window.RTCPeerConnection;
  window.__pcs = [];
  window.RTCPeerConnection = new Proxy(O, { construct(t, a) { const pc = new t(...a); window.__pcs.push(pc); return pc; } });
};
const media = (page) => page.evaluate(async () => {
  const pc = (window.__pcs || []).slice(-1)[0];
  const pl = document.getElementById('player');
  const r = { connectionState: pc?.connectionState || 'none', bytesReceived: 0, paused: pl?.paused, resumeHidden: document.getElementById('resume')?.hidden };
  if (pc) (await pc.getStats()).forEach((s) => { if (s.type === 'inbound-rtp' && s.kind === 'audio') r.bytesReceived = s.bytesReceived || 0; });
  return r;
});

// Drive a listener page from load -> connected -> audibly playing. If autoplay
// needed a second gesture, tap the resume overlay (and assert it then clears).
async function joinAndPlay(page, label) {
  ok(`${label}: join button not covered by an overlay`, (await topAt(page, '#joinBtn')) === 'joinBtn');
  await tap(page, '#joinBtn');
  await waitFor(`${label} connected`, async () => (await media(page)).connectionState === 'connected');
  let m = await media(page);
  if (!m.resumeHidden) { await tap(page, '#resumeBtn'); }      // autoplay slipped the gesture window
  m = await waitFor(`${label} audio playing`, async () => {
    const x = await media(page);
    return x.bytesReceived > 0 && x.paused === false && x.resumeHidden === true ? x : null;
  });
  ok(`${label}: connected + audio playing, no stuck resume overlay`, m.bytesReceived > 0 && m.paused === false && m.resumeHidden, JSON.stringify(m));
  return m;
}

const logs = [];
function wire(page, tag) {
  page.on('console', (m) => logs.push(`[${tag}/${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[${tag}/ERR] ${e.message}`));
}
async function newListener(browser, url, tag) {
  const p = await browser.newPage();
  await p.evaluateOnNewDocument(TAP_PCS);
  wire(p, tag);
  await p.goto(url, { waitUntil: 'load' });
  return p;
}

await import('../src/server.js');
await waitFor('server up', async () => (await fetch(`http://localhost:${PORT}/api/info`)).ok);
const info = await (await fetch(`http://localhost:${PORT}/api/info`)).json();
const LAN = `http://${info.lanIp}:${PORT}`, LOCAL = `http://localhost:${PORT}`;
console.log(`server: ${LOCAL} + LAN ${LAN}`);

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: true,
  protocolTimeout: 240000,
  defaultViewport: { width: 1100, height: 1000 },
  args: [
    '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream',
    '--disable-features=WebRtcHideLocalIpsWithMdns',
    '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage',
    // NOTE: no --autoplay-policy override — we test the real gesture/autoplay path.
  ],
});

try {
  console.log('\nBroadcaster:');
  const dj = await browser.newPage(); await dj.evaluateOnNewDocument(TAP_PCS); wire(dj, 'dj');
  await dj.goto(`${LOCAL}/broadcast`, { waitUntil: 'load' });
  await tap(dj, '#enableBtn');
  let startVisible = true;
  try { await dj.waitForSelector('#startBtn', { visible: true, timeout: 8000 }); } catch { startVisible = false; }
  ok('Start button appears after Enable inputs', startVisible);
  if (!startVisible) throw new Error('Start never became visible');
  await tap(dj, '#startBtn');
  await waitFor('on air', async () => /On air/i.test(await dj.$eval('#status', (e) => e.textContent)));
  ok('broadcaster goes on air', true);

  console.log('\nListener A (localhost, secure context):');
  const la = await newListener(browser, `${LOCAL}/`, 'A');
  await joinAndPlay(la, 'A');
  ok('A: UI says Connected', /Connected/i.test(await la.$eval('#status', (e) => e.textContent)));
  ok('A: latency number shows (frames really played out)',
    await waitFor('A latency', async () => { const t = await la.$eval('#latency', (e) => e.textContent); return /\d+\s*ms/.test(t) && !/^—/.test(t); }));

  console.log('\nResilience (RED/NACK) + buffering (Listener A):');
  const detail = await la.evaluate(async () => {
    const pc = (window.__pcs || []).slice(-1)[0];
    const recv = pc && pc.getReceivers && pc.getReceivers().find((r) => r.track && r.track.kind === 'audio');
    // sample inbound bitrate ~1.5s apart to confirm RED redundancy is on the wire
    const b1 = await pc.getStats(); let by1 = 0, t1 = 0;
    b1.forEach((s) => { if (s.type === 'inbound-rtp' && s.kind === 'audio') { by1 = s.bytesReceived; t1 = s.timestamp; } });
    await new Promise((r) => setTimeout(r, 1500));
    const b2 = await pc.getStats(); let by2 = 0, t2 = 0;
    b2.forEach((s) => { if (s.type === 'inbound-rtp' && s.kind === 'audio') { by2 = s.bytesReceived; t2 = s.timestamp; } });
    return {
      offerSdp: (pc && pc.remoteDescription && pc.remoteDescription.sdp) || '',
      answerSdp: (pc && pc.localDescription && pc.localDescription.sdp) || '',
      jitterBufferTarget: recv ? (recv.jitterBufferTarget ?? null) : null,
      bufferPref: localStorage.getItem('nudisco.buffer'),
      kbps: t2 > t1 ? Math.round((by2 - by1) * 8 / ((t2 - t1) / 1000) / 1000) : 0,
    };
  });
  // RED is a redundancy wrapper, not a distinct stats "codec" — verify it's the
  // negotiated PRIMARY payload type (red before opus) in both offer and answer.
  const redFirst = (sdp) => {
    const L = sdp.split(/\r\n/);
    const red = (L.find((l) => /^a=rtpmap:\d+ red\/48000/i.test(l)) || '').match(/a=rtpmap:(\d+)/);
    const opus = (L.find((l) => /^a=rtpmap:\d+ opus\/48000/i.test(l)) || '').match(/a=rtpmap:(\d+)/);
    const m = L.find((l) => l.startsWith('m=audio')) || '';
    if (!red || !opus || !m) return false;
    const pts = m.split(' ').slice(3);
    return pts.indexOf(red[1]) >= 0 && pts.indexOf(red[1]) < pts.indexOf(opus[1]);
  };
  ok('A: RED offered in SDP (red/48000)', /a=rtpmap:\d+ red\/48000/i.test(detail.offerSdp));
  ok('A: audio NACK enabled in SDP', /a=rtcp-fb:\d+ nack/i.test(detail.offerSdp));
  ok('A: RED negotiated as primary (offer + answer)', redFirst(detail.offerSdp) && redFirst(detail.answerSdp));
  ok('A: RED redundancy on the wire (~2x bitrate)', detail.kbps > 200, detail.kbps + ' kbps');
  ok('A: default jitterBufferTarget = 200ms (Smooth)', detail.jitterBufferTarget === 200, 'target=' + detail.jitterBufferTarget + ' pref=' + detail.bufferPref);

  // Toggle to Low latency → retunes the live buffer and persists.
  await la.select('#bufferSelect', 'low');
  const low = await la.evaluate(() => {
    const pc = (window.__pcs || []).slice(-1)[0];
    const recv = pc.getReceivers().find((r) => r.track && r.track.kind === 'audio');
    return { target: recv ? recv.jitterBufferTarget : null, pref: localStorage.getItem('nudisco.buffer') };
  });
  ok('A: toggle → Low retunes buffer to 40ms + persists', low.target === 40 && low.pref === 'low', JSON.stringify(low));
  await la.select('#bufferSelect', 'smooth');   // restore default

  console.log('\nListener B (LAN IP, plain http / insecure context — the phone case):');
  const lb = await newListener(browser, `${LAN}/`, 'B');
  ok('B: no "WebRTC blocked" warning over http', await lb.$eval('#warn', (e) => e.hidden));
  await joinAndPlay(lb, 'B');

  console.log('\nHouse Speaker (?house=1 on the Mac):');
  const hs = await newListener(browser, `${LOCAL}/?house=1`, 'house');
  await joinAndPlay(hs, 'house');
  ok('house: status says Routing to speakers', /Routing to speakers/i.test(await hs.$eval('#status', (e) => e.textContent)));

  console.log('\nBroadcaster view:');
  ok('broadcaster shows 3 listeners',
    (await waitFor('count=3', async () => (await dj.$eval('#count', (e) => e.textContent.trim())) === '3')));
  ok('broadcaster table shows connected peers',
    (await dj.$$eval('#listenerBody td.st-connected', (t) => t.length)) >= 1);

  console.log('\nReconnect:');
  await lb.close(); await hs.close();   // free CDP/WebRTC load before the reconnect check
  await sleep(500);
  await tap(la, '#reconnectBtn');
  const re = await waitFor('A reconnects', async () => {
    const m = await media(la);
    return m.connectionState === 'connected' && m.bytesReceived > 0 ? m : null;
  });
  ok('A reconnect re-establishes audio', re.bytesReceived > 0, JSON.stringify(re));
} catch (err) {
  fail++;
  console.error('\n\x1b[31mFATAL\x1b[0m', err.message);
} finally {
  if (fail > 0 && logs.length) { console.error('\n--- page logs (tail) ---\n' + logs.slice(-40).join('\n')); }
  await browser.close();
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
