module defi_aggregator::swap_aggregator {
    use std::signer;
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use defi_aggregator::pool;
    use defi_aggregator::pool_manager;
    use defi_aggregator::router;
    use defi_aggregator::admin;

    const E_NO_ROUTE_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_SLIPPAGE_EXCEEDED: u64 = 3;

    /// Find the best direct route and execute the swap
    public entry fun swap_best_route(
        sender: &signer,
        token_in_metadata: Object<Metadata>,
        token_out_metadata: Object<Metadata>,
        amount_in: u64,
        min_amount_out: u64,
    ) {
        admin::assert_not_paused();
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let sender_addr = signer::address_of(sender);

        // Find the best pool for this pair
        let pools = pool_manager::get_pools_for_token(token_in_metadata);
        let best_pool = @0x0;
        let best_output = 0u64;

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool_addr = *vector::borrow(&pools, i);
            let (token_x, token_y) = pool::get_token_metadata(pool_addr);

            let has_out_token = (
                object::object_address(&token_x) == object::object_address(&token_out_metadata) ||
                object::object_address(&token_y) == object::object_address(&token_out_metadata)
            );

            if (has_out_token) {
                let is_x_to_y = object::object_address(&token_x) == object::object_address(&token_in_metadata);
                let output = pool::get_amount_out(pool_addr, amount_in, is_x_to_y);
                if (output > best_output) {
                    best_output = output;
                    best_pool = pool_addr;
                };
            };

            i = i + 1;
        };

        assert!(best_pool != @0x0, E_NO_ROUTE_FOUND);
        assert!(best_output >= min_amount_out, E_SLIPPAGE_EXCEEDED);

        // Execute swap
        let token_in = primary_fungible_store::withdraw(sender, token_in_metadata, amount_in);
        let token_out = pool::swap(sender_addr, best_pool, token_in, min_amount_out);
        primary_fungible_store::deposit(sender_addr, token_out);
    }

    /// Swap with a caller-provided route (for off-chain computed routes)
    public entry fun swap_with_route(
        sender: &signer,
        pool_addrs: vector<address>,
        token_in_metadata: Object<Metadata>,
        amount_in: u64,
        min_amount_out: u64,
    ) {
        admin::assert_not_paused();
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let sender_addr = signer::address_of(sender);
        let token_in = primary_fungible_store::withdraw(sender, token_in_metadata, amount_in);

        // Build hop path
        let path = vector::empty();
        let i = 0;
        let len = vector::length(&pool_addrs);
        while (i < len) {
            let pool_addr = *vector::borrow(&pool_addrs, i);
            vector::push_back(&mut path, router::create_hop(pool_addr));
            i = i + 1;
        };

        let token_out = router::swap_exact_input_multihop(sender_addr, path, token_in, min_amount_out);
        primary_fungible_store::deposit(sender_addr, token_out);
    }

    #[view]
    public fun get_best_quote(
        token_in_metadata: Object<Metadata>,
        token_out_metadata: Object<Metadata>,
        amount_in: u64,
    ): (address, u64) {
        let pools = pool_manager::get_pools_for_token(token_in_metadata);
        let best_pool = @0x0;
        let best_output = 0u64;

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool_addr = *vector::borrow(&pools, i);
            let (token_x, token_y) = pool::get_token_metadata(pool_addr);

            let has_out_token = (
                object::object_address(&token_x) == object::object_address(&token_out_metadata) ||
                object::object_address(&token_y) == object::object_address(&token_out_metadata)
            );

            if (has_out_token) {
                let is_x_to_y = object::object_address(&token_x) == object::object_address(&token_in_metadata);
                let output = pool::get_amount_out(pool_addr, amount_in, is_x_to_y);
                if (output > best_output) {
                    best_output = output;
                    best_pool = pool_addr;
                };
            };

            i = i + 1;
        };

        (best_pool, best_output)
    }
}
