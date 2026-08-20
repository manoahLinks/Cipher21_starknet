//! `Cipher21Table` — the settlement core.
//!
//! This is the contract a session lives in. M1 builds it for the money loop
//! only: open a session, settle it to a final balance, pay it out. The blackjack
//! rules that decide that final balance arrive in M3 and replace
//! [`settle_session`] — everything else here is final.
//!
//! ## Why sessions have keys instead of owners
//!
//! The table must never learn which wallet is playing it. So a session is not
//! owned by an address; it is owned by a **session public key** the player
//! generates client-side and hands over at buy-in. Nothing on chain links that
//! key to the wallet that funded it, because the stake arrives as a withdrawal
//! from the STRK20 pool and the pool's withdrawals are relayed.
//!
//! Concretely, the money flows:
//!
//! ```text
//!   buy-in    pool --withdraw--> table          (public leg: amount, not player)
//!             pool --invoke----> anonymizer --> open_session(owner_key)
//!   hands     session key signs ordinary Starknet txs, no pool involvement
//!   cash-out  pool --invoke----> anonymizer --> claim_payout(id, sig)
//!             anonymizer approves the pool, pool credits an open note
//! ```
//!
//! ## What this contract deliberately does not do
//!
//! It never takes an address as an authorization. `claim_payout` and
//! `refund_session` authorize on a signature by the session key and pay to
//! `get_caller_address()`, which must be the anonymizer named at buy-in.
//!
//! ## SECURITY — unresolved before mainnet
//!
//! A claim signature is public once submitted. It authorizes a payout to the
//! session's anonymizer, and the anonymizer credits an open note to whichever
//! private transaction invoked it — so an observer who sees a claim signature
//! could in principle replay it inside their own private transaction and take
//! the note. Closing the session on first claim makes that a front-running race
//! rather than an indefinite hole, and Starknet's sequencer exposes no public
//! mempool today, but neither of those is a durable defence. Binding the
//! signature to the open-note id the pool generates is the likely fix and needs
//! to be settled with the anonymizer's design, before the audit. Tracked in
//! STRK20_INTEGRATION_PLAN.md §11.

use starknet::ContractAddress;

/// Blocks a session may sit unsettled before its owner can take the stake back.
/// An unresponsive house must never be able to strand a player's money.
pub const SESSION_TIMEOUT_BLOCKS: u64 = 7200;

/// Domain separators, so a claim signature can never be replayed as a refund.
pub const CLAIM_TAG: felt252 = 'CIPHER21_CLAIM';
pub const REFUND_TAG: felt252 = 'CIPHER21_REFUND';

#[derive(Copy, Default, Drop, PartialEq, Serde, starknet::Store)]
pub enum SessionState {
    /// No session with this id was ever opened.
    #[default]
    Nonexistent,
    /// Funded and playable. The house has not settled it.
    Open,
    /// The house has fixed the final balance. Awaiting the owner's claim.
    Settled,
    /// Paid out. Terminal.
    Closed,
    /// Timed out and the stake was taken back. Terminal.
    Refunded,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Session {
    /// STARK-curve public key that authorizes this session. Not an address.
    pub owner_key: felt252,
    /// The only contract this session will pay out to.
    pub anonymizer: ContractAddress,
    /// Chips staked at buy-in.
    pub buy_in: u256,
    /// Chips the session holds now. Equals `buy_in` until the house settles.
    pub balance: u256,
    pub opened_at: u64,
    pub state: SessionState,
}

#[starknet::interface]
pub trait ICipher21Table<T> {
    /// Opens a session over whatever chips arrived since the last accounting.
    ///
    /// The stake is not pulled — it is measured. The pool's withdraw leg
    /// transfers chips to this contract with no approval and no sender we
    /// should trust, so the buy-in is the contract's real balance minus what it
    /// already accounted for.
    fn open_session(ref self: T, owner_key: felt252, anonymizer: ContractAddress) -> u64;

