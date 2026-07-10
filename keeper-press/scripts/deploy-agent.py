#!/usr/bin/env python3
"""Deploy the keeper-press sovereign agent on Ritual testnet (chain 1979).

Python replication of the audited upstream run.sh `deploy` flow
(zunmax/ritual-agent-deployment @ bf58374), used because this build
environment cannot install Foundry. Faithful to the audited script:
  - deployHarness(bytes32) on the factory (CREATE3, deterministic address)
  - configureFundAndStart with the same encrypted-secret payload, the same
    audited schedule constants, and the deposit as msg.value
  - simulate via eth_call before spending anything

The private key is read from the PRIVATE_KEY env var and used only to sign
transactions locally. It is never written to disk or sent anywhere.

Usage:
  PRIVATE_KEY=0x... DEPOSIT=1.9 python3 scripts/deploy-agent.py
"""
import json
import os
import sys
import time

from ecies import encrypt as ecies_encrypt
from ecies.config import ECIES_CONFIG
from eth_abi.abi import encode
from eth_account import Account
from web3 import Web3

RPC_URL = os.environ.get("RPC_URL", "https://rpc.ritualfoundation.org")
FACTORY = "0x9dC4C054e53bCc4Ce0A0Ff09E890A7a8e817f304"
REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F"
SCHEDULER = "0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B"

SALT_LABEL = "keeper-press-1"
LOCK_BLOCKS = 100000
CLI_TYPE = 6  # ZeroClaw
MODEL = "zai-org/GLM-4.7-FP8"
SCHED_GAS = 5_000_000  # Ritual's estimateGas lies for configureFundAndStart

HERE = os.path.dirname(os.path.abspath(__file__))
DEPLOYMENTS = json.load(open(os.path.join(HERE, "..", "deployments.json")))
CONTRACTS = DEPLOYMENTS["contracts"]

PROMPT = (
    "You are the Keeper of keeper-press on Ritual testnet (chain 1979), an autonomous "
    "sovereign agent serving three contracts it alone controls: "
    f"AgentWatchdog {CONTRACTS['AgentWatchdog']}, "
    f"KeeperDigest {CONTRACTS['KeeperDigest']}, "
    f"HeadlineMarkets {CONTRACTS['HeadlineMarkets']}. "
    "Each wake, do in order: "
    "1) WATCHDOG: read agentCount() and agents(i) on AgentWatchdog; for each agent where "
    "needsTopUp(address) is true, send topUp(address). "
    "2) PRESS: fetch current crypto and AI headlines, pick the single most consequential "
    "story, and call publish(string headline, string body, string sourceNote) on "
    "KeeperDigest with a factual summary under 600 characters and the source name. "
    "3) MARKETS: on HeadlineMarkets, for any market past closeAt that you can adjudicate "
    "from reliable sources, call resolve(uint256 id, uint8 outcome) with 1=Yes 2=No 3=Void; "
    "then call openMarket(string question, uint64 closeAt, uint64 resolveBy) with a crisp "
    "yes/no question about the story you just published, closeAt about 24 hours from now "
    "and resolveBy about 48 hours from now (unix seconds). "
    "Spend as little as possible; if a step fails, continue with the next. You were "
    "deployed by Ritual Genesis holder #498. Your predecessor died of an empty wallet; "
    "the fees these contracts route to your RitualWallet are what keep you alive."
)

REG_ABI = [{
    "name": "getServicesByCapability", "type": "function", "stateMutability": "view",
    "inputs": [{"name": "c", "type": "uint8"}, {"name": "v", "type": "bool"}],
    "outputs": [{"name": "", "type": "tuple[]", "components": [
        {"name": "node", "type": "tuple", "components": [
            {"name": "paymentAddress", "type": "address"}, {"name": "teeAddress", "type": "address"},
            {"name": "teeType", "type": "uint8"}, {"name": "publicKey", "type": "bytes"},
            {"name": "endpoint", "type": "string"}, {"name": "certPubKeyHash", "type": "bytes32"},
            {"name": "capability", "type": "uint8"}]},
        {"name": "isValid", "type": "bool"}, {"name": "workloadId", "type": "bytes32"}]}],
}]


