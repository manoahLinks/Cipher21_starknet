# Cipher21 · Starknet — Milestones

Execution breakdown of [`STRK20_INTEGRATION_PLAN.md`](./STRK20_INTEGRATION_PLAN.md).
One milestone = one feature branch = one PR into `main`.

## Standing rules

**No mocks.** Every milestone ends with something real running against a real
network. Nothing merges on the strength of a stub, a fake pool, a hardcoded
proof, or a fixture standing in for a contract call.

The one thing that cannot be exercised locally is the STRK20 pool — it exists on
Mainnet and Sepolia only, there is no devnet deployment. "No mocks" therefore
means: **anything that touches the pool is tested on Sepolia against the real
pool**, not stubbed for a local run. Pure logic with no pool dependency (deck
verification, payout math, the table state machine) gets real `snforge` unit
tests — those are tests, not mocks.

**Definition of done is an artifact, not a green check.** Every milestone below
lands a deployed address, an explorer link, or a recorded transaction hash. If a
milestone can be declared done without one, it is written wrong.

**The anonymizer is yours.** `Cipher21Anonymizer` holds funds mid-transaction
and is the contract that needs an audit. Per the integration skill's rules I
deliver design guidance and reference-package pointers for it — your team
writes, reviews, audits, deploys, and maintains it. The rest of the Cairo
(`table`, `deck`, `payout`) is ordinary game logic and not subject to that rule.

**Branch flow.** Branch from `main`, PR into `main`, squash. Branch names below
are the contract. No milestone starts before its entry criteria hold.

---

## M0 — `chore/scaffold` · foundations

Entry: none.

- [x] Scarb workspace at `cairo/`, `snforge` wired, `starknet 2.18.0`.
- [x] `web/` scaffolded — Next 16.3.1, React 19, Tailwind 4, deps pinned per plan §4.
- [x] CI: `scarb fmt --check`, `scarb build`, `snforge test`, `npm run typecheck`, `next build`.
- [x] `.env.example` committed with placeholders; `.env` gitignored.
- [x] Live pool parameters measured via `scripts/src/pool-fee.ts` and recorded in
      plan §5 — **2 STRK per pool transaction on Sepolia, 6 STRK on mainnet**.
      Buy-in tiers derived from it and tested in `cairo/.../constants.cairo`.
- [ ] A real funded Sepolia account (see "Getting started" in the README). Yours
      to create — it needs your browser for the faucet.

Done when: CI is green on the branch, and the measured pool fee is written into
the plan.

Out: no game logic, no wallet UI.

---

## M1 — `feat/money-loop` · the money loop

**Nothing else starts until this works.** This is the STRK20-specific path with
every unknown in it: the public withdraw leg, one invoke per transaction, note
maturity, the fee, proving latency.

Entry: M0 merged.

- `cairo/src/table.cairo` — the **settlement core**, built for real and kept:
  accepts a session buy-in, holds the stake, exposes `claim_payout(session_id)`.
  Game rules arrive in M3; this is the same contract, not a placeholder.
- `cairo/src/anonymizer.cairo` — `Cipher21Anonymizer`, the `privacy_invoke`
  helper. Withdraw → `claim_payout` → re-shield. Nearest reference:
  `packages/vesu_lending_anonymizer` in
  [starknet-privacy](https://github.com/starkware-libs/starknet-privacy)
  (skeleton, not drop-in); `packages/ekubo_swap_anonymizer` is the fuller one.
- `scripts/money-loop.ts` — end-to-end on Sepolia: **buy in once → settle a
  synthetic outcome → cash out once**. Two pool operations per session, per plan §5.
- Atomicity test on Sepolia: settlement reverts → clean rollback, nothing stranded.

Done when: three Sepolia explorer links — buy-in, settlement, cash-out — and the
payout is confirmed as a real note. No cards, no UI.

---

## M2 — `feat/deck` · the shoe

Entry: M1 merged.

- `house/shuffle.ts` — seeded Fisher–Yates over a real 52-card shoe, salted
  Merkle leaves, root commitment. Two-sided entropy.
- `house/reveal.ts` — per-card Merkle paths, encrypted to the player.
- `cairo/src/deck.cairo` — Merkle verification and card decoding.
- `snforge` suite against known vectors, plus a cross-check that the TypeScript
  shuffle and the Cairo verifier agree on the same shoe.

Done when: the real house service commits a root and the deployed Sepolia
verifier accepts its reveals and rejects a tampered path.

---

## M3 — `feat/table` · the game

Entry: M2 merged.

- Full `Cipher21Table` state machine on top of M1's settlement core.
- `cairo/src/payout.cairo` — `_computePayout` / `_effectiveTotal` ported from
  the FHEVM build. They operated on plaintext at settlement time already, so
  they translate close to line-for-line.
- Dealer auto-play enforced on-chain — this is what makes commit-reveal honest
  here, since the dealer has no discretion to exploit.
- **The house-timeout refund path.** Still undesigned and it strands a player's
  stake. It ships in this milestone or the game is not safe to run.
- Full `snforge` suite: hand outcomes, splits, doubles, blackjack, bust, push.

Done when: a full session — buy in, play N hands as ordinary Starknet
transactions, cash out — runs end to end on Sepolia from a script.

---

## M4 — `feat/web` · the frontend

Entry: M3 merged.

- Wallet connect via get-starknet v6 + `WalletAccountV6` in `web/src/lib/wallet.ts`.
- Capability detection via `supportedWalletApi` — **never** by probing
  `strk20Balances([])`.
- Graceful degradation for wallets without privacy support (Ready and Xverse
  only; Braavos and Privy are out).
- Shielded balance display via `strk20Balances(tokens)` — a deliberate feature,
  consent prompt designed for rather than hit by accident.
- Session UI: buy-in, table, cash-out. Both wallet prompts on a deposit named
  explicitly. Screening decline as its own UI state.
- Honest labeling per plan §3 — the player is hidden; the amounts and the hands
  are not.
- Ported Cipher21 components from `../zama_hack/web`.

Done when: a human plays a full session in the browser on Sepolia with the Ready
extension.

---

## M5 — `feat/mainnet` · audit gate and launch

Entry: M4 merged, **and the anonymizer audit is complete**. That gate is not
negotiable — it holds funds mid-transaction.

- Audit remediation.
- Mainnet deploy: table, anonymizer, deck.
- Denominations re-derived from the **mainnet** `get_fee_amount`, which is not
  the Sepolia number.
- Three mainnet transaction hashes touching the pool
  (`0x040337b1af3c663e86e333bab5a4b28da8d4652a15a69beee2b677776ffe812a`)
  recorded in `strk20.json`, plus contract addresses, demo video, demo URL.
- Landing page and pitch.

Done when: a real session runs on mainnet and `strk20.json` is complete.

---

## Two things dropped from the README roadmap

**The faucet is gone.** A chip faucet hands out play money — on a build that
ends on mainnet with a real ERC-20, it is a mock wearing a contract's clothes.
Use real STRK on Sepolia from M0 onward.

**Per-hand betting is gone.** Superseded by the session model in plan §5: the
flat pool fee makes two pool operations per hand cost more than a 10-chip stake.
Buy in once, play, cash out once.
