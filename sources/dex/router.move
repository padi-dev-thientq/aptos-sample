module defi_aggregator::router {
    use std::vector;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::Object;
    use defi_aggregator::pool;
    use defi_aggregator::admin;

    friend defi_aggregator::swap_aggregator;
    friend defi_aggregator::executor;
    friend defi_aggregator::master_router;

    const E_EMPTY_PATH: u64 = 1;
    const E_SLIPPAGE_EXCEEDED: u64 = 2;
    const E_INVALID_WEIGHTS: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;

    /// A single hop in a swap path
    struct SwapHop has copy, drop, store {
        pool_addr: address,
    }

    /// Execute multi-hop swap: token flows through pools sequentially
    public fun swap_exact_input_multihop(
        sender: address,
        path: vector<SwapHop>,
        token_in: FungibleAsset,
        min_amount_out: u64,
    ): FungibleAsset {
        admin::assert_not_paused();
        let path_len = vector::length(&path);
        assert!(path_len > 0, E_EMPTY_PATH);

        let current_tokens = token_in;
        let i = 0;
        while (i < path_len) {
            let hop = vector::borrow(&path, i);
            // For intermediate hops, min_amount_out = 0 (only check final output)
            let min_out = if (i == path_len - 1) { min_amount_out } else { 0 };
            current_tokens = pool::swap(sender, hop.pool_addr, current_tokens, min_out);
            i = i + 1;
        };

        let final_amount = fungible_asset::amount(&current_tokens);
        assert!(final_amount >= min_amount_out, E_SLIPPAGE_EXCEEDED);

        current_tokens
    }

    /// Split swap across multiple pools for the same pair.
    /// Reduces price impact for large orders.
    /// weights_bps must sum to 10000.
    public fun swap_exact_input_split(
        sender: address,
        pool_addrs: vector<address>,
        weights_bps: vector<u64>,
        token_in: FungibleAsset,
        min_amount_out: u64,
        output_metadata: Object<Metadata>,
    ): FungibleAsset {
        admin::assert_not_paused();
        let num_pools = vector::length(&pool_addrs);
        assert!(num_pools > 0, E_EMPTY_PATH);
        assert!(num_pools == vector::length(&weights_bps), E_INVALID_WEIGHTS);

        // Verify weights sum to 10000
        let total_weight = 0u64;
        let i = 0;
        while (i < num_pools) {
            total_weight = total_weight + *vector::borrow(&weights_bps, i);
            i = i + 1;
        };
        assert!(total_weight == 10000, E_INVALID_WEIGHTS);

        let total_in = fungible_asset::amount(&token_in);
        assert!(total_in > 0, E_ZERO_AMOUNT);

        // Accumulate all outputs
        let total_output = fungible_asset::zero(output_metadata);

        let i = 0;
        while (i < num_pools) {
            let weight = *vector::borrow(&weights_bps, i);
            let pool_addr = *vector::borrow(&pool_addrs, i);

            let amount_for_pool = if (i == num_pools - 1) {
                // Last pool gets remaining to avoid rounding dust
                fungible_asset::amount(&token_in)
            } else {
                ((total_in as u128) * (weight as u128) / 10000u128 as u64)
            };

            if (amount_for_pool > 0) {
                let split_tokens = fungible_asset::extract(&mut token_in, amount_for_pool);
                let output = pool::swap(sender, pool_addr, split_tokens, 0);
                fungible_asset::merge(&mut total_output, output);
            };

            i = i + 1;
        };

        // Destroy any dust remaining
        fungible_asset::destroy_zero(token_in);

        let final_amount = fungible_asset::amount(&total_output);
        assert!(final_amount >= min_amount_out, E_SLIPPAGE_EXCEEDED);

        total_output
    }

    /// Calculate expected output for a multi-hop path (view-like helper)
    public fun get_multihop_amount_out(
        path: vector<SwapHop>,
        amount_in: u64,
    ): u64 {
        let current_amount = amount_in;
        let i = 0;
        let path_len = vector::length(&path);
        while (i < path_len) {
            let hop = vector::borrow(&path, i);
            let (token_x, _token_y) = pool::get_token_metadata(hop.pool_addr);
            // We need to determine direction - for simplicity, this requires knowing the token flow
            // In practice, the caller constructs the path with correct directions
            let is_x_to_y = true; // placeholder - real logic depends on token metadata matching
            _ = token_x;
            current_amount = pool::get_amount_out(hop.pool_addr, current_amount, is_x_to_y);
            i = i + 1;
        };
        current_amount
    }

    /// Create a SwapHop
    public fun create_hop(pool_addr: address): SwapHop {
        SwapHop { pool_addr }
    }
}
