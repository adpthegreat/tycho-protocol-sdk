use substreams::store::{StoreAdd, StoreAddBigInt, StoreNew};
use substreams::{
    hex,
};
use tycho_substreams::prelude::*;
use substreams::prelude::BigInt;
use num_bigint::Sign;

#[substreams::handlers::store]
pub fn store_balances(deltas: BlockBalanceDeltas, store: StoreAddBigInt) {
    tycho_substreams::balances::store_balance_changes(deltas, store);
}