# STRK20 Privacy Integration Plan — Cipher21 · Starknet

Generated 2026-08-17 by the strk20-privacy-integration skill. Statuses below were current at generation time — re-verify the "coming soon" and fee items before building against them.

## 1. Project snapshot

- **Stack:** greenfield. Repo contains `README.md` (design doc) and `strk20.json` only — no `package.json`, `Scarb.toml`, or `snfoundry.toml` yet.
- **Planned contracts (from README):** `cairo/src/table.cairo` (`Cipher21Table` — game state machine), `cairo/src/anonymizer.cairo` (`Cipher21Anonymizer` — `privacy_invoke`), `cairo/src/deck.cairo`, `cairo/src/payout.cairo`, `cairo/src/faucet.cairo`.
- **Planned frontend:** `web/` — Next.js 16, React 19, Tailwind 4, ported from `../zama_hack/web`. Wallet connection and transaction layer land in `web/src/lib/strk20.ts` (new).
- **Privacy goal:** break the link between a player's wallet and their bets and payouts. Card secrecy is handled *outside* STRK20 by deck commitments and is not a STRK20 concern.
- **Environment:** Sepolia first, mainnet after the loop is proven. Target wallet: Ready.

Because the repo is pre-code, this plan defines the files rather than modifying existing ones. Paths below are the contract this plan commits to.

## 2. Chosen route: Privacy Wallet API (starknet.js) + your own anonymizer contract

Users bring their own wallets, so every user-facing pool action goes through the Wallet API and the dapp never touches a viewing key. Crediting a game payout back into a private note is a protocol-specific action with no first-party private path, so it needs an anonymizer contract you write, audit, deploy, and maintain.

**First-party check performed:** AVNU ships private swaps end to end (`@avnu/avnu-sdk >= 4.2.0`) with no Cairo required, but Cipher21 needs "settle a game outcome into a note", which no protocol provides. Writing your own anonymizer is therefore justified — this is the expensive route and you are taking it deliberately.

**The rule this follows:** this app never touches viewing keys — the user's wallet acts on its behalf via starknet.js.

## 3. What this delivers — hidden vs visible

| Private | Public |
|---|---|
| Which wallet is playing at the table | Buy-in and cash-out amounts (the public ERC-20 legs) |
| The link between a player and their session | That an address interacted with the pool, and when |
| Chip balance held as notes between sessions | Every hand played within a session, and its outcome |
| Which notes funded a buy-in | The payout amount credited to an open note |

**Honest limit:** the anonymizer hides the *player's address* behind the settlement; the amounts and the game activity itself remain public. An observer can reconstruct the table's full win/loss history and attribute none of it to a wallet. This is narrower than the FHE build's guarantee and the UI copy must not blur it.

**Per-player stats:** private transactions are relayed, so `sender` is the relayer's account for every user. Any history, leaderboard, or stats feature must read the pool's `Deposit` event and filter on its **first indexed key (topic1)**, never the transaction sender. Grouping by `sender` silently attributes every buy-in to one address.

## 4. Prerequisites & versions

```sh
npm install @starknet-io/get-starknet-discovery@6.0.4 \
            @starknet-io/get-starknet-wallet-standard@6.0.4 \
            @starknet-io/types-js@0.10.3 \
            starknet@10.4.0
```

- get-starknet v6.x lives on the npm **`next`** tag — pin explicitly or `npm install` fetches the older major. Freshness check on 2026-08-17 moved these from 6.0.3 → **6.0.4**.
- `starknet@10.4.0` matches the STRK20 starter kit; `next` is currently 10.7.0. Re-verify before pinning.
- Cairo toolchain: `starknet 2.18.0`, Scarb workspace, `snforge` for tests.
- Test wallet: **Ready extension**. Wallet scope is Ready and Xverse only — Xverse's dapp-facing Wallet API is in progress. **Braavos, Privy, and embedded-wallet providers are unsupported; do not plan around them.**

## 5. ⚠️ The pool fee changes the game design

A **flat pool fee applies per private operation** — on the order of several STRK on mainnet at time of writing. Read it from the pool via `get_fee_amount` rather than assuming a number.