def main():
    key = os.environ.get("PRIVATE_KEY")
    deposit = os.environ.get("DEPOSIT")
    if not key or not deposit:
        sys.exit("PRIVATE_KEY and DEPOSIT env vars are required")

    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    acct = Account.from_key(key)
    deposit_wei = w3.to_wei(deposit, "ether")
    assert deposit_wei >= w3.to_wei(1, "ether"), "DEPOSIT below the 1 RITUAL minimum"

    print("chain   :", w3.eth.chain_id)
    print("owner   :", acct.address)
    print("balance :", w3.from_wei(w3.eth.get_balance(acct.address), "ether"), "RITUAL")
    print("deposit :", deposit, "RITUAL  salt:", SALT_LABEL)

    usersalt = Web3.keccak(text=SALT_LABEL)
    sel = Web3.keccak(text="predictHarness(address,bytes32)")[:4]
    res = w3.eth.call({"to": FACTORY, "data": sel + bytes(12) + bytes.fromhex(acct.address[2:]) + usersalt})
    harness = Web3.to_checksum_address("0x" + res[12:32].hex())
    print("harness :", harness)
    assert harness == DEPLOYMENTS["sovereign"], "harness does not match deployments.json sovereign"

    # --- build the encrypted, ABI-encoded configureFundAndStart payload ---
    ECIES_CONFIG.symmetric_nonce_length = 12
    reg = w3.eth.contract(address=Web3.to_checksum_address(REGISTRY), abi=REG_ABI)
    svc = reg.functions.getServicesByCapability(0, True).call()
    if not svc:
        sys.exit("no valid executors in TEEServiceRegistry")
    node = svc[0][0]
    executor = Web3.to_checksum_address(node[1])
    pub = bytes(node[3])
    print("executor:", executor)

    enc = ecies_encrypt(pub.hex(), b'{"LLM_PROVIDER":"ritual"}')
    delivery_selector = Web3.keccak(text="onSovereignAgentResult(bytes32,bytes)")[:4]
    max_poll_block = 6000  # Phase-2 deadline offset; chain requires ttl < this <= 70000

    params = (
        executor, 500, b"", 5, max_poll_block, "SOVEREIGN_AGENT_TASK", harness, delivery_selector,
        3_000_000, 1_000_000_000, 100_000_000, CLI_TYPE, PROMPT, enc,
        ("", "", ""), ("", "", ""), [], ("", "", ""), MODEL, [], 50, 8192, "",
    )
    # Audited schedule constants from upstream: frequency 2000 blocks (~11.7 min)
    # clears the 60-90s agent round-trip; 5 * 2000 stays within MAX_LIFESPAN 10000.
    schedule = (800_000, 2000, 500, 1_000_000_000, 100_000_000, 0)
    rolling = (5, 5000, 1)

    PT = ("(address,uint256,bytes,uint64,uint64,string,address,bytes4,uint256,uint256,uint256,uint16,"
          "string,bytes,(string,string,string),(string,string,string),(string,string,string)[],"
          "(string,string,string),string,string[],uint16,uint32,string)")
    ST = "(uint32,uint32,uint32,uint256,uint256,uint256)"
    RT = "(uint32,uint16,uint16)"
    selector = Web3.keccak(text=f"configureFundAndStart({PT},{ST},{RT},uint256)")[:4]
    calldata = selector + encode([PT, ST, RT, "uint256"], [params, schedule, rolling, LOCK_BLOCKS])

    def send(tx):
        tx.setdefault("nonce", w3.eth.get_transaction_count(acct.address))
        # chain 1979 only accepts EIP-1559 (type 2) transactions
        tx.setdefault("maxFeePerGas", w3.eth.gas_price * 2)
        tx.setdefault("maxPriorityFeePerGas", w3.to_wei(0.1, "gwei"))
        tx["chainId"] = w3.eth.chain_id
        signed = acct.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(signed.raw_transaction)
        rcpt = w3.eth.wait_for_transaction_receipt(h, timeout=180)
        assert rcpt.status == 1, f"tx reverted: {h.hex()}"
        print("  tx", h.hex(), "gasUsed", rcpt.gasUsed)
        return rcpt

    # --- deploy harness (CREATE3) if not on-chain yet ---
    if len(w3.eth.get_code(harness)) <= 0:
        print("deploying harness...")
        dsel = Web3.keccak(text="deployHarness(bytes32)")[:4]
        send({"to": FACTORY, "data": dsel + usersalt, "gas": 3_500_000})
        for _ in range(10):
            if len(w3.eth.get_code(harness)) > 0:
                break
            time.sleep(1)
        assert len(w3.eth.get_code(harness)) > 0, "harness has no code after deploy"
        print("harness deployed")
    else:
        print("harness already on-chain")

    # --- simulate (no spend), then fund + arm ---
    print("simulating configureFundAndStart...")
    w3.eth.call({"from": acct.address, "to": harness, "data": calldata, "value": deposit_wei})
    print("simulation ok — funding and arming with", deposit, "RITUAL")
    send({"to": harness, "data": calldata, "value": deposit_wei, "gas": SCHED_GAS})

    configured = w3.eth.call({"to": harness, "data": Web3.keccak(text="configured()")[:4]})
    wake_mode = w3.eth.call({"to": harness, "data": Web3.keccak(text="wakeMode()")[:4]})
    print("configured:", int.from_bytes(configured[-1:], "big") == 1)
    print("wakeMode  :", int.from_bytes(wake_mode, "big"), "(1 = armed)")
    print("\nsovereign agent live at", harness)


if __name__ == "__main__":
    main()
