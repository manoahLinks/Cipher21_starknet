//! Chip denominations and buy-in tiers.
//!
//! These numbers are not taste. They fall out of one measured fact: the STRK20
//! pool charges a **flat fee per `apply_actions` call** — per private
//! transaction, not per action inside it — and that fee is paid in STRK.
//!
//! Measured live (`scripts/src/pool-fee.ts`, 2026-08-20, pool version 2.0):
//!
//! | network | fee per pool tx | per session (2 tx) |
//! |---------|-----------------|--------------------|
//! | Sepolia | 2 STRK          | 4 STRK             |
//! | Mainnet | 6 STRK          | 12 STRK            |
//!
//! A session touches the pool exactly twice — buy in, cash out. Every hand in
//! between is an ordinary Starknet transaction against `Cipher21Table` and pays
//! no pool fee at all. So the *bet* denominations are unconstrained by the fee;
//! only the *buy-in* has to be large enough that 12 STRK of fees is not a
//! meaningful bite out of it.
//!
//! Re-measure before mainnet. The pool owner can change the fee, and the tiers
//! below are only correct relative to the number they were derived from.

/// One chip, in FRI. A chip is one STRK.
pub const CHIP: u256 = 1_000_000_000_000_000_000;

/// Fee charged per pool transaction, in FRI, as measured on each network.
pub const POOL_FEE_SEPOLIA: u256 = 2 * CHIP;
pub const POOL_FEE_MAINNET: u256 = 6 * CHIP;

/// A session opens and closes with one pool transaction each.
pub const POOL_TXS_PER_SESSION: u256 = 2;

/// Bet sizes available at the table, in chips. Free-form bet sizing would shrink
/// the anonymity set, so bets are denominated. These cost no pool fee.
pub const BET_SMALL: u256 = 10 * CHIP;
pub const BET_MEDIUM: u256 = 50 * CHIP;
pub const BET_LARGE: u256 = 100 * CHIP;

/// Buy-in tiers, in chips. The floor is set so pool fees stay under
/// `MAX_FEE_SHARE_BPS` of the smallest buy-in on mainnet.
/// 12 STRK of mainnet fees against 500 chips is 2.4%; against 250 it would be
/// 4.8%, inside the ceiling but not a whole number of 100-chip bets.
pub const BUY_IN_MIN: u256 = 500 * CHIP;
pub const BUY_IN_MID: u256 = 1000 * CHIP;
pub const BUY_IN_MAX: u256 = 2500 * CHIP;

/// Ceiling on what a full session's pool fees may cost, as a share of the
/// smallest buy-in, in basis points. 500 bps = 5%.
pub const MAX_FEE_SHARE_BPS: u256 = 500;

/// Total pool fees a session pays on the given per-transaction fee.
pub fn session_fee(fee_per_pool_tx: u256) -> u256 {
    fee_per_pool_tx * POOL_TXS_PER_SESSION
}

/// A buy-in must cover the session's pool fees with the headroom above, and it
/// must be a whole multiple of the largest bet so the last hand of a session is
/// playable at any denomination.
pub fn is_valid_buy_in(amount: u256, fee_per_pool_tx: u256) -> bool {
    if amount % BET_LARGE != 0 {
        return false;
    }
    session_fee(fee_per_pool_tx) * 10_000 <= amount * MAX_FEE_SHARE_BPS
}
