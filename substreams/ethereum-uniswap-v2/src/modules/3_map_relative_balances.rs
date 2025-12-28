use crate::{
    abi::pool::events::{Transfer, Sync}, store_key::StoreKey, traits::PoolAddresser
};
use anyhow::{Ok, Result};
use substreams::{prelude::{StoreGetString,StoreGetProto}, store::StoreGet};
use substreams_ethereum::pb::eth::v2::Block;
use substreams_helper::hex::Hexable;
use tycho_substreams::{
    balances::{extract_balance_deltas_from_tx},
    prelude::*,
};


//map all the relative balances in a block for the lp token supply and the balances for both tokens in the contract 
#[substreams::handlers::map]
pub fn map_relative_balances(
    block: Block,
    store: StoreGetProto<ProtocolComponent>,
    tokens_store: StoreGetString
) -> Result<BlockBalanceDeltas, anyhow::Error> {
     let mut balance_deltas = Vec::new();
     let mut deltas: Vec<BalanceDelta> = block
        .transactions()
        .flat_map(|tx| {
                extract_balance_deltas_from_tx(tx, |token, transactor| {
                    let pool_key = format!("Pool:{}", format!("0x{}", hex::encode(transactor)));
                    if let Some(tokens) = tokens_store.get_last(pool_key) {
                        let token_id = hex::encode(token);
                        tokens.split(':').any(|t| t == token_id) || token_id == hex::encode(transactor) //lp_token case 
                    } else {
                        false
                    }
                })
                .into_iter().collect::<Vec<_>>()
        })
        .collect();

    // Keep it consistent with how it's inserted in the store. This step is important
    // because we use a zip on the store deltas and balance deltas later.
    deltas.sort_unstable_by(|a, b| a.ord.cmp(&b.ord));

    if !deltas.is_empty(){
        balance_deltas.extend(deltas.clone());
    }

    Ok(BlockBalanceDeltas { balance_deltas })
}

//in the tx objects of the BalanceDeltas you may notice that to == 0x7a250d5630b4cf539739df2c5dacb4c659f2488d 
//instead of the pool address, this is the UniV2 Router address

//Q - should i modify the tx.to to make it the actual pool address in the balance delta tx field 

//map balance deltas by tx then get 