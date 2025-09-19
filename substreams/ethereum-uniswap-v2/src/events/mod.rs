pub mod transfer;

use substreams_ethereum::{pb::eth::v2::Log, Event};
use tycho_substreams::prelude::*;
use tycho_substreams::models::{BalanceDelta};

use crate::{
    store_key::StoreKey,
    abi::pool::events::{Transfer},
};


/// A trait for extracting changed balance from an event.
pub trait BalanceEventTrait {
    /// Get all balance deltas from the event.
    ///
    /// # Arguments
    ///
    /// * `tx` - Reference to the `Transaction`.
    /// * `pool` - Reference to the `Pool`.
    /// * `event` The event, we use it to access the ordinal number of the event, which is used by the balance store to sort the
    /// and the address of the event, for lp_token Transfer event tracking
    /// # Returns
    ///
    /// A vector of `BalanceDelta` that represents the balance deltas.
    fn get_balance_delta(&self, tx: &Transaction, pool: &ProtocolComponent, event: &Log)
        -> Vec<BalanceDelta>;
}

/// Represent every events of a Cow pool.
pub enum EventType {
    Transfer(Transfer),
}

impl EventType {
    fn as_event_trait(&self) -> &dyn BalanceEventTrait {
        match self {
            EventType::Transfer(event) => event,
        }
    }
}

/// Decodes the event from the log.
///
/// # Arguments
///
/// * `event` - A reference to the `Log`.
///
/// # Returns
///
/// An `Option` that contains the `EventType` if the event is recognized.
pub fn decode_event(event: &Log) -> Option<EventType> {
    [
        Transfer::match_and_decode(event).map(EventType::Transfer),
    ]
    .into_iter()
    .find_map(std::convert::identity)
}

/// Gets the changed balances from the log.
///
/// # Arguments
///
/// * `tx` - Reference to the `Transaction`.
/// * `event` - Reference to the `Log`.
/// * `pool_address` - Reference to the `Uniswap v2 pool address`.
///
/// # Returns
///
/// A vector of `BalanceDelta` that represents
pub fn get_log_changed_balances(
    tx: &Transaction,
    event: &Log,
    pool: &ProtocolComponent
) -> Vec<BalanceDelta> {
    decode_event(event)
        .map(|e| {
            e.as_event_trait()
                .get_balance_delta(tx, pool, event)
        })
        .unwrap_or_default()
}
