import "dotenv/config";
import { RpcProvider } from "starknet";

export type Network = "sepolia" | "mainnet";

/**
 * STRK20 privacy pool. Mainnet and Sepolia only — there is no devnet pool, which
 * is why every pool-touching test in this repo runs against Sepolia for real.
 */
export const POOL_ADDRESS: Record<Network, string> = {
  sepolia: "0x0254a6b2997ef52e9f830ce1f543f6b29768295e8d17e2267d672c552cfe0d91",
  mainnet: "0x040337b1af3c663e86e333bab5a4b28da8d4652a15a69beee2b677776ffe812a",
};

/** STRK. Same address on both networks. Pool fees are charged in STRK (FRI). */
export const STRK_ADDRESS =
  "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";

export const RPC_URL: Record<Network, string> = {
  sepolia:
    process.env.STARKNET_SEPOLIA_RPC ??
    "https://api.cartridge.gg/x/starknet/sepolia",
  mainnet:
    process.env.STARKNET_MAINNET_RPC ??
    "https://api.cartridge.gg/x/starknet/mainnet",
};

export function provider(network: Network): RpcProvider {
  return new RpcProvider({ nodeUrl: RPC_URL[network] });
}

/**
 * Felts have many valid spellings — `0x4718f5a…` and `0x04718f5a…` are the same
 * value. Never compare them as strings.
 */
export function sameAddress(a: string, b: string): boolean {
  return BigInt(a) === BigInt(b);
}

/** Format a FRI (STRK wei) amount as STRK, for humans. */
export function fri(amount: bigint, decimals = 6): string {
  const whole = amount / 10n ** 18n;
  const frac = (amount % 10n ** 18n).toString().padStart(18, "0").slice(0, decimals);
  return `${whole}.${frac} STRK`;
}
