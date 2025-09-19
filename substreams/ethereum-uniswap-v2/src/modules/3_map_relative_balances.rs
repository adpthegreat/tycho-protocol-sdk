use crate::{
    events::get_log_changed_balances, 
    abi::pool::events::{Transfer, Sync}, store_key::StoreKey, traits::PoolAddresser
};
use anyhow::{Ok, Result};
use substreams::{prelude::StoreGetProto, store::StoreGet};
use substreams_ethereum::pb::eth::v2::Block;
use substreams_helper::hex::Hexable;
use tycho_substreams::prelude::*;

//map all the relative balances in a block for the lp token supply 
#[substreams::handlers::map]
pub fn map_relative_balances(
    block: Block,
    store: StoreGetProto<ProtocolComponent>,
) -> Result<BlockBalanceDeltas, anyhow::Error> {
    let mut balance_deltas = Vec::new();
    for trx in block.transactions() {
        let mut tx_deltas = Vec::new();
        for log in trx
            .calls
            .iter()
            .filter(|call| !call.state_reverted)
            .flat_map(|call| &call.logs)
        {
            let pool = store.must_get_last(StoreKey::Pool.get_unique_pool_key(&log.address.to_hex()));
            tx_deltas.extend(get_log_changed_balances(&trx.into(), log, &pool));
        }
        if !tx_deltas.is_empty() {
            balance_deltas.extend(tx_deltas);
        }
    }
    Ok(BlockBalanceDeltas { balance_deltas })
}