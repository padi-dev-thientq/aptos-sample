module defi_aggregator::detector {
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use defi_aggregator::pool;
    use defi_aggregator::math_utils;

    friend defi_aggregator::executor;
    friend defi_aggregator::path_finder;

    const E_SAME_POOL: u64 = 1;
    const E_NO_OPPORTUNITY: u64 = 2;

    /// Describes a detected arbitrage opportunity
    struct ArbOpportunity has copy, drop, store {
        path: vector<address>,
        expected_profit: u64,
        start_amount: u64,
    }

    /// Detect two-pool arbitrage: same pair traded at different prices in two pools.
    /// Returns (has_opportunity, opportunity)
    public fun detect_two_pool_arb(
        pool_a: address,
        pool_b: address,
    ): (bool, ArbOpportunity) {
        assert!(pool_a != pool_b, E_SAME_POOL);

        let (reserve_a_x, reserve_a_y) = pool::get_reserves(pool_a);
        let (reserve_b_x, reserve_b_y) = pool::get_reserves(pool_b);

        // Price in pool A: reserve_a_y / reserve_a_x
        // Price in pool B: reserve_b_y / reserve_b_x
        // Arb exists if prices differ enough to cover fees

        let fee_a = pool::get_fee_bps(pool_a);
        let fee_b = pool::get_fee_bps(pool_b);

        // Check direction 1: buy X in pool A (cheaper), sell X in pool B (more expensive)
        // Pool A X is cheap if: reserve_a_y / reserve_a_x < reserve_b_y / reserve_b_x
        // Cross multiply: reserve_a_y * reserve_b_x < reserve_b_y * reserve_a_x

        let price_a_cross = (reserve_a_y as u256) * (reserve_b_x as u256);
        let price_b_cross = (reserve_b_y as u256) * (reserve_a_x as u256);

        let (has_opp, profit, optimal_amount) = if (price_a_cross < price_b_cross) {
            // Buy Y->X in pool A, sell X->Y in pool B
            let optimal = calculate_optimal_amount(
                (reserve_a_y as u128), (reserve_a_x as u128),
                (reserve_b_x as u128), (reserve_b_y as u128),
                fee_a, fee_b,
            );
            if (optimal > 0) {
                let out_a = pool::get_amount_out(pool_a, (optimal as u64), false); // Y -> X
                let out_b = pool::get_amount_out(pool_b, out_a, true); // X -> Y
                if ((out_b as u128) > optimal) {
                    (true, ((out_b as u128) - optimal as u64), (optimal as u64))
                } else {
                    (false, 0u64, 0u64)
                }
            } else {
                (false, 0u64, 0u64)
            }
        } else if (price_b_cross < price_a_cross) {
            // Buy Y->X in pool B, sell X->Y in pool A
            let optimal = calculate_optimal_amount(
                (reserve_b_y as u128), (reserve_b_x as u128),
                (reserve_a_x as u128), (reserve_a_y as u128),
                fee_b, fee_a,
            );
            if (optimal > 0) {
                let out_b = pool::get_amount_out(pool_b, (optimal as u64), false);
                let out_a = pool::get_amount_out(pool_a, out_b, true);
                if ((out_a as u128) > optimal) {
                    (true, ((out_a as u128) - optimal as u64), (optimal as u64))
                } else {
                    (false, 0u64, 0u64)
                }
            } else {
                (false, 0u64, 0u64)
            }
        } else {
            (false, 0u64, 0u64)
        };

        let path = std::vector::empty<address>();
        if (has_opp) {
            std::vector::push_back(&mut path, pool_a);
            std::vector::push_back(&mut path, pool_b);
        };

        (has_opp, ArbOpportunity {
            path,
            expected_profit: profit,
            start_amount: optimal_amount,
        })
    }

    /// Detect triangular arbitrage: A->B->C->A across three pools
    public fun detect_triangular_arb(
        pool_ab: address,
        pool_bc: address,
        pool_ca: address,
        start_token: Object<Metadata>,
        test_amount: u64,
    ): (bool, ArbOpportunity) {
        // Check if going through all 3 pools produces more than we started with
        let (token_x_ab, _) = pool::get_token_metadata(pool_ab);
        let is_x_to_y_ab = object::object_address(&start_token) == object::object_address(&token_x_ab);

        let out_1 = pool::get_amount_out(pool_ab, test_amount, is_x_to_y_ab);

        let (token_x_bc, _) = pool::get_token_metadata(pool_bc);
        let out_1_metadata = if (is_x_to_y_ab) {
            let (_, y) = pool::get_token_metadata(pool_ab);
            y
        } else {
            token_x_ab
        };
        let is_x_to_y_bc = object::object_address(&out_1_metadata) == object::object_address(&token_x_bc);

        let out_2 = pool::get_amount_out(pool_bc, out_1, is_x_to_y_bc);

        let (token_x_ca, _) = pool::get_token_metadata(pool_ca);
        let out_2_metadata = if (is_x_to_y_bc) {
            let (_, y) = pool::get_token_metadata(pool_bc);
            y
        } else {
            token_x_bc
        };
        let is_x_to_y_ca = object::object_address(&out_2_metadata) == object::object_address(&token_x_ca);

        let out_3 = pool::get_amount_out(pool_ca, out_2, is_x_to_y_ca);

        let has_opp = out_3 > test_amount;
        let profit = if (has_opp) { out_3 - test_amount } else { 0 };

        let path = std::vector::empty<address>();
        std::vector::push_back(&mut path, pool_ab);
        std::vector::push_back(&mut path, pool_bc);
        std::vector::push_back(&mut path, pool_ca);

        (has_opp, ArbOpportunity {
            path,
            expected_profit: profit,
            start_amount: test_amount,
        })
    }

    /// Get opportunity fields
    public fun get_opportunity_profit(opp: &ArbOpportunity): u64 {
        opp.expected_profit
    }

    public fun get_opportunity_amount(opp: &ArbOpportunity): u64 {
        opp.start_amount
    }

    public fun get_opportunity_path(opp: &ArbOpportunity): vector<address> {
        opp.path
    }

    /// Create an empty ArbOpportunity (for initialization)
    public fun empty_opportunity(): ArbOpportunity {
        ArbOpportunity {
            path: std::vector::empty(),
            expected_profit: 0,
            start_amount: 0,
        }
    }

    // ======== Internal ========

    /// Calculate optimal input amount for two-pool arbitrage
    /// Based on AMM math: optimize profit = output_pool_b(output_pool_a(x)) - x
    fun calculate_optimal_amount(
        reserve_a_in: u128,
        _reserve_a_out: u128,
        _reserve_b_in: u128,
        reserve_b_out: u128,
        fee_a_bps: u64,
        fee_b_bps: u64,
    ): u128 {
        // Simplified optimal amount estimation using geometric mean approach
        // optimal ~= sqrt(reserve_a_in * reserve_b_out * (10000-fee_a) * (10000-fee_b) / 10000^2) - reserve_a_in
        let fee_mult_a = (10000 - fee_a_bps as u128);
        let fee_mult_b = (10000 - fee_b_bps as u128);

        let product = math_utils::mul_div(
            math_utils::mul_div(reserve_a_in, reserve_b_out, 1),
            fee_mult_a * fee_mult_b,
            100_000_000, // 10000^2
        );

        let sqrt_product = math_utils::sqrt(product);

        if (sqrt_product > reserve_a_in) {
            // Cap at 10% of reserve to avoid excessive price impact
            let max_amount = reserve_a_in / 10;
            math_utils::min_u128(sqrt_product - reserve_a_in, max_amount)
        } else {
            0
        }
    }
}
