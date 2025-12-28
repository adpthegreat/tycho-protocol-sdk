use substreams::store::{StoreNew, StoreSetString, StoreSetIfNotExists, StoreSetIfNotExistsProto, StoreSet};
use substreams_helper::hex::Hexable;
use itertools::Itertools;
use crate::store_key::StoreKey;
use tycho_substreams::prelude::*;

#[substreams::handlers::store]
pub fn store_pools(
    pools_created: BlockChanges,
    store: StoreSetIfNotExistsProto<ProtocolComponent>,
) {
    // Store pools. Required so the next steps can match any event to a known pool by their address

    for change in pools_created.changes {
        for new_protocol_component in change.component_changes {
            //  Use ordinal 0 because the address should be unique, so ordering doesn't matter.
            store.set_if_not_exists(
                0,
                StoreKey::Pool.get_unique_pool_key(&new_protocol_component.id),
                &new_protocol_component,
            );
        }
    }
}

/// Get result `map_pools_created` and stores the created `ProtocolComponent`s with the pool id as the
/// key and tokens as the value
#[substreams::handlers::store]
pub fn store_pool_tokens(map: BlockChanges, store: StoreSetString) {
    map.changes
        .iter()
        .flat_map(|tx_changes| &tx_changes.component_changes)
        .for_each(|component| {
            store.set(
                0,
                format!("Pool:{0}", component.id),
                &component
                    .tokens
                    .iter()
                    .map(hex::encode)
                    .join(":"),
            );
        });
}
