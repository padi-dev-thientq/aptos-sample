module defi_aggregator::interest_rate_model {
    use defi_aggregator::math_utils;

    /// Scaling factor for rate calculations (1e18)
    const SCALE: u128 = 1_000_000_000_000_000_000;

    /// Seconds per year (365.25 days)
    const SECONDS_PER_YEAR: u128 = 31_557_600;

    /// BPS base
    const BPS_BASE: u128 = 10000;

    /// Calculate utilization rate in BPS: total_borrows / (total_deposits + total_borrows - reserves)
    public fun get_utilization_rate(
        total_deposits: u128,
        total_borrows: u128,
        reserves: u128,
    ): u64 {
        if (total_borrows == 0) return 0;
        let available = total_deposits + total_borrows - reserves;
        if (available == 0) return 0;
        (math_utils::mul_div(total_borrows, BPS_BASE, available) as u64)
    }

    /// Calculate annualized borrow rate (in BPS) based on dual-slope model
    /// Below optimal: base_rate + slope1 * utilization / optimal_utilization
    /// Above optimal: base_rate + slope1 + slope2 * (utilization - optimal) / (1 - optimal)
    public fun get_borrow_rate(
        utilization_bps: u64,
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
    ): u64 {
        if (utilization_bps == 0) return base_rate_bps;

        if ((utilization_bps as u128) <= (optimal_utilization_bps as u128)) {
            // base + slope1 * utilization / optimal
            let variable = math_utils::mul_div(
                (slope1_bps as u128),
                (utilization_bps as u128),
                (optimal_utilization_bps as u128),
            );
            base_rate_bps + (variable as u64)
        } else {
            // base + slope1 + slope2 * (utilization - optimal) / (10000 - optimal)
            let excess = (utilization_bps as u128) - (optimal_utilization_bps as u128);
            let max_excess = BPS_BASE - (optimal_utilization_bps as u128);
            let variable = if (max_excess > 0) {
                math_utils::mul_div((slope2_bps as u128), excess, max_excess)
            } else {
                (slope2_bps as u128)
            };
            base_rate_bps + slope1_bps + (variable as u64)
        }
    }

    /// Calculate supply rate: borrow_rate * utilization * (1 - reserve_factor)
    public fun get_supply_rate(
        borrow_rate_bps: u64,
        utilization_bps: u64,
        reserve_factor_bps: u64,
    ): u64 {
        let rate = math_utils::mul_div(
            (borrow_rate_bps as u128),
            (utilization_bps as u128),
            BPS_BASE,
        );
        let after_reserve = rate - math_utils::mul_div(rate, (reserve_factor_bps as u128), BPS_BASE);
        (after_reserve as u64)
    }

    /// Calculate the interest multiplier for a given time period
    /// Returns scaled by SCALE (1e18)
    /// multiplier = 1 + (borrow_rate_bps / 10000) * (time_elapsed / SECONDS_PER_YEAR)
    public fun calculate_interest_multiplier(
        borrow_rate_bps: u64,
        time_elapsed_secs: u64,
    ): u128 {
        if (time_elapsed_secs == 0) return SCALE;

        let rate_per_second = math_utils::mul_div(
            (borrow_rate_bps as u128),
            SCALE,
            BPS_BASE * SECONDS_PER_YEAR,
        );

        SCALE + rate_per_second * (time_elapsed_secs as u128)
    }

    /// Get the SCALE constant
    public fun scale(): u128 {
        SCALE
    }

    #[test]
    fun test_utilization_rate() {
        // 50% utilization
        assert!(get_utilization_rate(5000, 5000, 0) == 5000, 0);
        // 0% utilization
        assert!(get_utilization_rate(10000, 0, 0) == 0, 1);
        // 80% utilization
        assert!(get_utilization_rate(2000, 8000, 0) == 8000, 2);
    }

    #[test]
    fun test_borrow_rate() {
        // At 50% utilization with optimal=80%, base=2%, slope1=10%, slope2=100%
        let rate = get_borrow_rate(5000, 200, 1000, 10000, 8000);
        // Expected: 200 + 1000 * 5000/8000 = 200 + 625 = 825
        assert!(rate == 825, 0);

        // At 90% utilization (above optimal)
        let rate = get_borrow_rate(9000, 200, 1000, 10000, 8000);
        // Expected: 200 + 1000 + 10000 * (9000-8000)/(10000-8000) = 200 + 1000 + 5000 = 6200
        assert!(rate == 6200, 1);
    }
}
