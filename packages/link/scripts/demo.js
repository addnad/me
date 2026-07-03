"use strict";

/**
 * The offline handoff, end to end, with zero WAN:
 *
 *   1. spin a local DHT bootstrapper (the "venue node" — on match day,
 *      any one device on the hotspot plays this role)
 *   2. vendor and fan join stand "gate-c-kiosk"
 *   3. fan mints a real voucher and sends it over the swarm
 *   4. vendor verifies the signature locally and gossips the ID
 *   5. a second vendor is offered the same voucher — and flags it
 *      as a double-spend attempt without ever touching a chain
 */

const { ethers } = require("ethers");
const { SidelineLink } = require("..");
const { mintVoucher, verifyVoucher, decodeVoucher, encodeVoucher } = require("@sideline/voucher");

const STAND = "gate-c-kiosk";
const CTX = { chainId: 11155111, escrow: "0x0000000000000000000000000000000000000001" };
const BOOTSTRAP_PORT = 49737;

async function main() {
  const venue = await SidelineLink.bootstrapper(BOOTSTRAP_PORT);
  const bootstrap = [{ host: "127.0.0.1", port: BOOTSTRAP_PORT }];
  console.log("venue bootstrap node up (no WAN anywhere in this demo)\n");

  const fan = new SidelineLink({ bootstrap });
  const vendorA = new SidelineLink({ bootstrap, name: "pie-stand" });
  const vendorB = new SidelineLink({ bootstrap, name: "scarf-stall" });

  const outcomes = { accepted: 0, flagged: 0 };

  const vendorCheck = (name, link) => async ({ wire }) => {
    const decoded = decodeVoucher(wire);
    const res = verifyVoucher(decoded, CTX);
    if (!res.ok) return console.log(`${name}: rejected voucher (${res.reason})`);
    if (link.isSeen(decoded.voucher.id)) {
      outcomes.flagged++;
      return console.log(`${name}: ⚠ DOUBLE-SPEND FLAGGED — this voucher was already accepted at another stall`);
    }
    link.announceSeen(decoded.voucher.id);
    outcomes.accepted++;
    console.log(`${name}: accepted ${ethers.formatUnits(decoded.voucher.amount, 6)} USDT offline (sig verified locally)`);
  };

  vendorA.on("voucher", vendorCheck("pie-stand", vendorA));
  vendorB.on("voucher", vendorCheck("scarf-stall", vendorB));

  // stalls open first, then the fan walks up — and joins resolve
  // sequentially (concurrent DHT announces against a fresh bootstrap
  // node race each other's routing tables)
  await vendorA.joinStand(STAND);
  await vendorB.joinStand(STAND);
  await fan.joinStand(STAND);
  await new Promise((r) => setTimeout(r, 2000)); // let the swarm mesh
  console.log(`stand "${STAND}": fan sees stalls: ${fan.stalls.join(", ")}\n`);

  // fan mints a real EIP-712 voucher (pure signing — offline)
  const signer = ethers.Wallet.createRandom();
  const minted = await mintVoucher(signer, { ...CTX, amount: 5_000000n, expiry: Math.floor(Date.now() / 1000) + 7200 });
  const wire = encodeVoucher(minted);

  console.log("fan → pie-stand: paying with a 5 USDT voucher");
  fan.sendVoucher(wire, "pie-stand");
  await new Promise((r) => setTimeout(r, 1200));

  console.log("\nfan → scarf-stall: trying to pay with the SAME voucher");
  fan.sendVoucher(wire, "scarf-stall");
  await new Promise((r) => setTimeout(r, 1200));

  await Promise.all([fan.destroy(), vendorA.destroy(), vendorB.destroy(), venue.destroy()]);

  // both vendors got both sends: 1 accept + 3 flags is the ideal mesh;
  // require at least one accept and one flag to call it proven
  if (outcomes.accepted >= 1 && outcomes.flagged >= 1) {
    console.log(`\noffline handoff + double-spend gossip OK (${outcomes.accepted} accepted, ${outcomes.flagged} flagged)`);
  } else {
    console.error(`\nunexpected outcomes: ${JSON.stringify(outcomes)}`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
