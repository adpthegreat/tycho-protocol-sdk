use itertools::Itertools;
use std::collections::{HashMap, HashSet}; 
use substreams::store::{StoreGet, StoreGetProto};
use substreams_ethereum::pb::eth::v2::{self as eth};
use substreams_helper::{event_handler::EventHandler, hex::Hexable};
use crate::{abi::pool::events::{Transfer, Sync}, store_key::StoreKey, traits::PoolAddresser};
use tycho_substreams::{
    entrypoint::create_entrypoint,
    models::entry_point_params::TraceData,
    prelude::*,
};
use substreams::prelude::StoreGetBigInt;

// Auxiliary struct to serve as a key for the HashMaps.
#[derive(Clone, Hash, Eq, PartialEq)]
struct ComponentKey<T> {
    component_id: String,
    name: T, 
}

impl<T> ComponentKey<T> {
    fn new(component_id: String, name: T) -> Self {
        ComponentKey { component_id, name }
    }
}

#[derive(Clone)]
struct PartialChanges {
    transaction: Transaction,
    entity_changes: HashMap<ComponentKey<String>, Attribute>,
    balance_changes: HashMap<ComponentKey<Vec<u8>>, BalanceChange>,
    // na we cant do this because we are doing it for each component created , not per tx 
    // entrypoints: HashSet<EntryPoint>,
    // entrypoint_params: HashSet<EntryPointParams>,
}
//refactor to use Protocol Changes One day 
impl PartialChanges {
    // Consolidate the entity changes into a vector of EntityChanges. Initially, the entity changes
    // are in a map to prevent duplicates. For each transaction, we need to have only one final
    // state change, per state. Example:
    // If we have two sync events for the same pool (in the same tx), we need to have only one final
    // state change for the reserves. This will be the last sync event, as it is the final state
    // of the pool after the transaction.
    fn consolidate_entity_changes(self) -> Vec<EntityChanges> {
        self.entity_changes
            .into_iter()
            .map(|(key, attribute)| (key.component_id, attribute)) 
            .into_group_map()
            .into_iter()
            .map(|(component_id, attributes)| EntityChanges { component_id, attributes })
            .collect()
    }
}

#[substreams::handlers::map]
pub fn map_pool_events(
    block: eth::Block,
    block_entity_changes: BlockChanges,
    pools_store: StoreGetProto<ProtocolComponent>,
    balance_store:
    // balance_deltas: BlockBalanceDeltas 
) -> Result<BlockChanges, substreams::errors::Error> {
    // Sync event is sufficient for our use-case. Since it's emitted on every reserve-altering
    // function call, we can use it as the only event to update the reserves of a pool.
    let mut block_entity_changes = block_entity_changes;
    let mut tx_changes: HashMap<Vec<u8>, PartialChanges> = HashMap::new();
    //Basically, the operation is as so ->
    //Get all the balance deltas from a tx 
    //accumulate the balance deltas for a tx 
    //assign 

    // // Build a map of cumulative balances per transaction so the right balance can be emitted 
    // // Key: "pool_id:token" -> Vec of (ord, cumulative_balance)
    // let mut balance_map: HashMap<String, Vec<(u64, BigInt)>> = HashMap::new();

    // // Sort deltas by ord to process them in transaction order
    // let mut sorted_deltas = balance_deltas.balance_deltas.clone();
    // sorted_deltas.sort_by_key(|d| d.ord);

    // // Build cumulative balances
    // for delta in sorted_deltas {
    //     let component_id = String::from_utf8(delta.component_id.clone())
    //         .expect("component_id is not valid utf-8");
    //     let key = format!("{}:{}", component_id, hex::encode(&delta.token));
        
    //     let delta_value = BigInt::from_signed_bytes_be(&delta.delta);
        
    //     balance_map
    //         .entry(key.clone())
    //         .and_modify(|entries| {
    //             let last_balance = entries.last().map(|(_, bal)| bal.clone()).unwrap_or(BigInt::zero());
    //             let new_balance = last_balance + delta_value.clone();
    //             entries.push((delta.ord, new_balance));
    //         })
    //         .or_insert_with(|| vec![(delta.ord, delta_value)]);
    // }

    handle_sync(&block, &mut tx_changes, &pools_store);
    handle_transfers(&block, &mut tx_changes, &pools_store, balance_store);
    // handle_transfers(&block, &mut tx_changes, &pools_store, balance_map);

    merge_block(&mut tx_changes, &mut block_entity_changes);

    Ok(block_entity_changes)
}