The README's design puts **two pool operations per hand** (bet in, payout out) at fixed denominations of 10 / 50 / 100. At a flat multi-STRK fee, a 10-chip hand can cost more in fees than the stake. **That design is not viable as written.**

**Required change — move to a session model:**

| | README design | This plan |
|---|---|---|
| Buy-in | per hand | **once per session** (one pool op) |
| Hands | one pool op each | played against `Cipher21Table` as ordinary Starknet txs, no pool op |
| Cash-out | per hand | **once per session** (one pool op) |

Two pool operations per *session* instead of per *hand*. This amortizes the fee, removes the ~10-block note-maturity wait from the inner loop, and matches how a real table works. Privacy is unchanged: the buy-in still breaks the wallet↔session link, which is the property that matters.

Secondary consequence: raise denominations so a buy-in is meaningfully larger than the fee. Subtract the fee when pre-filling any "MAX" amount, or the operation fails after the user has already signed.

## 6. Phase 1 — wallet connect + first shielded flow (buildable now)

Scope: no game logic. Prove the pool round-trip on Sepolia.

1. Scaffold `web/` from the STRK20 starter kit (Next.js 16 / React 19) — it already ships the wallet picker, shield, unshield, and private transfer.
2. **Connect** in `web/src/lib/wallet.ts`: `createStore({ eip1193Adapters: [] })` (keeps MetaMask out of discovery), then `WalletAccountV6.connect(provider, wallet)`. Fetch the current WalletAccount guide before writing this — do not guess method names.
3. **Capability detection** in `web/src/lib/strk20.ts`: use `walletV6.supportedWalletApi(wallet)` / `supportedSpecs` and treat wallet-API `>= 0.10` as STRK20-capable. **Never probe `strk20Balances([])` to feature-detect** — it is a balance read and wallets gate it behind a user consent prompt the app has no reason to trigger.
4. **Graceful degradation** (not optional): a wallet without privacy support hides the private actions and prompts for Ready.
5. **Shield / unshield** wired to a test screen. Name **both** transactions in the UI — a deposit is `approve` then deposit, so the wallet prompts twice and users read the second as a bug.
6. Verify against the Ready extension and the wallet test dapp.

**Phase 1 gotchas to implement, not discover:**
- Import `WalletWithStarknetFeatures` from the subpath `@starknet-io/get-starknet-wallet-standard/features` — the package root declares but does not export it (TS2459).
- Compare addresses with `BigInt(a) === BigInt(b)`. `0x4718f5a…` and `0x04718f5a…` are the same felt and string equality reports one token as two.
- Give `waitForTransaction` a ceiling and treat timeout as "submitted", with an explorer link as fallback. Paymaster-relayed transactions can take a while to reach your RPC.
- Surface screening decline as its own UI state, not a generic error — the pool enforces deposit screening onchain and a deposit can legitimately be refused.

## 7. Phase 2 — shielded balance UI + session buy-in

1. **Shielded balance display** (confirmed as a deliberate feature): call `WalletAccountV6.strk20Balances(tokens)` from `web/src/lib/strk20.ts`. This triggers a user consent prompt for balance access — design the UI so the prompt is expected, and confirm Ready's consent behavior before building around it.
2. **Session buy-in**: a single `strk20InvokeTransaction([...])` that unshields the buy-in to `Cipher21Table` and opens a session. `strk20InvokeTransaction` takes an **array**, so multi-action settlements batch into one wallet request.
3. Honest labeling throughout per the hidden/visible table in §3 — buy-in and cash-out amounts are public, hands within a session are public, the player is not.

## 8. Phase 3 — `Cipher21Anonymizer` (your Cairo, your audit)

**This skill does not write Cairo.** The anonymizer is your team's contract to build, review, audit, deploy, and maintain.

