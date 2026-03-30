module defi_aggregator::master_router {
    use std::signer;
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use defi_aggregator::pool;
    use defi_aggregator::pool_manager;
    use defi_aggregator::router;
    use defi_aggregator::lending_pool;
    use defi_aggregator::collateral_manager;
    use defi_aggregator::admin;

    const E_NO_ROUTE_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_SLIPPAGE_EXCEEDED: u64 = 3;
    const E_LEVERAGE_TOO_HIGH: u64 = 4;
    const E_UNHEALTHY_AFTER_LEVERAGE: u64 = 5;

    /// Maximum leverage: 5x (50000 bps)
    const MAX_LEVERAGE_BPS: u64 = 50000;

    /// Smart swap: finds the best route across all DEX pools
    /// Tries direct route first, then 2-hop routes
    public entry fun smart_swap(
        sender: &signer,
        token_in_metadata: Object<Metadata>,
        token_out_metadata: Object<Metadata>,
        amount_in: u64,
        min_amount_out: u64,
    ) {
        admin::assert_not_paused();
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let sender_addr = signer::address_of(sender);

        // Try direct route first
        let (best_pool, best_output) = find_best_direct_route(
            token_in_metadata,
            token_out_metadata,
            amount_in,
        );

        // Try 2-hop routes through common intermediaries
        let (two_hop_pools, two_hop_output) = find_best_two_hop_route(
            token_in_metadata,
            token_out_metadata,
            amount_in,
        );

        let token_in = primary_fungible_store::withdraw(sender, token_in_metadata, amount_in);

        if (two_hop_output > best_output && vector::length(&two_hop_pools) == 2) {
            // Use 2-hop route
            let path = vector::empty();
            let i = 0;
            while (i < vector::length(&two_hop_pools)) {
                vector::push_back(&mut path, router::create_hop(*vector::borrow(&two_hop_pools, i)));
                i = i + 1;
            };
            let token_out = router::swap_exact_input_multihop(sender_addr, path, token_in, min_amount_out);
            primary_fungible_store::deposit(sender_addr, token_out);
        } else if (best_pool != @0x0) {
            // Use direct route
            let token_out = pool::swap(sender_addr, best_pool, token_in, min_amount_out);
            primary_fungible_store::deposit(sender_addr, token_out);
        } else {
            // No route found - abort
            primary_fungible_store::deposit(sender_addr, token_in);
            abort E_NO_ROUTE_FOUND
        };
    }

    /// Leveraged position: supply collateral -> borrow -> swap -> supply again
    /// Creates a leveraged long position on collateral_asset
    public entry fun leverage_long(
        user: &signer,
        collateral_market_addr: address,
        borrow_market_addr: address,
        swap_pool_addr: address,
        initial_amount: u64,
        leverage_bps: u64, // e.g., 20000 = 2x
    ) {
        admin::assert_not_paused();
        assert!(initial_amount > 0, E_ZERO_AMOUNT);
        assert!(leverage_bps <= MAX_LEVERAGE_BPS, E_LEVERAGE_TOO_HIGH);

        let user_addr = signer::address_of(user);
        let collateral_metadata = lending_pool::get_market_asset_metadata(collateral_market_addr);
        let _borrow_metadata = lending_pool::get_market_asset_metadata(borrow_market_addr);

        // Step 1: Supply initial collateral
        let initial_collateral = primary_fungible_store::withdraw(user, collateral_metadata, initial_amount);
        lending_pool::supply(user, collateral_market_addr, initial_collateral);
        lending_pool::enable_collateral(user, collateral_market_addr);

        // Step 2: Calculate borrow amount based on leverage
        // For 2x leverage, borrow = initial_amount * (leverage - 1)
        let borrow_ratio = leverage_bps - 10000; // e.g., 20000 - 10000 = 10000 = 1x additional
        let borrow_amount = (initial_amount as u128) * (borrow_ratio as u128) / 10000;

        // Step 3: Borrow
        let borrowed = lending_pool::borrow(user, borrow_market_addr, (borrow_amount as u64));

        // Step 4: Swap borrowed asset to collateral asset
        let swapped = pool::swap(user_addr, swap_pool_addr, borrowed, 0);

        // Step 5: Supply swapped tokens as additional collateral
        lending_pool::supply(user, collateral_market_addr, swapped);

        // Step 6: Verify health factor is ok
        collateral_manager::assert_healthy(user_addr);
    }

    // ======== Internal Helpers ========

    fun find_best_direct_route(
        token_in: Object<Metadata>,
        token_out: Object<Metadata>,
        amount_in: u64,
    ): (address, u64) {
        let pools = pool_manager::get_pools_for_token(token_in);
        let best_pool = @0x0;
        let best_output = 0u64;

        let i = 0;
        let len = vector::length(&pools);
        while (i < len) {
            let pool_addr = *vector::borrow(&pools, i);
            let (token_x, token_y) = pool::get_token_metadata(pool_addr);

            let has_out = (
                object::object_address(&token_x) == object::object_address(&token_out) ||
                object::object_address(&token_y) == object::object_address(&token_out)
            );

            if (has_out) {
                let is_x_to_y = object::object_address(&token_x) == object::object_address(&token_in);
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

    fun find_best_two_hop_route(
        token_in: Object<Metadata>,
        token_out: Object<Metadata>,
        amount_in: u64,
    ): (vector<address>, u64) {
        let in_pools = pool_manager::get_pools_for_token(token_in);
        let best_route = vector::empty<address>();
        let best_output = 0u64;

        let i = 0;
        let len = vector::length(&in_pools);
        while (i < len) {
            let pool1 = *vector::borrow(&in_pools, i);
            let (token_x1, token_y1) = pool::get_token_metadata(pool1);

            // Determine intermediate token
            let is_x_to_y1 = object::object_address(&token_x1) == object::object_address(&token_in);
            let mid_token = if (is_x_to_y1) { token_y1 } else { token_x1 };

            // Skip if mid_token is the same as token_out (that would be a direct route)
            if (object::object_address(&mid_token) != object::object_address(&token_out)) {
                let mid_output = pool::get_amount_out(pool1, amount_in, is_x_to_y1);

                if (mid_output > 0) {
                    // Find pools containing mid_token and token_out
                    let mid_pools = pool_manager::get_pools_for_token(mid_token);
                    let j = 0;
                    let mid_len = vector::length(&mid_pools);
                    while (j < mid_len) {
                        let pool2 = *vector::borrow(&mid_pools, j);
                        if (pool2 != pool1) {
                            let (token_x2, token_y2) = pool::get_token_metadata(pool2);
                            let has_out = (
                                object::object_address(&token_x2) == object::object_address(&token_out) ||
                                object::object_address(&token_y2) == object::object_address(&token_out)
                            );

                            if (has_out) {
                                let is_x_to_y2 = object::object_address(&token_x2) == object::object_address(&mid_token);
                                let final_output = pool::get_amount_out(pool2, mid_output, is_x_to_y2);

                                if (final_output > best_output) {
                                    best_output = final_output;
                                    best_route = vector::empty();
                                    vector::push_back(&mut best_route, pool1);
                                    vector::push_back(&mut best_route, pool2);
                                };
                            };
                        };
                        j = j + 1;
                    };
                };
            };

            i = i + 1;
        };

        (best_route, best_output)
    }
}
