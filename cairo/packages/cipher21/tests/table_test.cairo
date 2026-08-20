//! `Cipher21Table` — settlement core tests.
//!
//! The token here is OpenZeppelin's audited ERC-20 preset, deployed for real.
//! The pool's withdraw leg is a plain ERC-20 transfer into the table, so it is
//! reproduced as exactly that: tokens arrive with no approval and no sender the
//! table trusts, and the buy-in is whatever the balance grew by.

use cipher21::constants::{BUY_IN_MIN, CHIP, POOL_FEE_MAINNET};
use cipher21::table::{
    ICipher21TableDispatcher, ICipher21TableDispatcherTrait, SESSION_TIMEOUT_BLOCKS, SessionState,
};
use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_number_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;

const SUPPLY: u256 = 1_000_000 * CHIP;
const BANKROLL: u256 = 10_000 * CHIP;

fn house() -> ContractAddress {
    'house'.try_into().unwrap()
}

fn anonymizer() -> ContractAddress {
    'anonymizer'.try_into().unwrap()
}

#[derive(Copy, Drop)]
struct Fixture {
    table: ICipher21TableDispatcher,
    token: IERC20Dispatcher,
}

fn setup() -> Fixture {
    let erc20 = declare("ERC20Upgradeable").unwrap().contract_class();
    let mut calldata = array![];
    let name: ByteArray = "Chips";
    let symbol: ByteArray = "CHIP";
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    SUPPLY.serialize(ref calldata);
    house().serialize(ref calldata);
    house().serialize(ref calldata);
    let (token_address, _) = erc20.deploy(@calldata).unwrap();

    let table_class = declare("Cipher21Table").unwrap().contract_class();
    let mut table_calldata = array![];
    house().serialize(ref table_calldata);
    token_address.serialize(ref table_calldata);
    POOL_FEE_MAINNET.serialize(ref table_calldata);
    let (table_address, _) = table_class.deploy(@table_calldata).unwrap();

    let fixture = Fixture {
        table: ICipher21TableDispatcher { contract_address: table_address },
        token: IERC20Dispatcher { contract_address: token_address },
    };

    start_cheat_caller_address(token_address, house());
    fixture.token.approve(table_address, BANKROLL);
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(table_address, house());
    fixture.table.fund_bankroll(BANKROLL);
    stop_cheat_caller_address(table_address);

    fixture
}

/// The pool's withdraw leg: tokens land in the table with no approval and no
/// call. Any address can play the pool's part, which is the point — the table
/// authorizes on the measured delta, never on a sender.
fn deliver_stake(fixture: Fixture, amount: u256) {
    start_cheat_caller_address(fixture.token.contract_address, house());
    fixture.token.transfer(fixture.table.contract_address, amount);
    stop_cheat_caller_address(fixture.token.contract_address);
}

fn open(fixture: Fixture, owner_key: felt252, amount: u256) -> u64 {
    deliver_stake(fixture, amount);
    start_cheat_caller_address(fixture.table.contract_address, anonymizer());
    let id = fixture.table.open_session(owner_key, anonymizer());
    stop_cheat_caller_address(fixture.table.contract_address);
    id
}

fn settle(fixture: Fixture, session_id: u64, final_balance: u256) {
    start_cheat_caller_address(fixture.table.contract_address, house());
    fixture.table.settle_session(session_id, final_balance);
    stop_cheat_caller_address(fixture.table.contract_address);
}

#[test]
fn deploys_with_the_measured_fee() {
    let f = setup();
    assert!(f.table.get_pool_fee() == POOL_FEE_MAINNET);
    assert!(f.table.get_house() == house());
    assert!(f.table.get_bankroll() == BANKROLL);
    assert!(f.table.get_accounted() == BANKROLL);
    assert!(f.token.balance_of(f.table.contract_address) == BANKROLL);
}

#[test]
fn a_buy_in_is_measured_not_pulled() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();

    let id = open(f, key.public_key, BUY_IN_MIN);

    let session = f.table.get_session(id);
    assert!(session.state == SessionState::Open);
    assert!(session.buy_in == BUY_IN_MIN);
    assert!(session.balance == BUY_IN_MIN);
    assert!(session.owner_key == key.public_key);
    assert!(session.anonymizer == anonymizer());
    assert!(f.table.get_accounted() == BANKROLL + BUY_IN_MIN);
}

/// Chips already accounted for are not a new buy-in. Without this, the bankroll
/// could be re-opened as somebody's session.
#[test]
#[should_panic(expected: 'C21: invalid buy-in amount')]
fn the_bankroll_is_not_an_unclaimed_buy_in() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.open_session(key.public_key, anonymizer());
}

/// 12 STRK of mainnet session fees against 100 chips is 12%. The session model
/// exists because that arithmetic does not work; the table enforces it.
#[test]
#[should_panic(expected: 'C21: invalid buy-in amount')]
fn a_buy_in_the_fee_would_eat_is_rejected() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    open(f, key.public_key, 100 * CHIP);
}

#[test]
fn a_winning_session_is_paid_out_of_the_bankroll() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    let won = BUY_IN_MIN + 200 * CHIP;

    settle(f, id, won);
    assert!(f.table.get_bankroll() == BANKROLL - 200 * CHIP);
    assert!(f.table.get_session(id).state == SessionState::Settled);

    let (r, s) = key.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    let paid = f.table.claim_payout(id, r, s);
    stop_cheat_caller_address(f.table.contract_address);

    assert!(paid == won);
    assert!(f.token.balance_of(anonymizer()) == won);
    assert!(f.table.get_session(id).state == SessionState::Closed);
    assert!(f.table.get_accounted() == f.token.balance_of(f.table.contract_address));
}

