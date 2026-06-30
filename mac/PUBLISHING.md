# Publishing the nudisco macOS broadcaster

There are **two products** to ship, and they go through different channels:

| App | What it is | Best channel |
|---|---|---|
| **nudisco** (iOS, `ios/`) | the listener phones use | **App Store** — see [ios/APPSTORE.md](../ios/APPSTORE.md) |
| **nudisco Broadcaster** (macOS, this folder) | the DJ app | **Developer ID + notarized DMG** (recommended) — *not* the Mac App Store |

## Why Developer ID, not the Mac App Store, for the broadcaster
The Mac App Store **requires the App Sandbox**. This app does two things the sandbox
fights:
1. **Captures system audio** (Core Audio process taps). System-audio capture is the
   classic reason pro-audio apps (Audio Hijack, Loopback, etc.) ship **outside** the
   Mac App Store — sandbox + audio-capture review is fragile and may be rejected.
2. **Runs a small LAN server** (binds a port, accepts incoming connections from
   phones/browsers). Possible under sandbox with `com.apple.security.network.server`,
   but it's extra surface reviewers scrutinize.

So the pragmatic, reliable path is **Developer ID distribution**: a signed +
notarized DMG you host on a website. The build is already set up for this — the app
is intentionally **not sandboxed**, has Hardened Runtime on, and
`Distribution/notarize.sh` produces the DMG. Gatekeeper accepts it on any Mac.

You *can* still attempt the Mac App Store — see "If you really want the Mac App
Store" below — but expect sandbox/audio-capture friction.

## Developer ID release (recommended) — checklist
- [ ] Apple Developer Program account ($99/yr) — same one as the iOS app.
- [ ] A **Developer ID Application** certificate in your keychain.
- [ ] A notarytool credential profile:
      `xcrun notarytool store-credentials nudisco-notary --apple-id … --team-id … --password <app-specific>`
- [ ] Set `TEAM_ID` / `DEV_ID_APP` / `NOTARY_PROFILE` and run
      `./Distribution/notarize.sh` → produces `dist/nudisco-broadcaster.dmg`.
- [ ] Host the DMG for download (e.g. `enchante.events/nudisco`).
- [ ] First launch: the user allows **audio capture** + **Local Network** once.

That's the whole release. No App Review, no waiting.

## Shared / legal (needed either way) — same as the iOS app
- [ ] Fill the placeholders in [`PRIVACY.md`](../PRIVACY.md) and [`TERMS.md`](../TERMS.md):
      legal entity name, jurisdiction, support email (currently `support@enchante.events`).
- [ ] Host PRIVACY/TERMS at public URLs (the iOS App Store listing requires them).
- [ ] `package.json` says `"license": "MIT"` — confirm that's intended for a published
      product, or change to `UNLICENSED`.

## If you really want the Mac App Store (extra work, may be rejected)
1. Enable App Sandbox + entitlements in `Nudisco.entitlements`:
   `com.apple.security.app-sandbox`, `com.apple.security.network.server`,
   `com.apple.security.network.client`, keep `com.apple.security.device.audio-input`.
2. **Verify process taps actually work sandboxed** (test on device) — this is the
   make-or-break. If system-audio capture is blocked, MAS is not viable; stay on
   Developer ID.
3. Add a `PrivacyInfo.xcprivacy` (no tracking, no data collected) like the iOS app.
4. Switch signing to Apple Distribution / "3rd Party Mac Developer", archive, upload.
5. App Review notes: a reviewer **can** test solo — run the app, "go on air", open the
   join URL in Safari on the *same* Mac, hear audio. Explain the audio-capture prompt
   (we capture system output to rebroadcast on the LAN; nothing is recorded/stored).
6. Age rating 4+, "Data Not Collected" privacy label, screenshots, listing copy
   (reuse the iOS copy in `ios/APPSTORE.md`, adjusted for "the DJ app").

## Already handled in the project
- Hardened Runtime on; `NSAudioCaptureUsageDescription`, `NSLocalNetworkUsageDescription`,
  `ITSAppUsesNonExemptEncryption=false`, app icon, branded launch — all set in `project.yml`.
- The `Distribution/notarize.sh` universal build + sign + notarize + staple + DMG flow.
