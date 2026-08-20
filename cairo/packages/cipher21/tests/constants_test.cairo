use cipher21::constants::{
    BET_LARGE, BET_MEDIUM, BET_SMALL, BUY_IN_MAX, BUY_IN_MID, BUY_IN_MIN, CHIP, MAX_FEE_SHARE_BPS,
    POOL_FEE_MAINNET, POOL_FEE_SEPOLIA, is_valid_buy_in, session_fee,
};

#[test]
fn session_costs_two_pool_fees() {
    assert!(session_fee(POOL_FEE_SEPOLIA) == 4 * CHIP);
    assert!(session_fee(POOL_FEE_MAINNET) == 12 * CHIP);
}

/// The whole point of the floor: on mainnet, where the fee is highest, the
/// smallest buy-in must still keep fees under the headroom ceiling.
#[test]
fn smallest_buy_in_survives_the_mainnet_fee() {
    assert!(is_valid_buy_in(BUY_IN_MIN, POOL_FEE_MAINNET));
    assert!(is_valid_buy_in(BUY_IN_MID, POOL_FEE_MAINNET));
    assert!(is_valid_buy_in(BUY_IN_MAX, POOL_FEE_MAINNET));
}

/// 12 STRK of fees against a 100-chip buy-in is 12% — well past the ceiling.
/// This is the design the session model replaced; it must stay rejected.
#[test]
fn a_buy_in_the_fee_would_eat_is_rejected() {
    assert!(!is_valid_buy_in(100 * CHIP, POOL_FEE_MAINNET));
    assert!(!is_valid_buy_in(BET_LARGE, POOL_FEE_MAINNET));
}

#[test]
fn buy_in_must_be_a_whole_number_of_largest_bets() {
    assert!(!is_valid_buy_in(BUY_IN_MIN + BET_SMALL, POOL_FEE_MAINNET));
    assert!(!is_valid_buy_in(BUY_IN_MIN + BET_MEDIUM, POOL_FEE_MAINNET));
}

#[test]
fn every_buy_in_tier_is_divisible_by_every_bet() {
    let tiers = array![BUY_IN_MIN, BUY_IN_MID, BUY_IN_MAX];
    for tier in tiers {
        assert!(tier % BET_SMALL == 0);
        assert!(tier % BET_MEDIUM == 0);
        assert!(tier % BET_LARGE == 0);
    }
}

#[test]
fn headroom_ceiling_is_five_percent() {
    assert!(MAX_FEE_SHARE_BPS == 500);
}
