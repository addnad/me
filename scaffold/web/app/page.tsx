"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  formatEther,
  http,
} from "viem";
import { CONTRACT_ADDRESS, displayUri, promptGenesisAbi, ritualChain } from "../lib/chain";

type Piece = {
  tokenId: bigint;
  prompt: string;
  minter: string;
  jobId: string;
  imageUri: string;
  revealed: boolean;
  failed: boolean;
  failReason: string;
};

type MintPhase = "idle" | "confirming" | "gestating" | "revealed" | "failed";

const publicClient = createPublicClient({ chain: ritualChain, transport: http() });

export default function Home() {
  const [account, setAccount] = useState<`0x${string}` | null>(null);
  const [prompt, setPrompt] = useState("");
  const [mintPrice, setMintPrice] = useState<bigint | null>(null);
  const [phase, setPhase] = useState<MintPhase>("idle");
  const [phaseDetail, setPhaseDetail] = useState("");
  const [pieces, setPieces] = useState<Piece[]>([]);
  const [error, setError] = useState("");

  const walletClient = useMemo(() => {
    if (typeof window === "undefined" || !(window as any).ethereum) return null;
    return createWalletClient({ chain: ritualChain, transport: custom((window as any).ethereum) });
  }, []);

  const connect = useCallback(async () => {
    setError("");
    if (!walletClient) {
      setError("No wallet found. Open this page inside a wallet browser (MetaMask, Rainbow…).");
      return;
    }
    const [addr] = await walletClient.requestAddresses();
    const chainId = await walletClient.getChainId();
    if (chainId !== 1979) {
      try {
        await walletClient.switchChain({ id: 1979 });
      } catch {
        await walletClient.addChain({ chain: ritualChain });
      }
    }
    setAccount(addr);
  }, [walletClient]);

  const loadCollection = useCallback(async () => {
    try {
      const next = (await publicClient.readContract({
        address: CONTRACT_ADDRESS,
        abi: promptGenesisAbi,
        functionName: "nextTokenId",
      })) as bigint;
      const found: Piece[] = [];
      for (let id = next - 1n; id >= 1n && found.length < 48; id--) {
        const p = (await publicClient.readContract({
          address: CONTRACT_ADDRESS,
          abi: promptGenesisAbi,
          functionName: "pieces",
          args: [id],
        })) as any;
        found.push({
          tokenId: id,
          prompt: p[0],
          minter: p[1],
          jobId: p[2],
          imageUri: p[3],
          revealed: p[6],
          failed: p[7],
          failReason: p[8],
        });
      }
      setPieces(found);
    } catch {
      /* contract not deployed yet */
    }
  }, []);

  useEffect(() => {
    publicClient
      .readContract({ address: CONTRACT_ADDRESS, abi: promptGenesisAbi, functionName: "mintPrice" })
      .then((p) => setMintPrice(p as bigint))
      .catch(() => {});
    loadCollection();
    const t = setInterval(loadCollection, 15_000);
    return () => clearInterval(t);
  }, [loadCollection]);

  const mint = useCallback(async () => {
    if (!walletClient || !account || mintPrice === null || !prompt.trim()) return;
    setError("");
    setPhase("confirming");
    setPhaseDetail("Confirm the transaction in your wallet…");
    try {
      // Explicit gas: estimation is unreliable for async precompile calls.
      const hash = await walletClient.writeContract({
        address: CONTRACT_ADDRESS,
        abi: promptGenesisAbi,
        functionName: "mint",
        args: [prompt.trim()],
        value: mintPrice,
        gas: 1_000_000n,
        account,
      });
      setPhase("gestating");
      setPhaseDetail(`Mint tx ${hash} — the TEE executor is painting. jobId = this tx hash.`);
      await publicClient.waitForTransactionReceipt({ hash });

      // Poll for the Phase 2 reveal on this jobId (== tx hash).
      for (let i = 0; i < 100; i++) {
        await new Promise((r) => setTimeout(r, 3000));
        const tokenId = (await publicClient.readContract({
          address: CONTRACT_ADDRESS,
          abi: promptGenesisAbi,
          functionName: "jobToToken",
          args: [hash],
        })) as bigint;
        if (tokenId === 0n) continue;
        const p = (await publicClient.readContract({
          address: CONTRACT_ADDRESS,
          abi: promptGenesisAbi,
          functionName: "pieces",
          args: [tokenId],
        })) as any;
        if (p[6]) {
          setPhase("revealed");
          setPhaseDetail(`Token #${tokenId} revealed.`);
          setPrompt("");
          loadCollection();
          return;
        }
        if (p[7]) {
          setPhase("failed");
          setPhaseDetail(`Generation failed: ${p[8]} — you can retry from the gallery.`);
          loadCollection();
          return;
        }
      }
      setPhaseDetail("Still gestating — it will reveal in the gallery when the callback lands.");
    } catch (e: any) {
      setPhase("idle");
      setError(e?.shortMessage || e?.message || String(e));
    }
  }, [walletClient, account, mintPrice, prompt, loadCollection]);

  const retry = useCallback(
    async (tokenId: bigint) => {
      if (!walletClient || !account) return;
      const hash = await walletClient.writeContract({
        address: CONTRACT_ADDRESS,
        abi: promptGenesisAbi,
        functionName: "retry",
        args: [tokenId],
        gas: 1_000_000n,
        account,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      loadCollection();
    },
    [walletClient, account, loadCollection]
  );

  return (
    <main className="wrap">
      <header>
        <h1>HEX_PAYLOAD GENESIS</h1>
        <p className="tag">
          Fully on-chain generative art. Your prompt enters Ritual&apos;s image precompile;
          the mint transaction hash <em>is</em> the provenance record.
        </p>
        {account ? (
          <span className="pill">{account.slice(0, 6)}…{account.slice(-4)}</span>
        ) : (
          <button onClick={connect}>Connect wallet</button>
        )}
      </header>

      <section className="mint">
        <textarea
          placeholder="Describe the artwork… e.g. 'obsidian monolith humming with neon glyphs, rain'"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          rows={3}
          maxLength={500}
        />
        <div className="mintRow">
          <button disabled={!account || phase === "confirming" || phase === "gestating" || !prompt.trim()} onClick={mint}>
            {phase === "gestating" ? "Gestating…" : `Mint${mintPrice !== null ? ` · ${formatEther(mintPrice)} RITUAL` : ""}`}
          </button>
          <span className={`status status-${phase}`}>{phaseDetail}</span>
        </div>
        {error && <p className="error">{error}</p>}
        <p className="hint">One mint at a time per wallet — Ritual allows a single async job in flight per sender.</p>
      </section>

      <section className="gallery">
        {pieces.map((p) => (
          <article key={p.tokenId.toString()} className="card">
            {p.revealed ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={displayUri(p.imageUri)} alt={p.prompt} loading="lazy" />
            ) : (
              <div className={`placeholder ${p.failed ? "failed" : "gestating"}`}>
                {p.failed ? "generation failed" : "gestating…"}
              </div>
            )}
            <div className="meta">
              <strong>#{p.tokenId.toString()}</strong>
              <p className="prompt">{p.prompt}</p>
              <a
                href={`https://explorer.ritualfoundation.org/tx/${p.jobId}`}
                target="_blank"
                rel="noreferrer"
                className="prov"
              >
                provenance ↗
              </a>
              {p.failed && account?.toLowerCase() === p.minter.toLowerCase() && (
                <button className="retry" onClick={() => retry(p.tokenId)}>
                  retry
                </button>
              )}
            </div>
          </article>
        ))}
        {pieces.length === 0 && <p className="empty">No pieces yet — be the first mint.</p>}
      </section>

      <footer>
        <a href={`https://explorer.ritualfoundation.org/address/${CONTRACT_ADDRESS}`} target="_blank" rel="noreferrer">
          contract ↗
        </a>
        <span>· chain 1979 · art by HEX_PAYLOAD</span>
      </footer>
    </main>
  );
}
