"use strict";

/**
 * @sideline/link — the offline leg of a Sideline payment.
 *
 * A "stand" is a Hyperswarm topic derived from a human room code
 * (printed on the vendor's stall, shouted down the row). Fan and
 * vendor join the same stand and vouchers travel peer-to-peer over
 * the swarm — on match day that's a hotspot or LAN with no WAN.
 *
 * The link also carries double-spend gossip: every peer announces the
 * voucher IDs it has accepted, so a buyer trying to hand the same
 * voucher to two stalls gets flagged inside the venue within seconds,
 * long before settlement.
 */

const Hyperswarm = require("hyperswarm");
const DHT = require("hyperdht");
const crypto = require("crypto");
const b4a = require("b4a");

const TOPIC_NS = "sideline/stand/v1/";

function standTopic(code) {
  return crypto.createHash("sha256").update(TOPIC_NS + code.trim().toLowerCase()).digest();
}

class SidelineLink {
  /**
   * @param {object} [opts]
   * @param {Array}  [opts.bootstrap] DHT bootstrap nodes. On a WAN-less
   *   LAN, point every device at one peer running `SidelineLink.bootstrapper`.
   */
  constructor(opts = {}) {
    // Venue mode (explicit bootstrap, e.g. one device on a WAN-less
    // hotspot): loopback/LAN addresses classify as firewalled, which
    // blocks topic announces — so pin firewalled:false, ephemeral:false
    // the way hyperdht's own testnet does. With no bootstrap given,
    // fall back to the public swarm.
    this.swarm = opts.bootstrap
      ? new Hyperswarm({ dht: new DHT({ bootstrap: opts.bootstrap, firewalled: false, ephemeral: false }) })
      : new Hyperswarm();
    this.name = opts.name || null; // how this peer introduces itself (a stall name)
    this.seen = new Map(); // voucher id → first-seen unix seconds
    this.handlers = { voucher: [], seen: [], peer: [] };
    this._conns = new Set();

    this.swarm.on("connection", (conn) => {
      this._conns.add(conn);
      conn.peerName = null;
      conn.on("close", () => this._conns.delete(conn));
      conn.on("error", () => {});
      let buffer = "";
      conn.on("data", (chunk) => {
        buffer += b4a.toString(chunk);
        let nl;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, nl);
          buffer = buffer.slice(nl + 1);
          this._onMessage(line, conn);
        }
      });
      conn.write(JSON.stringify({ type: "hello", name: this.name }) + "\n");
      this._emit("peer", { count: this._conns.size });
      // brief the newcomer on every voucher this side has seen
      for (const [id, at] of this.seen) {
        conn.write(JSON.stringify({ type: "seen", id, at }) + "\n");
      }
    });
  }

  /** Run a tiny DHT bootstrap node so a venue works with zero WAN. */
  static async bootstrapper(port = 49737, host = "127.0.0.1") {
    const DHT = require("hyperdht");
    const node = DHT.bootstrapper(port, host);
    await node.ready();
    return node;
  }

  on(event, fn) {
    this.handlers[event].push(fn);
  }

  _emit(event, data) {
    for (const fn of this.handlers[event]) fn(data);
  }

  async joinStand(code) {
    const discovery = this.swarm.join(standTopic(code), { server: true, client: true });
    await discovery.flushed(); // announced to the DHT
    await this.swarm.flush(); // pending peer connections completed
  }

  get peerCount() {
    return this._conns.size;
  }

  /** Stalls visible at this stand (named peers). */
  get stalls() {
    return [...this._conns].map((c) => c.peerName).filter(Boolean);
  }

  /**
   * Hand a voucher over. A payment is addressed to one stall (`to`);
   * an unaddressed send goes to every peer (useful for testing the
   * gossip, not how you pay for a pie).
   */
  sendVoucher(wire, to = null) {
    const msg = JSON.stringify({ type: "voucher", wire }) + "\n";
    let delivered = 0;
    for (const conn of this._conns) {
      if (to == null || conn.peerName === to) {
        conn.write(msg);
        delivered++;
      }
    }
    return delivered;
  }

  /** Announce that a voucher ID has been accepted here (double-spend gossip). */
  announceSeen(id) {
    if (this.seen.has(id)) return;
    this.seen.set(id, Math.floor(Date.now() / 1000));
    this._broadcast({ type: "seen", id, at: this.seen.get(id) });
  }

  /** Has anyone at this stand already accepted this voucher? */
  isSeen(id) {
    return this.seen.has(id);
  }

  _broadcast(msg) {
    const line = JSON.stringify(msg) + "\n";
    for (const conn of this._conns) conn.write(line);
  }

  _onMessage(line, from) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return; // not ours
    }
    if (msg.type === "hello") {
      from.peerName = typeof msg.name === "string" ? msg.name : null;
      this._emit("peer", { count: this._conns.size });
    } else if (msg.type === "voucher" && typeof msg.wire === "string") {
      this._emit("voucher", { wire: msg.wire });
    } else if (msg.type === "seen" && typeof msg.id === "string") {
      const fresh = !this.seen.has(msg.id);
      if (fresh) {
        this.seen.set(msg.id, msg.at || Math.floor(Date.now() / 1000));
        this._broadcast({ type: "seen", id: msg.id, at: this.seen.get(msg.id) }); // re-gossip
        this._emit("seen", { id: msg.id });
      }
    }
  }

  async destroy() {
    await this.swarm.destroy();
  }
}

module.exports = { SidelineLink, standTopic };
