module defi_aggregator::path_finder {
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use defi_aggregator::pool;
    use defi_aggregator::pool_manager;
    use defi_aggregator::detector::{Self, ArbOpportunity};

    const E_NO_PATH_FOUND: u64 = 1;

    /// Find the most profitable two-pool arbitrage for a given pair
    public fun find_best_two_pool_arb(
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
    ): (bool, ArbOpportunity) {
        let pools_a = pool_manager::get_pools_for_token(token_a);
        let pools_b = pool_manager::get_pools_for_token(token_b);

        let best_profit = 0u64;
        let best_opp = detector::empty_opportunity();
        let found = false;

        let i = 0;
        let len_a = vector::length(&pools_a);
        while (i < len_a) {
            let pool_a = *vector::borrow(&pools_a, i);
            let (token_x_a, token_y_a) = pool::get_token_metadata(pool_a);

            // Check if pool_a contains both tokens
            let a_has_pair = (
                object::object_address(&token_x_a) == object::object_address(&token_a) ||
                object::object_address(&token_y_a) == object::object_address(&token_a)
            ) && (
                object::object_address(&token_x_a) == object::object_address(&token_b) ||
                object::object_address(&token_y_a) == object::object_address(&token_b)
            );

            if (a_has_pair) {
                let j = 0;
                let len_b = vector::length(&pools_b);
                while (j < len_b) {
                    let pool_b = *vector::borrow(&pools_b, j);
                    if (pool_a != pool_b) {
                        let (token_x_b, token_y_b) = pool::get_token_metadata(pool_b);
                        let b_has_pair = (
                            object::object_address(&token_x_b) == object::object_address(&token_a) ||
                            object::object_address(&token_y_b) == object::object_address(&token_a)
                        ) && (
                            object::object_address(&token_x_b) == object::object_address(&token_b) ||
                            object::object_address(&token_y_b) == object::object_address(&token_b)
                        );

                        if (b_has_pair) {
                            let (has_opp, opp) = detector::detect_two_pool_arb(pool_a, pool_b);
                            if (has_opp) {
                                let profit = detector::get_opportunity_profit(&opp);
                                if (profit > best_profit) {
                                    best_profit = profit;
                                    best_opp = opp;
                                    found = true;
                                };
                            };
                        };
                    };
                    j = j + 1;
                };
            };
            i = i + 1;
        };

        (found, best_opp)
    }

    /// Calculate optimal input amount for a two-pool arbitrage
    /// Uses binary search over the profit curve
    public fun optimize_arb_amount(
        pool_a: address,
        pool_b: address,
        initial_estimate: u64,
        is_x_to_y_a: bool,
        is_x_to_y_b: bool,
    ): u64 {
        let low = initial_estimate / 2;
        let high = initial_estimate * 2;
        let best_amount = initial_estimate;
        let best_profit = 0u64;

        // Binary search for optimal amount (10 iterations)
        let iterations = 0;
        while (iterations < 10 && low < high) {
            let mid = (low + high) / 2;
            if (mid == 0) break;

            let out_a = pool::get_amount_out(pool_a, mid, is_x_to_y_a);
            let out_b = pool::get_amount_out(pool_b, out_a, is_x_to_y_b);

            if (out_b > mid) {
                let profit = out_b - mid;
                if (profit > best_profit) {
                    best_profit = profit;
                    best_amount = mid;
                };
                low = mid + 1;
            } else {
                high = mid;
            };

            iterations = iterations + 1;
        };

        best_amount
    }
}
