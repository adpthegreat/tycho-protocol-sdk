use substreams_ethereum::{pb::eth::v2::Log, Event};
use tycho_substreams::prelude::*;
use tycho_substreams::models::{BalanceDelta};
use crate::events::BalanceEventTrait;
use crate::{
    abi::pool::events::{Transfer},
};

impl BalanceEventTrait for Transfer {
    fn get_balance_delta(
        &self,
        tx: &Transaction,
        pool: &ProtocolComponent,
        event: &Log,
    ) -> Vec<BalanceDelta> {
        let mut changed_balances: Vec<BalanceDelta> = vec![];
        const NULL_ADDRESS: [u8; 20] = [0u8; 20];

        let pool_address = hex::decode(pool.id.trim_start_matches("0x")).unwrap();
        
        let token0 = &pool.tokens[0];
        let token1 = &pool.tokens[1];

        let from = &event.topics.get(1).unwrap()[12..];
        let to = &event.topics.get(2).unwrap()[12..];

        // --- Token0 transfers ---
        if event.address == *token0 {
            if from == pool_address {
                // token0 leaving pool
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: token0.clone(),
                    delta: self.value.neg().to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            } else if to == pool_address {
                // token0 entering pool
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: token0.clone(),
                    delta: self.value.to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            }
        };

        // --- Token1 transfers ---
        if event.address == *token1 {
            if from == pool_address {
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: token1.clone(),
                    delta: self.value.neg().clone().to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            } else if to == pool_address {
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: token1.clone(),
                    delta: self.value.clone().to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            }
        };

        //liquidity
        if event.address == pool_address {
            if to == pool_address {
                // LP tokens transferred into the pool → pool holds more LP
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: pool_address.clone(),
                    delta: self.value.to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            } else if from == pool_address {
                // LP tokens transferred out of the pool
                changed_balances.push(BalanceDelta {
                    ord: event.ordinal,
                    tx: Some(tx.clone()),
                    token: pool_address.clone(),
                    delta: self.value.neg().to_signed_bytes_be(),
                    component_id: pool_address.clone(),
                });
            }
        };

        changed_balances
    }
}