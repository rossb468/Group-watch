# Group Watch

Watch a video with friends on different computers, in sync, and talk about
it while you watch. Everyone plays their own copy of the file; Group Watch
only syncs playback (under 50 ms apart), chat and reactions. No video is sent.

## Using it

1. Open a video (drag it onto the window).
2. Click **Invite**. The link is copied: paste it in a message.
3. Your friend clicks the link, opens their copy, and you're watching together.

Anyone can play, pause or seek. Keys: Space play/pause · ←/→ 5 s (⇧ 30 s) ·
↑/↓ volume · Return chat · 1–8 reactions · F full screen · M mute · S subtitles · A audio track.

## Layout

| Folder | What |
|---|---|
| `Core/` | `GroupWatchCore`, the platform-independent sync engine (Swift package, tested on Linux and macOS): clock sync, shared playback state, the player controller, the wire protocol. |
| `App/` | The Mac app. SwiftUI + AppKit, [libmpv](https://mpv.io) via MPVKit for playback (Metal, hardware decoding), Google's WebRTC for peer-to-peer data. |
| `Signaling/` | A Cloudflare Worker that introduces peers to each other. Nothing else goes through it. |
| `docs/PROTOCOL.md` | The protocol, for future Windows/Linux clients. |

## Building the Mac app

Needs Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
cd App
xcodegen generate
open GroupWatch.xcodeproj
```

Pick your team under Signing & Capabilities (or set `DEVELOPMENT_TEAM` in
`App/project.yml`), then Run.

## Running the server

One-time, on a free Cloudflare account:

```sh
cd Signaling
npm install
npx wrangler login
npm run deploy
```

Wrangler prints the server's URL (like `https://groupwatch.<you>.workers.dev`).
Put it in `GW_SIGNALING_URL` in `App/project.yml` and regenerate the project.

Optional, for the rare networks that block direct connections: create a TURN
key in the Cloudflare dashboard (Realtime → TURN), then
`npx wrangler secret put TURN_KEY_ID` and `npx wrangler secret put TURN_KEY_API_TOKEN`.

Local testing: `npm run dev`, then set the server to `http://127.0.0.1:8787` in
the app's Settings → Advanced.

## Tests

```sh
cd Core && swift test          # sync engine, simulated players and networks
cd Signaling && npm run dev &  # then:
npm test                       # signaling smoke test
```