/// Handle the sync events and update the reserves of the pools.
///
/// This function is called for each block, and it will handle the sync events for each transaction.
/// On UniswapV2, Sync events are emitted on every reserve-altering function call, so we can use
/// only this event to keep track of the pool state.
///
/// This function also relies on an intermediate HashMap to store the changes for each transaction.
/// This is necessary because we need to consolidate the changes for each transaction before adding
/// them to the block_entity_changes. This HashMap prevents us from having duplicate changes for the
/// same pool and token. See the PartialChanges struct for more details.
fn handle_sync(
    block: &eth::Block,
    tx_changes: &mut HashMap<Vec<u8>, PartialChanges>,
    store: &StoreGetProto<ProtocolComponent>,
) {
    let mut on_sync = |event: Sync, _tx: &eth::TransactionTrace, _log: &eth::Log| {
        let pool_address_hex = _log.address.to_hex();

        let pool =
            store.must_get_last(StoreKey::Pool.get_unique_pool_key(pool_address_hex.as_str()));
        // Convert reserves to bytes
        let reserves_bytes = [event.reserve0, event.reserve1];

        let tx_change = tx_changes
            .entry(_tx.hash.clone())
            .or_insert_with(|| PartialChanges {
                transaction: _tx.into(),
                entity_changes: HashMap::new(),
                balance_changes: HashMap::new(),
            });

        for (i, reserve_bytes) in reserves_bytes.iter().enumerate() {
            let attribute_name = format!("reserve{}", i);
            // By using a HashMap, we can overwrite the previous value of the reserve attribute if
            // it is for the same pool and the same attribute name (reserves).
            tx_change.entity_changes.insert(
                ComponentKey::new(pool_address_hex.clone(), attribute_name.clone()),
                Attribute {
                    name: attribute_name,  
                    value: reserve_bytes
                        .clone()
                        .to_signed_bytes_be(),
                    change: ChangeType::Update.into(),
                },
            );
        }

        // Update balance changes for each token
        for (index, token) in pool.tokens[..2].iter().enumerate() { 
            let balance = &reserves_bytes[index];
            // HashMap also prevents having duplicate balance changes for the same pool and token.
            tx_change.balance_changes.insert(
                ComponentKey::new(pool_address_hex.clone(), token.clone()),
                BalanceChange {
                    token: token.clone(),
                    balance: balance.clone().to_signed_bytes_be(),
                    component_id: pool_address_hex.as_bytes().to_vec(),
                },
            );
        }
    };

    let mut eh = EventHandler::new(block);
    // Filter the sync events by the pool address, to make sure we don't process events for other
    // Protocols that use the same event signature.
    eh.filter_by_address(PoolAddresser { store });
    eh.on::<Sync, _>(&mut on_sync);
    eh.handle_events();
}


//the whole data transformation pipeline that happens for the stores and maps is block by block, 
// so it runs all the modules for one block, then repeats for the next one 

