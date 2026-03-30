module defi_aggregator::pool_manager {
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_std::smart_table::{Self, SmartTable};
    use defi_aggregator::admin;
    use defi_aggregator::pool;

    friend defi_aggregator::router;
    friend defi_aggregator::detector;
    friend defi_aggregator::path_finder;
    friend defi_aggregator::swap_aggregator;
    friend defi_aggregator::executor;

    const E_ALREADY_INITIALIZED: u64 = 1;
    const E_POOL_ALREADY_EXISTS: u64 = 2;
    const E_POOL_NOT_FOUND: u64 = 3;
    const E_INVALID_TOKENS: u64 = 4;

    /// Pool pair key for lookup
    struct PoolKey has copy, drop, store {
        token_x: address,
        token_y: address,
        fee_bps: u64,
    }

    /// Global pool registry
    struct PoolRegistry has key {
        /// Map from PoolKey -> pool address
        pools: SmartTable<PoolKey, address>,
        /// All pool addresses (for iteration)
        all_pools: vector<address>,
        /// Map from token address -> list of pools containing that token
        token_pools: SmartTable<address, vector<address>>,
    }

    public entry fun initialize(admin_signer: &signer) {
        admin::assert_admin(admin_signer);
        assert!(!exists<PoolRegistry>(@defi_aggregator), E_ALREADY_INITIALIZED);

        move_to(admin_signer, PoolRegistry {
            pools: smart_table::new(),
            all_pools: vector::empty(),
            token_pools: smart_table::new(),
        });
    }

    /// Create a new pool and register it
    public entry fun create_pool(
        creator: &signer,
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        fee_bps: u64,
    ) acquires PoolRegistry {
        admin::assert_admin(creator);
        let registry = borrow_global_mut<PoolRegistry>(@defi_aggregator);

        let x_addr = object::object_address(&token_x_metadata);
        let y_addr = object::object_address(&token_y_metadata);
        assert!(x_addr != y_addr, E_INVALID_TOKENS);

        // Ensure canonical ordering (x < y)
        let (ordered_x, ordered_y, ordered_x_meta, ordered_y_meta) = if (x_addr < y_addr) {
            (x_addr, y_addr, token_x_metadata, token_y_metadata)
        } else {
            (y_addr, x_addr, token_y_metadata, token_x_metadata)
        };

        let key = PoolKey { token_x: ordered_x, token_y: ordered_y, fee_bps };
        assert!(!smart_table::contains(&registry.pools, key), E_POOL_ALREADY_EXISTS);

        let pool_addr = pool::create_pool(creator, ordered_x_meta, ordered_y_meta, fee_bps);

        // Register pool
        smart_table::add(&mut registry.pools, key, pool_addr);
        vector::push_back(&mut registry.all_pools, pool_addr);

        // Index by token
        if (!smart_table::contains(&registry.token_pools, ordered_x)) {
            smart_table::add(&mut registry.token_pools, ordered_x, vector::empty());
        };
        vector::push_back(smart_table::borrow_mut(&mut registry.token_pools, ordered_x), pool_addr);

        if (!smart_table::contains(&registry.token_pools, ordered_y)) {
            smart_table::add(&mut registry.token_pools, ordered_y, vector::empty());
        };
        vector::push_back(smart_table::borrow_mut(&mut registry.token_pools, ordered_y), pool_addr);
    }

    // ======== View Functions ========

    #[view]
    public fun get_pool(
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        fee_bps: u64,
    ): address acquires PoolRegistry {
        let registry = borrow_global<PoolRegistry>(@defi_aggregator);
        let x_addr = object::object_address(&token_x_metadata);
        let y_addr = object::object_address(&token_y_metadata);
        let (ordered_x, ordered_y) = if (x_addr < y_addr) {
            (x_addr, y_addr)
        } else {
            (y_addr, x_addr)
        };
        let key = PoolKey { token_x: ordered_x, token_y: ordered_y, fee_bps };
        assert!(smart_table::contains(&registry.pools, key), E_POOL_NOT_FOUND);
        *smart_table::borrow(&registry.pools, key)
    }

    #[view]
    public fun get_all_pools(): vector<address> acquires PoolRegistry {
        borrow_global<PoolRegistry>(@defi_aggregator).all_pools
    }

    #[view]
    public fun get_pools_for_token(token_metadata: Object<Metadata>): vector<address> acquires PoolRegistry {
        let registry = borrow_global<PoolRegistry>(@defi_aggregator);
        let token_addr = object::object_address(&token_metadata);
        if (smart_table::contains(&registry.token_pools, token_addr)) {
            *smart_table::borrow(&registry.token_pools, token_addr)
        } else {
            vector::empty()
        }
    }

    #[view]
    public fun pool_exists(
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        fee_bps: u64,
    ): bool acquires PoolRegistry {
        let registry = borrow_global<PoolRegistry>(@defi_aggregator);
        let x_addr = object::object_address(&token_x_metadata);
        let y_addr = object::object_address(&token_y_metadata);
        let (ordered_x, ordered_y) = if (x_addr < y_addr) {
            (x_addr, y_addr)
        } else {
            (y_addr, x_addr)
        };
        let key = PoolKey { token_x: ordered_x, token_y: ordered_y, fee_bps };
        smart_table::contains(&registry.pools, key)
    }

    public fun get_pool_count(): u64 acquires PoolRegistry {
        vector::length(&borrow_global<PoolRegistry>(@defi_aggregator).all_pools)
    }
}
