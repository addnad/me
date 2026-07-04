import { defineChain } from "viem";

export const ritualChain = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_RITUAL_RPC_URL || "https://rpc.ritualfoundation.org"],
    },
  },
  blockExplorers: {
    default: { name: "RitualScan", url: "https://explorer.ritualfoundation.org" },
  },
});

export const CONTRACT_ADDRESS = (process.env.NEXT_PUBLIC_CONTRACT_ADDRESS ||
  "0x0000000000000000000000000000000000000000") as `0x${string}`;

export const promptGenesisAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "payable",
    inputs: [{ name: "prompt", type: "string" }],
    outputs: [{ name: "tokenId", type: "uint256" }],
  },
  {
    type: "function",
    name: "retry",
    stateMutability: "nonpayable",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "mintPrice",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "nextTokenId",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "jobToToken",
    stateMutability: "view",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "pieces",
    stateMutability: "view",
    inputs: [{ type: "uint256" }],
    outputs: [
      { name: "prompt", type: "string" },
      { name: "minter", type: "address" },
      { name: "jobId", type: "bytes32" },
      { name: "imageUri", type: "string" },
      { name: "contentHash", type: "bytes32" },
      { name: "mintedAt", type: "uint64" },
      { name: "revealed", type: "bool" },
      { name: "failed", type: "bool" },
      { name: "failReason", type: "string" },
    ],
  },
  {
    type: "event",
    name: "MintRequested",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "jobId", type: "bytes32", indexed: true },
      { name: "minter", type: "address", indexed: true },
      { name: "prompt", type: "string", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Revealed",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "jobId", type: "bytes32", indexed: true },
      { name: "imageUri", type: "string", indexed: false },
      { name: "contentHash", type: "bytes32", indexed: false },
    ],
  },
] as const;

/** Render storage URIs in a browser-friendly way. */
export function displayUri(uri: string): string {
  if (uri.startsWith("ipfs://")) return `https://gateway.pinata.cloud/ipfs/${uri.slice(7)}`;
  return uri;
}