fn handle_transfers(
    block:&eth::Block,
    tx_changes: &mut HashMap<Vec<u8>, PartialChanges>,
    store: &StoreGetProto<ProtocolComponent>,
    balance_store: StoreGetBigInt
) {
    //filters transfers by pool address so that means it'll only filter txs that have an LP Token transfer (LP Token transfer is the same)
    //and thats the only time it'll update the balances and we'll see balance0 and balance1 
    //see pool 
    //get the last balance -> update the last balance
    //add to entity changes 

    //issue with this is that interim txs in the block will register the final balance 
    //of the pool at the end of the block, with the actual reserves at that point 
    //which is an actual issue 
    let mut on_transfer = |event: Transfer, tx: &eth::TransactionTrace, log: &eth::Log| {
        let pool_address = &log.address;
        //when i used pool_address_hex as 
        // let pool_address_hex = pool_address.clone().to_hex();

        //the problem with this if there are multiple balance changes to a pool in the same block
        //it registers the same thing as the latest change 

        //some balances are the same as the reserve , some are not 
         // Check if either 'to' or 'from' address is a pool
        let to_hex = event.to.to_hex();
        let from_hex = event.from.to_hex();

        let pool = [&to_hex, &from_hex]
            .iter()
            .find_map(|addr| store.get_last(StoreKey::Pool.get_unique_pool_key(addr.as_str())));

        if let Some(pool) = pool {
            let mut entity_changes: Vec<Attribute> = vec![];
            let attr_names = vec!["balance0", "balance1", "liquidity"];

            let token0 = &pool.tokens[0];
            let token1 = &pool.tokens[1];

            // // Helper function to get balance at specific ordinal
            //     let get_balance_at_ord = |key: &str, ord: u64| -> Option<BigInt> {
            //         balance_map.get(key).and_then(|entries| {
            //             // Find the last entry with ord <= tx_ord
            //             entries
            //                 .iter()
            //                 .rev()
            //                 .find(|(entry_ord, _)| *entry_ord <= ord)
            //                 .map(|(_, balance)| balance.clone())
            //         })
            //     };

            //     let key_token0 = format!("{}:{}", pool_id, hex::encode(&token0));
            //     let key_token1 = format!("{}:{}", pool_id, hex::encode(&token1));
            //     let key_liquidity = format!("{}:{}", pool_id, pool_id);

            //     let token0_balance = get_balance_at_ord(&key_token0, tx_ord);
            //     let token1_balance = get_balance_at_ord(&key_token1, tx_ord);
            //     let liquidity_balance = get_balance_at_ord(&key_liquidity, tx_ord);
            //pool id is the string version of the address with "0x"
            //balance delta component id does not have "0x"
            let pool_id = pool.id.trim_start_matches("0x");

            let token0_balance = balance_store.get_last(format!(
                "{0}:{1}",
                &pool_id,
                hex::encode(&token0)
            ));

            let token1_balance = balance_store.get_last(format!(
                "{0}:{1}",
                &pool_id,
                hex::encode(&token1)
            ));
            //liquidity - the amount of lp tokens in the contract 
            let liquidity_balance = balance_store.get_last(format!(
                "{0}:{1}",
                &pool_id,
                &pool_id // pool and token address is the same
            ));
 
            // 1. Construct the keys first
            let key_token0 = format!("{}:{}", &pool_id, hex::encode(&token0));
            let key_token1 = format!("{}:{}", &pool_id, hex::encode(&token1));
            let key_liquidity = format!("{}:{}", &pool_id, &pool_id);

            // 2. Log them
            substreams::log::info!("Store Keys -> Token0: {}, Token1: {}, Liquidity: {}", key_token0, key_token1, key_liquidity);
            substreams::log::info!(
                "token 0 balance {:?}", token0_balance
            );
            
            substreams::log::info!(
                "token 1 balance {:?}",
                token1_balance,
            );
            
            substreams::log::info!(
                "liquidity balance {:?}", liquidity_balance
            );

            let pool_address_utf8 = pool
                .id
                .clone()
                .as_bytes()
                .to_vec();

            //the problem with the delta returning a tuple of the sign and the Vec<u8> 
            //is the there is a possibility of the delta to be negative 
            //in the entity changes the reserves are being updated but not the balances and liquidity 

                if let Some(bal) = token0_balance {
                    entity_changes.push(Attribute {
                        name: attr_names[0].to_string(),
                        value: bal.to_signed_bytes_be(),
                        change: ChangeType::Update.into(),
                    });
                }

                if let Some(bal) = token1_balance {
                    entity_changes.push(Attribute {
                        name: attr_names[1].to_string(),
                        value: bal.to_signed_bytes_be(),
                        change: ChangeType::Update.into(),
                    });
                }

                if let Some(bal) = liquidity_balance {
                    entity_changes.push(Attribute {
                        name: attr_names[2].to_string(),
                        value: bal.to_signed_bytes_be(),
                        change: ChangeType::Update.into(),
                    });
                }
                let tx_change = tx_changes
                    .entry(tx.hash.clone())
                .or_insert_with(|| PartialChanges {
                    transaction: tx.into(),
                    entity_changes: HashMap::new(),
                    balance_changes: HashMap::new(), 
                });

            for (index, entity) in entity_changes.iter().enumerate() {
                tx_change.entity_changes.insert(
                    ComponentKey::new(pool.id.to_string().clone(), attr_names[index].to_string().clone()),
                    entity.clone()
                );
            }
        }
    };

    let mut eh = EventHandler::new(block);

    eh.on::<Transfer, _>(&mut on_transfer);
    eh.handle_events();
}


