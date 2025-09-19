pub use map_pool_created::map_pools_created;
pub use store_pools::store_pools;
pub use map_relative_balances::map_relative_balances;
pub use store_balances::store_balances;
pub use map_pool_events::map_pool_events;
use substreams_ethereum::pb::eth::v2::TransactionTrace;
use crate::pb::tycho::evm::uniswap::v2::Transaction;

#[path = "1_map_pool_created.rs"]
mod map_pool_created;
#[path = "2_store_pools.rs"]
mod store_pools;

#[path = "3_map_relative_balances.rs"]
mod map_relative_balances;

#[path = "4_store_balances.rs"]
mod store_balances;

#[path = "5_map_pool_events.rs"]
mod map_pool_events;