#[test]
fn a_losing_session_feeds_the_bankroll() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    let left = 200 * CHIP;

    settle(f, id, left);
    assert!(f.table.get_bankroll() == BANKROLL + (BUY_IN_MIN - left));

    let (r, s) = key.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    let paid = f.table.claim_payout(id, r, s);
    stop_cheat_caller_address(f.table.contract_address);

    assert!(paid == left);
    assert!(f.table.get_accounted() == f.token.balance_of(f.table.contract_address));
}

/// The table must never promise more than it can pay.
#[test]
#[should_panic(expected: 'C21: bankroll too low')]
fn a_win_the_bankroll_cannot_cover_is_refused() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    settle(f, id, BUY_IN_MIN + BANKROLL + CHIP);
}

#[test]
#[should_panic(expected: 'C21: caller is not the house')]
fn only_the_house_settles() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.settle_session(id, BUY_IN_MIN);
}

#[test]
#[should_panic(expected: 'C21: bad session signature')]
fn a_stranger_cannot_claim_a_session() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let thief = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    settle(f, id, BUY_IN_MIN);

    let (r, s) = thief.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.claim_payout(id, r, s);
}

/// The payout goes to the anonymizer named at buy-in and nowhere else, so a
/// leaked signature cannot be redirected.
#[test]
#[should_panic(expected: 'C21: wrong anonymizer')]
fn a_claim_only_pays_the_named_anonymizer() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    settle(f, id, BUY_IN_MIN);

    let (r, s) = key.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, 'elsewhere'.try_into().unwrap());
    f.table.claim_payout(id, r, s);
}

#[test]
#[should_panic(expected: 'C21: session is not settled')]
fn a_session_pays_out_once() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    settle(f, id, BUY_IN_MIN);

    let (r, s) = key.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.claim_payout(id, r, s);
    f.table.claim_payout(id, r, s);
}

#[test]
#[should_panic(expected: 'C21: session is not settled')]
fn an_unsettled_session_cannot_be_claimed() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);

    let (r, s) = key.sign(f.table.claim_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.claim_payout(id, r, s);
}

/// An unresponsive house must not be able to strand a stake.
#[test]
fn an_unsettled_session_can_be_taken_back_after_the_timeout() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);

    let opened_at = f.table.get_session(id).opened_at;
    start_cheat_block_number_global(opened_at + SESSION_TIMEOUT_BLOCKS);

    let (r, s) = key.sign(f.table.refund_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    let refunded = f.table.refund_session(id, r, s);
    stop_cheat_caller_address(f.table.contract_address);

    assert!(refunded == BUY_IN_MIN);
    assert!(f.token.balance_of(anonymizer()) == BUY_IN_MIN);
    assert!(f.table.get_session(id).state == SessionState::Refunded);
    // A refund is not a loss: the bankroll neither won nor lost anything.
    assert!(f.table.get_bankroll() == BANKROLL);
    assert!(f.table.get_accounted() == f.token.balance_of(f.table.contract_address));
}

#[test]
#[should_panic(expected: 'C21: session has not timed out')]
fn a_session_cannot_be_taken_back_early() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);

    let (r, s) = key.sign(f.table.refund_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.refund_session(id, r, s);
}

/// Domain separation, tested rather than asserted: the two authorizations are
/// different messages, so neither signature works as the other.
#[test]
#[should_panic(expected: 'C21: bad session signature')]
fn a_refund_signature_is_not_a_claim_signature() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    let id = open(f, key.public_key, BUY_IN_MIN);
    settle(f, id, BUY_IN_MIN);

    let (r, s) = key.sign(f.table.refund_hash(id)).unwrap();
    start_cheat_caller_address(f.table.contract_address, anonymizer());
    f.table.claim_payout(id, r, s);
}

#[test]
fn two_sessions_do_not_share_an_authorization() {
    let f = setup();
    let a = KeyPairTrait::<felt252, felt252>::generate();
    let b = KeyPairTrait::<felt252, felt252>::generate();
    let first = open(f, a.public_key, BUY_IN_MIN);
    let second = open(f, b.public_key, BUY_IN_MIN);

    assert!(first != second);
    assert!(f.table.claim_hash(first) != f.table.claim_hash(second));
    assert!(f.table.claim_hash(first) != f.table.refund_hash(first));
}

#[test]
#[should_panic(expected: 'C21: bankroll too low')]
fn the_house_cannot_withdraw_a_players_stake() {
    let f = setup();
    let key = KeyPairTrait::<felt252, felt252>::generate();
    open(f, key.public_key, BUY_IN_MIN);

    start_cheat_caller_address(f.table.contract_address, house());
    f.table.withdraw_bankroll(BANKROLL + CHIP);
}

#[test]
fn the_house_can_withdraw_its_own_bankroll() {
    let f = setup();
    start_cheat_caller_address(f.table.contract_address, house());
    f.table.withdraw_bankroll(BANKROLL);
    stop_cheat_caller_address(f.table.contract_address);

    assert!(f.table.get_bankroll() == 0);
    assert!(f.table.get_accounted() == 0);
}
