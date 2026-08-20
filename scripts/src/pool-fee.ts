/**
 * M0 deliverable: read the live pool parameters that constrain the game design.
 *
 * The pool charges a flat fee per `apply_actions` call — per private transaction,
 * not per action inside it. That is the number that killed per-hand betting and
 * forced the session model (STRK20_INTEGRATION_PLAN.md §5), so it is measured
 * rather than assumed, and re-measured on mainnet before launch.
 *
 *   npm run pool-fee            # sepolia
 *   npm run pool-fee -- mainnet
 */
import { POOL_ADDRESS, RPC_URL, fri, provider, type Network } from "./config.js";

const network = (process.argv[2] ?? "sepolia") as Network;
if (network !== "sepolia" && network !== "mainnet") {
  console.error(`unknown network "${network}" — expected sepolia or mainnet`);
  process.exit(1);
}

const pool = POOL_ADDRESS[network];
const p = provider(network);

async function felt(entrypoint: string): Promise<bigint> {
  const [value] = await p.callContract({
    contractAddress: pool,
    entrypoint,
    calldata: [],
  });
  return BigInt(value);
}

/** Decode a short-string felt, e.g. 0x322e30 -> "2.0". */
function shortString(value: bigint): string {
  let hex = value.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  return Buffer.from(hex, "hex").toString("ascii");
}

const [version, feeAmount, feeCollector, proofValidityBlocks] = await Promise.all([
  felt("get_version"),
  felt("get_fee_amount"),
  felt("get_fee_collector"),
  felt("get_proof_validity_blocks"),
]);

const block = await p.getBlockLatestAccepted();

console.log(`network                 ${network}`);
console.log(`rpc                     ${RPC_URL[network]}`);
console.log(`pool                    ${pool}`);
console.log(`block                   ${block.block_number}`);
console.log(`pool version            ${shortString(version)}`);
console.log(`fee per apply_actions   ${feeAmount} FRI  (${fri(feeAmount)})`);
console.log(`fee collector           0x${feeCollector.toString(16)}`);
console.log(`proof validity blocks   ${proofValidityBlocks}`);
console.log();
console.log(`a session costs 2 pool transactions: ${fri(feeAmount * 2n)} in fees`);
