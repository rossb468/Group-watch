// Smoke test against a running `wrangler dev` (default http://127.0.0.1:8787).
import WebSocket from "ws";
import assert from "node:assert/strict";

const base = process.env.BASE ?? "http://127.0.0.1:8787";
const wsBase = base.replace(/^http/, "ws");

function connect(peer, code = "ABCDEF") {
  const ws = new WebSocket(`${wsBase}/room/${code}?peer=${peer}`);
  const inbox = [];
  const waiters = [];
  ws.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());
    const i = waiters.findIndex((w) => w.match(msg));
    if (i >= 0) waiters.splice(i, 1)[0].resolve(msg);
    else inbox.push(msg);
  });
  const next = (type, timeout = 3000) => {
    const i = inbox.findIndex((m) => m.type === type);
    if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
    return new Promise((resolve, reject) => {
      waiters.push({ match: (m) => m.type === type, resolve });
      setTimeout(() => reject(new Error(`${peer}: timed out waiting for ${type}`)), timeout);
    });
  };
  const opened = new Promise((r, j) => { ws.on("open", r); ws.on("error", j); });
  return { ws, next, opened, send: (m) => ws.send(JSON.stringify(m)) };
}

const a = connect("peer-a");
await a.opened;
const wa = await a.next("welcome");
assert.deepEqual(wa.peers, []);
assert.ok(wa.iceServers.length > 0);

const b = connect("peer-b");
await b.opened;
const wb = await b.next("welcome");
assert.deepEqual(wb.peers, ["peer-a"]);
assert.equal((await a.next("peer-joined")).id, "peer-b");

b.send({ type: "signal", to: "peer-a", data: { sdp: "offer" } });
const sig = await a.next("signal");
assert.equal(sig.from, "peer-b");
assert.deepEqual(sig.data, { sdp: "offer" });

a.send({ type: "ping" });
await a.next("pong");

// Reconnect of b replaces the old socket; a sees a fresh join, not a leave.
const b2 = connect("peer-b");
await b2.opened;
assert.deepEqual((await b2.next("welcome")).peers, ["peer-a"]);
assert.equal((await a.next("peer-joined")).id, "peer-b");

b2.ws.close();
assert.equal((await a.next("peer-left")).id, "peer-b");

const page = await fetch(`${base}/j/abc-def`);
assert.equal(page.status, 200);
assert.match(await page.text(), /groupwatch:\/\/join\/ABCDEF/);
assert.equal((await fetch(`${base}/room/nope`)).status, 400);

a.ws.close();
console.log("signaling smoke test passed");
process.exit(0);
