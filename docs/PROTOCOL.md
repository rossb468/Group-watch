# Group Watch protocol

Two layers: a tiny signaling server that only introduces peers, and a direct
peer-to-peer protocol that carries everything else. Any client on any
platform that speaks both can join a party.

## 1. Signaling (WebSocket)

`wss://<server>/room/<CODE>?peer=<PEER-ID>`

- `CODE`: 6 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`.
- `PEER-ID`: `[A-Za-z0-9-]{1,64}`, random per app launch. Reconnecting with
  the same ID replaces the old socket.

All messages are JSON objects with a `type`.

| Direction | Message | Meaning |
|---|---|---|
| server → client | `{"type":"welcome","self":id,"peers":[ids],"iceServers":[...]}` | You're in. `peers` are already here: **you call each of them** (send offers). `iceServers` is a WebRTC ICE server list (STUN, plus TURN when configured). |
| server → client | `{"type":"peer-joined","id":id}` | Someone arrived. They will call you. |
| server → client | `{"type":"peer-left","id":id}` | Their socket closed. Keep a working direct link anyway; tear down only when it fails. |
| both | `{"type":"signal","to":id,"data":{...}}` → `{"type":"signal","from":id,"data":{...}}` | Relayed WebRTC setup, see below. |
| server → client | `{"type":"error","reason":"room-full"}` | Room has 8 peers already. |
| client → server | `{"type":"ping"}` → `{"type":"pong"}` | Keepalive, every 20 s. |

Signal `data`:

```json
{"kind":"offer","sdp":"..."}
{"kind":"answer","sdp":"..."}
{"kind":"candidate","candidate":"...","sdpMid":"0","sdpMLineIndex":0}
```

Rules:
- A new arrival offers to everyone in `welcome.peers`. Existing peers wait.
- An offer for a peer you already have a link to replaces that link.
- Offer collision: the peer with the lexicographically smaller ID keeps its
  offer; the other drops its own and answers.
- When a direct link fails while both peers are still in the room, the peer
  with the smaller ID redials.

## 2. Peer link (WebRTC data channels)

Each pair of peers has one RTCPeerConnection with two **pre-negotiated** data
channels (`negotiated: true`, so neither side waits for the other to create them):

| id | label | config | carries |
|---|---|---|---|
| 0 | `control` | ordered, reliable | everything except clock pings |
| 1 | `clock` | unordered, `maxRetransmits: 0` | `ping`, `pong` |

Messages are UTF-8 JSON: `{"t": <type>, "v": <body>}`. Unknown types are ignored.
Times named `t*` and `referenceTime` are seconds on the **sender's monotonic
clock**. Dates are milliseconds since 1970.

| `t` | `v` | |
|---|---|---|
| `hello` | `{peerID, name, protocolVersion, appVersion, media?, state?}` | First message on a new link. `state` is omitted if the sender has never had a non-zero version. |
| `ping` | `{id, t0}` | Clock probe. |
| `pong` | `{id, t0, t1, t2, lead}` | `t1` = receive time, `t2` = send time (responder's clock). `lead` = seconds the responder needs to seek and be ready. |
| `state` | `PlaybackState` | The group's playback state changed. |
| `media` | `MediaInfo` or absent | The sender opened a different file. |
| `chat` | `{id, from, name, text, mediaTime, sentAt}` | |
| `reaction` | `{id, from, name, emoji, mediaTime}` | |

`MediaInfo`: `{fileName, fileSize, duration, fingerprint}`. `fingerprint` is
the first 16 bytes (hex) of SHA-256 over: file size as little-endian int64,
the first 4 MiB, and (for files over 8 MiB) the last 4 MiB.

### Playback state

```json
{"playing": true, "position": 1234.5, "referenceTime": 98765.432, "rate": 1,
 "version": {"counter": 17, "origin": "peer-id"}}
```

- Media position at time `t` is `position + (t - referenceTime) * rate` when
  playing and `t > referenceTime`, otherwise `position`.
- A playing state with `referenceTime` in the future means: sit paused on
  `position` and start at `referenceTime`. Play and seek use this so every
  peer starts on the same frame at the same instant.
- **Last writer wins** by `version`: higher `counter`, then higher `origin`
  string. A new local action uses `counter = (highest counter seen) + 1`.
  Version `{0, ""}` is "just opened a file" and loses to anything.
- States are sent to every peer directly (full mesh); late joiners get the
  current state in `hello`.

### Clocks

Each peer estimates `offset = remote − local` per peer NTP-style:
`offset = ((t1 − t0) + (t2 − t3)) / 2`, `rtt = (t3 − t0) − (t2 − t1)`, using
the lowest-RTT sample among the last 30. Pings go every 100 ms until 6 samples,
then every 2 s. A received state's `referenceTime` converts to the local clock
as `referenceTime − offset`; states that arrive before 3 samples are held until then.

### Keeping the player on target (each client, locally)

- Paused: pause and seek to `position` if more than 80 ms off.
- Scheduled start: pause on the start frame, unpause at the start time.
- Playing: average the last 12 position errors (cancels frame-quantization
  noise). Above 40 ms, scale speed by up to ±4% to close the gap over ~2 s;
  stop below 12 ms. Above 750 ms, or a new state more than 100 ms away,
  pause, seek to where the group will be after the measured seek time, and
  unpause at that moment.