/// Merge the changes from the sync events with the create_pool events and the transfer events previously mapped on
/// block_entity_changes.
///
/// Parameters:
/// - tx_changes: HashMap with the changes for each transaction. This is the same HashMap used in
///   handle_sync
/// - block_entity_changes: The BlockChanges struct that will be updated with the changes from the
///   sync events.
///
/// This HashMap comes pre-filled with the changes for the create_pool events, mapped in
///   1_map_pool_created.
///
/// This function is called after the handle_sync function, and it is expected that
/// block_entity_changes will be complete after this function ends.
fn merge_block(
    tx_changes: &mut HashMap<Vec<u8>, PartialChanges>,
    block_entity_changes: &mut BlockChanges,
) {
    let mut tx_entity_changes_map = HashMap::new();

    let trace_data = TraceData::Rpc(RpcTraceData {
        caller: None,
        calldata: hex::decode("18160ddd").unwrap(), // totalSupply()
    });

    // let mut entrypoints = HashSet::new();
    // let mut entrypoint_params = HashSet::new();

    // Add created pools to the tx_changes_map
    for change in block_entity_changes
        .changes
        .clone()
        .into_iter()
    {
        let transaction = change.tx.as_ref().unwrap();
        tx_entity_changes_map
            .entry(transaction.hash.clone())
            .and_modify(|c: &mut TransactionChanges| {
                c.component_changes
                    .extend(change.component_changes.clone());
                c.entity_changes
                    .extend(change.entity_changes.clone());
                let _= change.component_changes.iter().for_each(|component| {
                     //Get the totalSupply() of lp tokens using DCI entrypoint
                    let (entrypoint, entrypoint_params) = create_entrypoint(
                        component
                            .id
                            .clone()
                            .as_bytes()
                            .to_vec(),
                        "totalSupply()".to_string(),
                        component.id.clone(), //string 
                        trace_data.clone(),
                    );
                    c.entrypoints.push(entrypoint);
                    c.entrypoint_params.push(entrypoint_params);
                });
            })
            .or_insert(change);
    }

    // First, iterate through the previously created transactions, extracted from the
    // map_pool_created step. If there are sync events for this transaction, add them to the
    // block_entity_changes and the corresponding balance changes.
    for change in tx_entity_changes_map.values_mut() {
        let tx = change
            .clone()
            .tx
            .expect("Transaction not found")
            .clone();

        // If there are sync events for this transaction, add them to the block_entity_changes
        // If we update the same partial_changes hashmap too, then we should also add the balance_changes for the transfer events -> huh? na
        if let Some(partial_changes) = tx_changes.remove(&tx.hash) {
            change.entity_changes = partial_changes
                .clone()
                .consolidate_entity_changes();
            change.balance_changes = partial_changes
                .balance_changes
                .into_values()
                .collect();
        }
    };

    // If there are any transactions left in the tx_changes, it means that they are transactions
    // that changed the state of the pools, but were not included in the block_entity_changes.
    // This happens for every regular transaction that does not actually create a pool. By the
    // end of this function, we expect block_entity_changes to be up-to-date with the changes
    // for all sync and new_pools in the block.
    for partial_changes in tx_changes.values() {
        tx_entity_changes_map.insert(
            partial_changes.transaction.hash.clone(),
            TransactionChanges {
                tx: Some(partial_changes.transaction.clone()),
                contract_changes: vec![],
                entity_changes: partial_changes
                    .clone()
                    .consolidate_entity_changes(),
                balance_changes: partial_changes
                    .balance_changes
                    .clone()
                    .into_values()
                    .collect(),
                component_changes: vec![],
                entrypoints: vec![],
                entrypoint_params: vec![],
            },
        );
    };


    block_entity_changes.changes = tx_entity_changes_map
        .into_values()
        .collect();
}


