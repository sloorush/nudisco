# Publishing nudisco to the App Store / TestFlight

Everything to fill into **App Store Connect**, plus the two things that trip up
this specific app (it's LAN-only, and it asks for the mic). Build/signing steps
are in [README.md](README.md); this file is the store/legal side.

## Already handled in the project
- **Privacy manifest** — `Nudisco/PrivacyInfo.xcprivacy` (no tracking, no data
  collected, declares the UserDefaults required-reason API). Required since 2024.
- **Export compliance** — `ITSAppUsesNonExemptEncryption: false` in `project.yml`
  (only standard TLS / DTLS-SRTP). No annual self-classification prompt.
- **Permission strings** — Local Network, Microphone, Camera, all set with honest
  descriptions.

## Required URLs (host these first)
App Store Connect requires public URLs. Host the repo's `PRIVACY.md` and
`TERMS.md` somewhere (e.g. on enchante.events or GitHub Pages):
- **Privacy Policy URL** — required. e.g. `https://enchante.events/nudisco/privacy`
- **Support URL** — required. e.g. `https://enchante.events/nudisco` or a mailto page
- **Marketing URL** — optional. `https://enchante.events`

## App privacy "nutrition label" (App Store Connect ▸ App Privacy)
Answer **"Data Not Collected."** Walk-through:
- "Do you or your third-party partners collect data from this app?" → **No.**
That's it — no data types to declare. (Matches `PrivacyInfo.xcprivacy`.)

## Age rating
**4+** — no objectionable content in the app itself. (The app only receives the
DJ's audio; per the Terms, content responsibility is the DJ's.)

## Listing copy (draft — edit to taste)
- **Name:** `nudisco` (must be unique on the App Store; if taken, e.g.
  `nudisco by enchante`)
- **Subtitle (30 chars):** `silent disco for your party`
- **Promotional text:** `Tap in. Same Wi-Fi, no account, earphones on — the room goes quiet, the party doesn't.`
- **Keywords (100 chars):** `silent disco,headphone party,dj,wifi audio,enchante,live audio,broadcast,low latency`
- **Description:**
  ```
  nudisco turns any room into a silent disco. The DJ broadcasts from their
  computer over your Wi-Fi; you put in your earphones, tap to join, and listen —
  in sync with everyone else and with the room speakers. No account, no sign-up,
  nothing leaves your local network. Lock your phone and the music keeps playing.

  • Tap to join — scan a QR or enter the address the DJ shows
  • Plays with the screen locked, with lock-screen controls
  • Smooth / Balanced / Low-latency buffer to match your Wi-Fi
  • Private by design: peer-to-peer on your LAN, no servers, no tracking

  nudisco needs a DJ running the nudisco broadcaster on the same Wi-Fi.

  by enchante
  ```

## App Review notes (IMPORTANT — paste into "Notes for Review")
This is the make-or-break field. The reviewer has **no nudisco broadcaster on
their network**, so without help the app just sits on "waiting for the DJ" and
gets rejected under Guideline 2.1 (App Completeness). Give them a way to test:

> nudisco is a LAN silent-disco receiver: it connects to a "broadcaster" running
> on a computer on the SAME Wi-Fi and plays its audio. To review end-to-end we
> have a temporary public broadcaster running:
>
>   Address to enter in the app: `<HOST:PORT you expose for review>`
>   (or scan the QR at `<a URL showing the QR>`)
>
> Steps: open the app → "scan QR to join" or tap the address field, enter the
> address above → Allow Local Network and Microphone when prompted → audio plays.
>
> Microphone: the app is RECEIVE-ONLY and never records or transmits audio. iOS
> requires the microphone permission only because the WebRTC audio engine
> initializes the shared audio unit; no microphone data is captured or sent.

To expose a broadcaster for review, run the server on a reachable host (a small
cloud VM, or your Mac via a tunnel like Tailscale/ngrok) for the review window and
put its `host:port` above. (Internal TestFlight needs none of this — see below.)

## Screenshots (required)
Capture on a real device or simulator at the required sizes (at minimum a 6.7"/6.9"
iPhone; add 5.5" if supported). Good shots: the **join screen** ("tap to join"
lockup) and a **connected screen** (latency + buffer). The brand yellow reads great.

## Fastest path: Internal TestFlight (no review)
For a private party, skip App Review entirely: App Store Connect ▸ TestFlight ▸
**Internal Testing** ▸ add your guests as Users (up to 100) ▸ assign the build.
No Beta App Review, no demo server needed. External (public link) is the part that
needs Beta App Review + the demo-broadcaster notes above.

## Pre-submit checklist
- [ ] `xcodegen generate`, Team set, archive uploads cleanly
- [ ] App icon shows (yellow loop) and launch screen is branded
- [ ] Privacy Policy + Support URLs live and entered
- [ ] App Privacy = "Data Not Collected"
- [ ] Notes for Review include the demo address + mic explanation
- [ ] Screenshots uploaded
- [ ] (If Apple flags extra required-reason APIs from the WebRTC framework, add
      them to `PrivacyInfo.xcprivacy` or update the `stasel/WebRTC` package.)
