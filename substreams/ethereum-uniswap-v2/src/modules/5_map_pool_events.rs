use itertools::Itertools;
use std::collections::{HashMap, HashSet}; 
use substreams::store::{StoreGet, StoreGetProto};
use substreams_ethereum::pb::eth::v2::{self as eth};
use substreams_helper::{event_handler::EventHandler, hex::Hexable};
use crate::{events::get_log_changed_balances};
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
    balance_store: StoreGetBigInt
) -> Result<BlockChanges, substreams::errors::Error> {
    // Sync event is sufficient for our use-case. Since it's emitted on every reserve-altering
    // function call, we can use it as the only event to update the reserves of a pool.
    let mut block_entity_changes = block_entity_changes;
    let mut tx_changes: HashMap<Vec<u8>, PartialChanges> = HashMap::new();

    handle_sync(&block, &mut tx_changes, &pools_store);
    handle_transfers(&block, &mut tx_changes, &pools_store, balance_store);

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
    let mut on_transfer = |event: Transfer, tx: &eth::TransactionTrace, log: &eth::Log| {
        let pool_address = &log.address;
        let pool_address_hex = pool_address.clone().to_hex();

        let pool = store.must_get_last(StoreKey::Pool.get_unique_pool_key(pool_address_hex.as_str()));
        let mut entity_changes: Vec<Attribute> = vec![];
        let attr_names = vec!["balance0", "balance1", "liquidity"];

        let token0 = &pool.tokens[0];
        let token1 = &pool.tokens[1];

        if !(get_log_changed_balances(&tx.into(), log, &pool).is_empty()) {

            let token0_balance = balance_store.get_last(format!(
                "pool:{0}:token:{1}",
                hex::encode(&pool.id),
                hex::encode(&token0)
            ));

            let token1_balance = balance_store.get_last(format!(
                "pool:{0}:token:{1}",
                hex::encode(&pool.id),
                hex::encode(&token1)
            ));
            //liquidity - the amount of lp tokens in the contract 
            let liquidity_balance = balance_store.get_last(format!(
                "pool:{0}:token:{1}",
                hex::encode(&pool.id),
                hex::encode(&pool.id) // pool and token is the same
            ));
           
            let pool_address_utf8 = pool
                .id
                .clone()
                .as_bytes()
                .to_vec();

            //the problem with the delta returning a tuple of the sign and the Vec<u8> 
            //is the there is a possibility of the delta to be negative 
            let updated_balance0 = Attribute {
                    name: attr_names[0].to_string(),
                    value:  token0_balance.unwrap().to_signed_bytes_be(),
                    change: ChangeType::Update.into(),
            };
            let updated_balance1 = Attribute {
                    name: attr_names[1].to_string(),
                    value:  token1_balance.unwrap().to_signed_bytes_be(),
                    change: ChangeType::Update.into(),
            };
            let updated_liquidity = Attribute {
                    name: attr_names[2].to_string(),
                    value: liquidity_balance.unwrap().to_signed_bytes_be(),
                    change: ChangeType::Update.into(),
            };

            entity_changes.extend([updated_balance0, updated_balance1, updated_liquidity]);
        };

        let tx_change = tx_changes
            .entry(tx.hash.clone())
            .or_insert_with(|| PartialChanges {
                transaction: tx.into(),
                entity_changes: HashMap::new(),
                balance_changes: HashMap::new(), 
            });

        for (index, entity) in entity_changes.iter().enumerate() {
             tx_change.entity_changes.insert(
                ComponentKey::new(pool_address_hex.clone(), attr_names[index].to_string().clone()),
                entity.clone()
            );
        }
    };

    let mut eh = EventHandler::new(block);
    // Filter the Transfer events by the pool address, to make sure we don't process events for other
    // Protocols that use the same event signature.
    eh.filter_by_address(PoolAddresser { store });
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
        calldata: hex::decode("0x18160ddd").unwrap(), // totalSupply()
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
        // If we update the same partial_changes hashmap too, then we should also add the balance_changes for the transfer events -> huh?
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