- **Entry criterion:** Phase 1 round-trip verified on Sepolia, and `Cipher21Table` settlement logic complete.
- **Design on paper first:** input token → `claim_payout(game_id)` on `Cipher21Table` → output token, in the pool's withdraw → act → re-shield shape. Specify approvals and rollback behavior for every path.
- **Nearest reference:** `packages/vesu_lending_anonymizer` in https://github.com/starkware-libs/starknet-privacy — intentionally lean, a skeleton to adapt rather than a drop-in. `packages/ekubo_swap_anonymizer` is the fuller example.
- **Note on the monorepo:** `packages/sub_account_anonymizer` no longer exists; sub-accounts now ship as `packages/shadow_account_anonymizer`. Not needed here — flagged so a stale reference does not send you looking.
- **Open notes carry public amounts.** Crediting the payout straight into an open note is atomic and cheap but publishes the amount. Landing it in the player's own note and following with an encrypted transfer hides the amount at the cost of an extra operation and another fee. Choose deliberately and record the choice.
- **Test atomicity:** settlement succeeds → payout credited as a private note; settlement reverts → clean rollback, nothing stranded.
- **Audit step — owner, budget, and timing lined up before mainnet. Non-negotiable.** The anonymizer holds funds mid-transaction.

## 9. Testing

- **No mocks — project policy.** Nothing merges on the strength of a stub, a fake pool, or a fixture standing in for a contract call.
- Sepolia first, throughout. There is no local devnet STRK20 pool, so the pool leg cannot be exercised offline. Under the no-mock policy that means every pool-touching path is tested on Sepolia against the **real** pool rather than stubbed for a local run.
- `snforge` for `Cipher21Table`, `deck`, and `payout` — these need no pool and should be fully covered locally.
- Ready extension + wallet test dapp for every Wallet-API phase.
- Dev/test may use the Privacy SDK directly, where *you* control the account and keys. Production user flows stay on the Wallet API.

## 10. Compliance & security notes

- Deposit screening is enforced onchain by the protocol and applies on every route, self-hosted proving included. It is not something any route bypasses.
- Selective disclosure exists so the pool can disclose what a legitimate regulatory request requires without exposing unrelated users. This is not automatic compliance and carries no regulator endorsement.
- You own app-level legal and compliance decisions, any use-case KYC, and the anonymizer contract end to end.
- A real-money card game may carry gambling-licensing obligations independent of anything here. Out of scope for this plan; get advice before mainnet with real value.

## 11. Open items to re-verify at build time

- **Pool fee** via `get_fee_amount` — the number drives denominations and the session model in §5. Confirm before fixing buy-in sizes.
- `starknet` pin: 10.4.0 vs current `next` 10.7.0.
- get-starknet 6.0.4 — moved from 6.0.3 during this plan's generation; check again.
- Xverse dapp-facing Wallet API status.
- Fee UX: wallet flows currently sponsor gas but not pool fees; shielded-token fee payment is still being designed.
- Ready's consent-prompt behavior for `strk20Balances` before Phase 2 UI is finalized.
- The house-timeout refund path from the README — still undesigned, and it strands a player's stake. Settle before Phase 3.

## 12. Execution

Phase breakdown, branch names, and per-milestone definitions of done live in [`MILESTONES.md`](./MILESTONES.md). One milestone = one feature branch = one PR into `main`, and each ends with a deployed address or a recorded transaction hash rather than a green check.

## 13. Links

- What STRK20 is — https://strk20-by-example.org/what-is-strk20
- Builder-facing privacy overview — https://strk20-by-example.org/builder-privacy-overview
- Wallet API overview — https://strk20-by-example.org/starknet-wallet-api/overview
- starknet.js / `WalletAccountV6` — https://strk20-by-example.org/starknet-wallet-api/starknet-js
- React apps / `useStrk20` — https://strk20-by-example.org/starknet-wallet-api/starknet-start-hook
- Private DeFi via the Wallet API (open notes + invoke) — https://strk20-by-example.org/starknet-wallet-api/private-defi
- Anonymizer anatomy / `privacy_invoke` — https://strk20-by-example.org/helpers/privacy-invoke
- Vault anonymizer example — https://strk20-by-example.org/helpers/vesu-lending-helper
- WalletAccount guide (fetch before coding) — https://starknet-js.com/docs/next/guides/account/walletAccount/#with-get-starknet-v6
- Wallet test dapp — https://starknet-wallet-account.vercel.app/
- Privacy SDK monorepo — https://github.com/starkware-libs/starknet-privacy
- STRK20 starter kit — https://github.com/Akashneelesh/strk20-starter-kit
