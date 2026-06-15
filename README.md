# nudisco 🎧

A local-network **silent disco** for a home party. You DJ on a Mac; guests listen
on their phones' earphones by opening a URL — **no app to install**. Built for a
**hybrid** setup where real speakers also play in the room, so phone audio is
tuned to line up with the speakers as closely as possible.

- One **broadcaster** (your Mac) → many **listeners** (phones) over a WebRTC
  **mesh** (a peer connection per listener). Sized for ~5–15 listeners.
- **LAN-only**: uses host ICE candidates (your devices' Wi-Fi addresses). No
  STUN, no TURN, nothing leaves your network.
- **Opus, stereo, ~160 kbps**, tuned for low and consistent latency.
- Shows the **measured/estimated latency** so you can delay your room speakers to
  match — or use the built-in **House Speaker mode** so the speakers ride the
  same delay automatically.
- Minimal dependencies: Node + [`ws`](https://www.npmjs.com/package/ws) +
  [`qrcode`](https://www.npmjs.com/package/qrcode). No build toolchain, vanilla
  JS on the client.

---

## 1. Quick start

```bash
npm install
npm start
```

You'll see something like:

```
  nudisco  silent-disco server  (HTTP)
  ──────────────────────────────────────────────────────
  DJ / broadcaster (this Mac):  http://localhost:3000/broadcast
  Listeners (phones):           http://192.168.1.50:3000/
  House Speaker (this Mac):      http://localhost:3000/?house=1
  ──────────────────────────────────────────────────────
```

1. On the **Mac**, open **`http://localhost:3000/broadcast`**.
2. Click **Enable & list audio inputs**, choose **BlackHole 2ch**, click **Start
   broadcasting**.
3. **Guests** scan the QR (or type the `192.168.x.x` URL) on their phones, tap
   **Tap to Join**, and listen on **wired earphones**.

> Change the port with `PORT=8080 npm start` or `npm start -- --port 8080`.

---

## 2. Audio routing on the Mac (BlackHole)

Guests' phones can only play what the Mac is **capturing**. We capture from a
virtual audio device so your DJ software's master output reaches the broadcaster.

### Install BlackHole (2ch)

```bash
brew install blackhole-2ch
```

(or download from <https://existential.audio/blackhole/>). Reboot or log out/in
if the device doesn't appear immediately.

You then have **two routing options**. Pick one.

### Option 1 — BlackHole only + House Speaker mode (recommended for tight sync)

DJ master out → **BlackHole** (nothing else). Drive the room speakers from this
app's **House Speaker mode**, so the speakers pass through the *same* WebRTC delay
as the phones and stay roughly in sync — **no manual delay math**.

- **DJ app master/output device:** `BlackHole 2ch`.
- **Cue / monitor / headphones:** keep on the **DDJ-FLX 4 headphone output** for
  beatmatching. That path is the controller's own analog monitor and stays
  **instant** — it never goes through BlackHole or the network.
- **Room speakers:** on the Mac, open **House Speaker mode**
  (`http://localhost:3000/?house=1`, there's a link on the broadcast page),
  tap **Join**, and in the **Output** picker choose your **speakers / audio
  interface** (NOT BlackHole — that would loop back). The speakers now play the
  delayed stream, matching the phones.

```
DJ app ─master─▶ BlackHole 2ch ─▶ nudisco broadcaster ─▶ phones (delayed)
                                                       └▶ House Speaker tab ─▶ room speakers (same delay)
DDJ-FLX 4 ─headphone out─▶ your cue headphones (instant, for beatmatching)
```

> House Speaker rides the LAN without the phones' *wireless* hop, so it's a few ms
> tighter than the phones — close, not sample-perfect. Use the per-listener
> latency table to sanity-check.

### Option 2 — Multi-Output Device (instant speakers, manual delay)

DJ master out → a macOS **Multi-Output Device** that contains **BlackHole 2ch +
your speakers**. Speakers play **instantly**; phones lag by the displayed
latency, so you'll hear an **echo** between room and phones unless you add a
matching delay to the speaker path.

Create a Multi-Output Device:

1. Open **Audio MIDI Setup** (`/Applications/Utilities/`).
2. Click **+** ▸ **Create Multi-Output Device**.
3. Tick **BlackHole 2ch** and your speakers/interface. Set your speakers as the
   **Primary** ("Master Device"), and enable **Drift Correction** on BlackHole.
4. In your DJ app, set the master/output to this **Multi-Output Device**.

To remove the echo you must delay the **speaker** path by the latency the
broadcast page shows (the big **recommended room-speaker delay** number). macOS
can't delay one route of a Multi-Output Device on its own, so use a paid tool:

- **[Rogue Amoeba Loopback](https://rogueamoeba.com/loopback/)** — build a device
  with a per-source delay on the speaker branch.
- **[Rogue Amoeba Audio Hijack](https://rogueamoeba.com/audiohijack/)** — insert a
  **Delay** block before the speaker output.

Set that delay to the displayed latency (e.g. `~120 ms`), then fine-tune by ear
until the room and a phone are in phase. Re-check during the night — Wi-Fi
latency drifts; **Option 1 avoids all of this.**

### DJ software output settings (generic)

- **rekordbox:** *Preferences ▸ Audio ▸ Audio* → set **Output channels / Audio**
  device to `BlackHole 2ch` (Option 1) or your **Multi-Output Device** (Option
  2). Keep the **DDJ-FLX 4** assigned for **headphones/cue**. Sample rate 48 kHz.
- **Serato DJ:** *Setup ▸ Audio* → with the DDJ-FLX 4 connected, Serato routes
  master to the controller by default. To send master into BlackHole, set the
  **system/aggregate output** appropriately or use Serato's audio routing; keep
  **Cue** on the DDJ-FLX 4 headphone jack. (If Serato locks you to the
  controller's outputs, Option 1's House Speaker mode is the cleanest path: send
  master to BlackHole via a Multi-Output/aggregate that includes the controller
  only for cueing.)
- **Any app:** the rule is — **master → BlackHole**, **cue/monitor → DDJ-FLX 4
  headphone out**, sample rate **48 kHz**, and **disable** any "sound
  enhancer"/normalization.

---

## 3. Find your LAN IP & share the link

The server prints the listener URL on startup. To find it manually:

```bash
ipconfig getifaddr en0     # Wi-Fi on most Macs
ipconfig getifaddr en1     # try this if en0 is empty
```

Share **`http://<that-ip>:3000/`**. The broadcast page shows this URL, a **copy**
button, and a **QR code** — easiest is to have guests **scan the QR**.

Everyone (Mac + phones) must be on the **same Wi-Fi network**.

---

## 4. Latency & speaker sync

- Each phone continuously **estimates its end-to-end latency** (one-way network +
  jitter buffer + a fixed pipeline constant) and shows it on its own screen.
- The **broadcast page** collects all phones and shows a **recommended
  room-speaker delay** = the **median** phone latency, plus a per-listener table
  (state / latency / network RTT / buffer). House Speaker outputs are **excluded**
  from the median and tagged `house`.
- Use that number for **Option 2**'s speaker delay. For **Option 1** you don't
  need it — the speakers already share the delay.

### Smoothness vs latency (the buffer)

Each listener page has a **Buffer** control — **Smooth / Balanced / Low latency** —
that sizes the jitter buffer (how much audio the phone holds before playing):

| Preset | Buffer | Use when |
|---|---|---|
| **Smooth** (default) | ~200 ms | Default. Choppiness is worse than a little extra delay. |
| **Balanced** | ~120 ms | Good Wi-Fi, want it tighter. |
| **Low latency** | ~40 ms | Excellent Wi-Fi only; risks dropouts. |

The choice is saved per phone. A bigger buffer just raises the displayed latency
(so the room-speaker delay you set goes up) — it does **not** desync anything,
because House Speaker mode shares the same buffer.

**Loss resilience is on by default** so phones stay smooth on real-world Wi-Fi:
Opus **in-band FEC**, **RED** (sends a redundant copy of recent audio, so a single
lost packet rarely causes a gap), and **audio NACK** (the phone re-requests lost
packets — cheap on a LAN). RED roughly doubles audio bandwidth (~250–320 kbps per
phone), which is fine on a home network. iOS Safari ignores the JS buffer knobs but
still benefits from FEC/RED/NACK and its own adaptive buffer.

**Tuning knobs** live in `public/js/rtc-common.js`:

| Constant | Default | Effect |
|---|---|---|
| `BUFFER_PRESETS` | smooth/balanced/low | Per-preset `playoutDelayHint` (s) + `jitterBufferTarget` (ms) |
| `DEFAULT_BUFFER` | `'smooth'` | Which preset new listeners start on |
| `AUDIO.bitrate` | `160000` | Opus base bitrate (RED ~doubles on the wire) |
| `AUDIO.fec` | `true` | Opus in-band FEC |
| `PIPELINE_CONST_MS` | `48` ms | Fixed pipeline + phone-output overhead added to the estimate (errs low) |

To make every phone smoother by default, raise the `smooth` preset's
`jitterBufferTarget`/`playoutDelayHint`; to chase lower latency on great Wi-Fi,
lower them (or tell guests to pick **Low latency**).

> **Use WIRED earphones.** Bluetooth earbuds add **100–200 ms** of their own
> latency that nudisco can't see or compensate for — they'll be out of sync with
> the room no matter what.

---

## 5. HTTPS mode (only if a phone refuses plain http)

Listeners only **receive** audio (no microphone), so plain **http** on the LAN
usually works. Some mobile browsers, though, gate WebRTC behind a *secure
context*. If a phone shows the "browser is blocking WebRTC" warning, switch to
HTTPS:

```bash
npm run gen-cert            # self-signed cert for your LAN IP (auto-detected)
npm run start:https         # serves on https (default port 8443)
```

Then guests open **`https://<lan-ip>:8443/`** and **trust the self-signed cert**:

- **iPhone/iPad (Safari):**
  1. Open the `https://` URL → tap **Show Details ▸ visit this website** to load
     it once. For full trust, email/AirDrop `certs/cert.pem` to the phone, open
     it, **Settings ▸ Profile Downloaded ▸ Install**.
  2. **Settings ▸ General ▸ About ▸ Certificate Trust Settings** → toggle the
     `nudisco-…` cert **ON**.
- **Android (Chrome):** open the URL and accept the warning
  (**Advanced ▸ Proceed**). For some versions you may need to install
  `certs/cert.pem` via **Settings ▸ Security ▸ Install a certificate ▸ CA
  certificate**.

The broadcaster page itself works on `http://localhost` either way (localhost is
already a secure context for `getUserMedia`).

---

## 6. Troubleshooting

**A phone connects but there's no sound.**
Tap the screen (mobile autoplay needs a gesture). If you see **"Tap to resume
audio"**, tap it — iOS pauses audio when Safari is backgrounded or interrupted by
a call/notification. Keep the tab in the foreground.

**The volume slider does nothing on iPhone.**
iOS ignores in-page volume for web audio. Use the phone's **hardware volume
buttons** (the page tells guests this).

**"This browser is blocking WebRTC here."**
The browser wants a secure context. Use **HTTPS mode** (section 5).

**Guests can't reach the URL at all.**
- Confirm they're on the **same Wi-Fi** (not a guest VLAN / 5 GHz-vs-2.4 GHz
  split that isolates clients).
- Many routers have **"AP/client isolation"** or **"guest network"** that blocks
  device-to-device traffic — turn it off for the party, or use your main SSID.
- Check the IP is current: `ipconfig getifaddr en0`. DHCP may have changed it.
- macOS firewall: **System Settings ▸ Network ▸ Firewall** — allow incoming
  connections for `node` if prompted.

**Audio is choppy / drops out / crackles.**
- First: on the phone, set the **Buffer** control to **Smooth** (it's the default,
  but a guest may have changed it). That alone fixes most choppiness.
- Wi-Fi is the usual cause. Prefer **5 GHz** for phones near the AP, put the router
  near the room, and cut other heavy traffic (big downloads, video calls). Fewer
  competing devices on the AP = fewer dropouts.
- **Wired earphones**, not Bluetooth — BT adds latency *and* its own dropouts.
- FEC + RED + audio NACK are already on (loss resilience). To push smoothness
  globally, raise the `smooth` preset in `public/js/rtc-common.js` (section 4).
- If only **one** phone is bad, check its Wi-Fi signal / move it closer; the
  broadcaster's per-listener table shows that phone's RTT and buffer.

**Echo between room speakers and phones.**
You're on **Option 2** without a matching speaker delay. Either add the displayed
delay to the speaker path (Loopback/Audio Hijack), or switch to **Option 1**
(House Speaker mode) and feed the speakers from the app.

**The level meter on the broadcast page is flat.**
Your DJ app isn't sending master into BlackHole. Re-check section 2 routing and
that you selected **BlackHole 2ch** as the input on the broadcast page.

**House Speaker plays into BlackHole and feeds back / echoes.**
In House Speaker mode's **Output** picker, choose your **speakers/interface**, not
BlackHole.

**CPU spikes / glitches with many listeners.**
The mesh encodes once per listener. Beyond ~15, swap in an SFU (see below).

---

## 7. Project layout & swapping in an SFU later

```
nudisco/
├─ src/
│  ├─ server.js        # static files + /api/info + /qr.svg + WebSocket at /ws
│  └─ signaling.js     # relays offer/answer/ICE between broadcaster & listeners
├─ public/
│  ├─ index.html       # listener page  (served at /)
│  ├─ broadcast.html   # broadcaster page (served at /broadcast)
│  ├─ css/style.css
│  └─ js/
│     ├─ rtc-common.js       # shared config + SDP munging + Signal client
│     ├─ mesh-broadcaster.js # ← the swappable broadcast layer (mesh today)
│     ├─ broadcast.js        # broadcaster UI
│     └─ listener.js         # listener UI
├─ scripts/gen-cert.sh
└─ package.json
```

**Swapping the broadcast layer:** `public/js/mesh-broadcaster.js` is isolated
behind a small interface (`addListener`, `removeListener`, `count`,
`getPeerStats`, `stop`, and it wires itself to the `listener-joined` /
`listener-left` / `signal` events). To move to a **mediasoup SFU**, write an
`SfuBroadcaster` with the same surface: publish one stream to the SFU instead of
N peer connections, and have listeners consume from it. The signaling protocol
(`hello` / `welcome` / `signal` / `stats`) and the rest of the UI stay the same.
**Not included now** to keep dependencies minimal.

---

## 8. Run reference

| Command | What |
|---|---|
| `npm start` | HTTP on port 3000 (LAN) |
| `npm start -- --port 8080` | choose a port |
| `npm run gen-cert` | make a self-signed cert for your LAN IP |
| `npm run start:https` | HTTPS on port 8443 (needs the cert) |
| `npm test` | smoke test: boots the server + exercises HTTP + signaling |
| `npm run test:e2e` | full browser test — real WebRTC audio, DJ→listener (needs Google Chrome) |
| `PORT=80 npm start` | port via env var (80 may need `sudo`) |

URLs: broadcaster `…/broadcast` · listener `…/` · House Speaker `…/?house=1`.