    /// House-only. Fixes the session's final balance.
    ///
    /// M1 takes the outcome on trust from the house so the money loop can be
    /// proven end to end. M3 replaces this with the game's own state machine,
    /// where the balance is derived from verified hands rather than asserted.
    fn settle_session(ref self: T, session_id: u64, final_balance: u256);

    /// Pays a settled session out to the caller, which must be the anonymizer
    /// named at buy-in, on a signature by the session key.
    fn claim_payout(
        ref self: T, session_id: u64, signature_r: felt252, signature_s: felt252,
    ) -> u256;

    /// Takes back the stake of a session the house never settled, once
    /// `SESSION_TIMEOUT_BLOCKS` have passed.
    fn refund_session(
        ref self: T, session_id: u64, signature_r: felt252, signature_s: felt252,
    ) -> u256;

    /// House-only. Adds chips the table can lose to players. Requires an ERC-20
    /// approval first.
    fn fund_bankroll(ref self: T, amount: u256);

    /// House-only. Removes chips no open session has a claim on.
    fn withdraw_bankroll(ref self: T, amount: u256);

    fn get_session(self: @T, session_id: u64) -> Session;
    fn get_bankroll(self: @T) -> u256;
    fn get_accounted(self: @T) -> u256;
    fn get_min_buy_in(self: @T) -> u256;
    fn get_pool_fee(self: @T) -> u256;
    fn get_house(self: @T) -> ContractAddress;
    fn get_token(self: @T) -> ContractAddress;

