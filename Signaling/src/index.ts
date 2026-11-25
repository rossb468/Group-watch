// Group Watch signaling server.
//
// Peers in a room find each other here and swap WebRTC offers, answers and
// ICE candidates. No video, chat or voice passes through: once peers are
// connected, everything flows directly between them.
//
//   GET /room/:code?peer=:id   WebSocket. One Durable Object per room.
//   GET /j/:code               Join page: opens the app via groupwatch://join/:code
//
// Messages (JSON, both directions) are documented in docs/PROTOCOL.md.

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOMS: DurableObjectNamespace<Room>;
  DOWNLOAD_URL?: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const CODE_LENGTH = 6;
const MAX_PEERS = 8;
const MAX_MESSAGE_BYTES = 64 * 1024;
const PEER_ID = /^[A-Za-z0-9-]{1,64}$/;

type IceServer = { urls: string | string[]; username?: string; credential?: string };

const STUN: IceServer[] = [{ urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] }];

export function normalizeCode(raw: string): string | null {
  const code = raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (code.length !== CODE_LENGTH) return null;
  for (const c of code) if (!CODE_ALPHABET.includes(c)) return null;
  return code;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const [route, rawCode] = url.pathname.split("/").filter(Boolean);

    if (route === "room" && rawCode) {
      const code = normalizeCode(rawCode);
      if (!code) return new Response("bad room code", { status: 400 });
      if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
        return new Response("expected websocket", { status: 426 });
      }
      const room = env.ROOMS.get(env.ROOMS.idFromName(code));
      return room.fetch(request);
    }

    if (route === "j" && rawCode) {
      const code = normalizeCode(rawCode);
      if (!code) return new Response("That link doesn't look right.", { status: 404 });
      return html(joinPage(code, env.DOWNLOAD_URL ?? ""));
    }

    if (route === "health") return new Response("ok");

    return html(page("Group Watch", `<h1>Group Watch</h1><p>Watch videos together, in sync.</p>`));
  },
} satisfies ExportedHandler<Env>;

type Attachment = { peerId: string };

export class Room extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keepalives are answered without waking the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const peerId = url.searchParams.get("peer") ?? "";
    if (!PEER_ID.test(peerId)) return new Response("bad peer id", { status: 400 });

    // A reconnect from the same peer replaces its old socket.
    for (const old of this.ctx.getWebSockets(peerId)) {
      try { old.close(4000, "replaced"); } catch {}
    }

    const others = this.ctx.getWebSockets().filter((ws) => this.peerOf(ws) !== peerId && ws.readyState === WebSocket.READY_STATE_OPEN);
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [peerId]);
    server.serializeAttachment({ peerId } satisfies Attachment);

    if (others.length >= MAX_PEERS) {
      server.send(JSON.stringify({ type: "error", reason: "room-full" }));
      server.close(4001, "room full");
      return new Response(null, { status: 101, webSocket: client });
    }

    server.send(JSON.stringify({
      type: "welcome",
      self: peerId,
      peers: others.map((ws) => this.peerOf(ws)),
      iceServers: await this.iceServers(),
    }));
    for (const ws of others) this.send(ws, { type: "peer-joined", id: peerId });

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string" || message.length > MAX_MESSAGE_BYTES) return;
    let msg: { type?: string; to?: string; data?: unknown };
    try { msg = JSON.parse(message); } catch { return; }

    if (msg.type === "signal" && typeof msg.to === "string") {
      const from = this.peerOf(ws);
      for (const target of this.ctx.getWebSockets(msg.to)) {
        this.send(target, { type: "signal", from, data: msg.data });
      }
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.leave(ws);
    try { ws.close(code, reason); } catch {}
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.leave(ws);
  }

  private leave(ws: WebSocket) {
    const peerId = this.peerOf(ws);
    // Replaced by a newer socket from the same peer: not a departure.
    if (this.ctx.getWebSockets(peerId).some((other) => other !== ws && other.readyState === WebSocket.READY_STATE_OPEN)) return;
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws) this.send(other, { type: "peer-left", id: peerId });
    }
  }

  private peerOf(ws: WebSocket): string {
    return (ws.deserializeAttachment() as Attachment | null)?.peerId ?? "";
  }

  private send(ws: WebSocket, msg: unknown) {
    try { ws.send(JSON.stringify(msg)); } catch {}
  }

  /// STUN always; TURN relay credentials too when a Cloudflare TURN key is configured.
  private async iceServers(): Promise<IceServer[]> {
    const { TURN_KEY_ID: keyId, TURN_KEY_API_TOKEN: token } = this.env;
    if (!keyId || !token) return STUN;
    try {
      const response = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ ttl: 86400 }),
        },
      );
      if (!response.ok) return STUN;
      const body = (await response.json()) as { iceServers?: IceServer | IceServer[] };
      const turn = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : [];
      return turn.length ? turn : STUN;
    } catch {
      return STUN;
    }
  }
}

function html(body: string): Response {
  return new Response(body, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}

function page(title: string, content: string, head = ""): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>${head}
<style>
:root{color-scheme:light dark;--bg:#f5f5f7;--fg:#1d1d1f;--muted:#6e6e73;--accent:#0a84ff;--card:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f5f5f7;--muted:#98989d;--card:#1c1c1e}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);
font:17px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;padding:16px;box-sizing:border-box}
main{background:var(--card);border-radius:20px;padding:40px 32px;max-width:420px;width:100%;text-align:center;box-sizing:border-box}
h1{font-size:28px;margin:0 0 8px}p{color:var(--muted);margin:8px 0}
.code{font:600 40px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:4px;margin:24px 0}
a.button{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;padding:12px 28px;border-radius:12px;font-weight:600;margin-top:8px}
a.subtle{color:var(--accent);text-decoration:none}
</style></head><body><main>${content}</main></body></html>`;
}

function joinPage(code: string, downloadURL: string): string {
  const display = `${code.slice(0, 3)}-${code.slice(3)}`;
  const appURL = `groupwatch://join/${code}`;
  const download = downloadURL
    ? `<p style="margin-top:24px">Don't have Group Watch? <a class="subtle" href="${downloadURL}">Download it</a></p>`
    : "";
  return page(
    "Join Group Watch",
    `<h1>You're invited to watch</h1>
<p>Opening Group Watch…</p>
<div class="code">${display}</div>
<a class="button" href="${appURL}">Open Group Watch</a>
${download}`,
    `<script>setTimeout(function(){location.href=${JSON.stringify(appURL)}},150)</script>`,
  );
}