    /// The message a session key signs to claim its payout. Exposed so the
    /// client signs exactly what the contract verifies.
    fn claim_hash(self: @T, session_id: u64) -> felt252;
    fn refund_hash(self: @T, session_id: u64) -> felt252;
}

#[starknet::contract]
pub mod Cipher21Table {
    use core::ecdsa::check_ecdsa_signature;
    use core::poseidon::poseidon_hash_span;
    use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{
        Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::{
        ContractAddress, get_block_number, get_caller_address, get_contract_address, get_tx_info,
    };
    use crate::constants::is_valid_buy_in;
    use super::{CLAIM_TAG, REFUND_TAG, SESSION_TIMEOUT_BLOCKS, Session, SessionState};

    #[storage]
    struct Storage {
        house: ContractAddress,
        token: ContractAddress,
        /// The pool's flat per-transaction fee, in FRI, as measured on the
        /// network this instance is deployed to. Buy-in validity is checked
        /// against it, so the floor is always right for the live fee.
        pool_fee: u256,
        /// Chips this contract believes it holds. Anything above this is an
        /// unaccounted arrival — a buy-in.
        accounted: u256,
        /// House liquidity. What a winning session is paid out of.
        bankroll: u256,
        sessions: Map<u64, Session>,
        next_session_id: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        SessionOpened: SessionOpened,
        SessionSettled: SessionSettled,
        PayoutClaimed: PayoutClaimed,
        SessionRefunded: SessionRefunded,
        BankrollFunded: BankrollFunded,
        BankrollWithdrawn: BankrollWithdrawn,
    }

    /// Carries no player identity, by construction. There is none to carry.
    #[derive(Drop, starknet::Event)]
    pub struct SessionOpened {
        #[key]
        pub session_id: u64,
        pub buy_in: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SessionSettled {
        #[key]
        pub session_id: u64,
        pub final_balance: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PayoutClaimed {
        #[key]
        pub session_id: u64,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct SessionRefunded {
        #[key]
        pub session_id: u64,
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BankrollFunded {
        pub amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    pub struct BankrollWithdrawn {
        pub amount: u256,
    }

    pub mod Errors {
        pub const NOT_HOUSE: felt252 = 'C21: caller is not the house';
        pub const NOT_ANONYMIZER: felt252 = 'C21: wrong anonymizer';
        pub const NOT_OPEN: felt252 = 'C21: session is not open';
        pub const NOT_SETTLED: felt252 = 'C21: session is not settled';
        pub const BAD_SIGNATURE: felt252 = 'C21: bad session signature';
        pub const BAD_BUY_IN: felt252 = 'C21: invalid buy-in amount';
        pub const ZERO_KEY: felt252 = 'C21: zero session key';
        pub const ZERO_ADDRESS: felt252 = 'C21: zero address';
        pub const BANKROLL_TOO_LOW: felt252 = 'C21: bankroll too low';
        pub const NOT_TIMED_OUT: felt252 = 'C21: session has not timed out';
        pub const TRANSFER_FAILED: felt252 = 'C21: token transfer failed';
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, house: ContractAddress, token: ContractAddress, pool_fee: u256,
    ) {
        assert(house.into() != 0_felt252, Errors::ZERO_ADDRESS);
        assert(token.into() != 0_felt252, Errors::ZERO_ADDRESS);
        self.house.write(house);
        self.token.write(token);
        self.pool_fee.write(pool_fee);
        self.next_session_id.write(1);
    }

    #[abi(embed_v0)]
    impl Cipher21TableImpl of super::ICipher21Table<ContractState> {
        fn open_session(
            ref self: ContractState, owner_key: felt252, anonymizer: ContractAddress,
        ) -> u64 {
            assert(owner_key != 0, Errors::ZERO_KEY);
            assert(anonymizer.into() != 0_felt252, Errors::ZERO_ADDRESS);

            let buy_in = self.unaccounted();
            assert(is_valid_buy_in(buy_in, self.pool_fee.read()), Errors::BAD_BUY_IN);

            let session_id = self.next_session_id.read();
            self.next_session_id.write(session_id + 1);
            self.accounted.write(self.accounted.read() + buy_in);

            self
                .sessions
                .entry(session_id)
                .write(
                    Session {
                        owner_key,
                        anonymizer,
                        buy_in,
                        balance: buy_in,
                        opened_at: get_block_number(),
                        state: SessionState::Open,
                    },
                );

            self.emit(SessionOpened { session_id, buy_in });
            session_id
        }

        fn settle_session(ref self: ContractState, session_id: u64, final_balance: u256) {
            self.assert_house();
            let mut session = self.sessions.entry(session_id).read();
            assert(session.state == SessionState::Open, Errors::NOT_OPEN);

            // The bankroll absorbs the difference in both directions: it pays
            // for a win and takes in a loss.
            let bankroll = self.bankroll.read();
            if final_balance > session.buy_in {
                let owed = final_balance - session.buy_in;
                assert(bankroll >= owed, Errors::BANKROLL_TOO_LOW);
                self.bankroll.write(bankroll - owed);
            } else {
                self.bankroll.write(bankroll + (session.buy_in - final_balance));
            }

            session.balance = final_balance;
            session.state = SessionState::Settled;
            self.sessions.entry(session_id).write(session);

            self.emit(SessionSettled { session_id, final_balance });
        }

        fn claim_payout(
            ref self: ContractState, session_id: u64, signature_r: felt252, signature_s: felt252,
        ) -> u256 {
            let mut session = self.sessions.entry(session_id).read();
            assert(session.state == SessionState::Settled, Errors::NOT_SETTLED);
            assert(get_caller_address() == session.anonymizer, Errors::NOT_ANONYMIZER);
            assert(
                check_ecdsa_signature(
                    self.claim_hash(session_id), session.owner_key, signature_r, signature_s,
                ),
                Errors::BAD_SIGNATURE,
            );

            let amount = session.balance;
            session.balance = 0;
            session.state = SessionState::Closed;
            self.sessions.entry(session_id).write(session);

            self.pay_out(amount);
            self.emit(PayoutClaimed { session_id, amount });
            amount
        }

        fn refund_session(
            ref self: ContractState, session_id: u64, signature_r: felt252, signature_s: felt252,
        ) -> u256 {
            let mut session = self.sessions.entry(session_id).read();
            assert(session.state == SessionState::Open, Errors::NOT_OPEN);
            assert(get_caller_address() == session.anonymizer, Errors::NOT_ANONYMIZER);
            assert(
                get_block_number() >= session.opened_at + SESSION_TIMEOUT_BLOCKS,
                Errors::NOT_TIMED_OUT,
            );
            assert(
                check_ecdsa_signature(
                    self.refund_hash(session_id), session.owner_key, signature_r, signature_s,
                ),
                Errors::BAD_SIGNATURE,
            );

            // A refund returns the stake untouched — the house never settled,
            // so the bankroll neither won nor lost anything.
            let amount = session.balance;
            session.balance = 0;
            session.state = SessionState::Refunded;
            self.sessions.entry(session_id).write(session);

            self.pay_out(amount);
            self.emit(SessionRefunded { session_id, amount });
            amount
        }

        fn fund_bankroll(ref self: ContractState, amount: u256) {
            self.assert_house();
            let ok = IERC20Dispatcher { contract_address: self.token.read() }
                .transfer_from(get_caller_address(), get_contract_address(), amount);
            assert(ok, Errors::TRANSFER_FAILED);
            self.bankroll.write(self.bankroll.read() + amount);
            self.accounted.write(self.accounted.read() + amount);
            self.emit(BankrollFunded { amount });
        }

        fn withdraw_bankroll(ref self: ContractState, amount: u256) {
            self.assert_house();
            let bankroll = self.bankroll.read();
            assert(bankroll >= amount, Errors::BANKROLL_TOO_LOW);
            self.bankroll.write(bankroll - amount);
            self.accounted.write(self.accounted.read() - amount);
            let ok = IERC20Dispatcher { contract_address: self.token.read() }
                .transfer(get_caller_address(), amount);
            assert(ok, Errors::TRANSFER_FAILED);
            self.emit(BankrollWithdrawn { amount });
        }

        fn get_session(self: @ContractState, session_id: u64) -> Session {
            self.sessions.entry(session_id).read()
        }

        fn get_bankroll(self: @ContractState) -> u256 {
            self.bankroll.read()
        }

        fn get_accounted(self: @ContractState) -> u256 {
            self.accounted.read()
        }

        fn get_min_buy_in(self: @ContractState) -> u256 {
            crate::constants::BUY_IN_MIN
        }

        fn get_pool_fee(self: @ContractState) -> u256 {
            self.pool_fee.read()
        }

        fn get_house(self: @ContractState) -> ContractAddress {
            self.house.read()
        }

        fn get_token(self: @ContractState) -> ContractAddress {
            self.token.read()
        }

        fn claim_hash(self: @ContractState, session_id: u64) -> felt252 {
            self.authorization_hash(CLAIM_TAG, session_id)
        }

        fn refund_hash(self: @ContractState, session_id: u64) -> felt252 {
            self.authorization_hash(REFUND_TAG, session_id)
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn assert_house(self: @ContractState) {
            assert(get_caller_address() == self.house.read(), Errors::NOT_HOUSE);
        }

        /// Chips sitting here that no session and no bankroll has claimed yet.
        fn unaccounted(self: @ContractState) -> u256 {
            let held = IERC20Dispatcher { contract_address: self.token.read() }
                .balance_of(get_contract_address());
            let accounted = self.accounted.read();
            if held <= accounted {
                0
            } else {
                held - accounted
            }
        }

        fn pay_out(ref self: ContractState, amount: u256) {
            self.accounted.write(self.accounted.read() - amount);
            let ok = IERC20Dispatcher { contract_address: self.token.read() }
                .transfer(get_caller_address(), amount);
            assert(ok, Errors::TRANSFER_FAILED);
        }

        /// Bound to the tag, the chain and this table, so a signature is
        /// useless anywhere else — a different network, a different deployment,
        /// or the other of the two authorizations.
        fn authorization_hash(self: @ContractState, tag: felt252, session_id: u64) -> felt252 {
            poseidon_hash_span(
                array![
                    tag, get_tx_info().unbox().chain_id, get_contract_address().into(),
                    session_id.into(),
                ]
                    .span(),
            )
        }
    }
}
