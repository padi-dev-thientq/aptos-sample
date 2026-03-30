module defi_aggregator::percentage {
    use defi_aggregator::math_utils;

    /// 100% in basis points
    const BPS_BASE: u64 = 10000;

    const E_INVALID_BPS: u64 = 1;

    /// Apply basis points to an amount: amount * bps / 10000
    public fun apply_bps(amount: u128, bps: u64): u128 {
        math_utils::mul_div(amount, (bps as u128), (BPS_BASE as u128))
    }

    /// Apply basis points with rounding up
    public fun apply_bps_round_up(amount: u128, bps: u64): u128 {
        math_utils::mul_div_round_up(amount, (bps as u128), (BPS_BASE as u128))
    }

    /// Calculate what percentage (in bps) `part` is of `total`
    public fun to_bps(part: u128, total: u128): u64 {
        if (total == 0) return 0;
        (math_utils::mul_div(part, (BPS_BASE as u128), total) as u64)
    }

    /// Get the BPS base (10000)
    public fun bps_base(): u64 {
        BPS_BASE
    }

    /// Validate that bps is within valid range [0, 10000]
    public fun assert_valid_bps(bps: u64) {
        assert!(bps <= BPS_BASE, E_INVALID_BPS);
    }

    #[test]
    fun test_apply_bps() {
        // 30 bps of 10000 = 30
        assert!(apply_bps(10000, 30) == 30, 0);
        // 100% of 500 = 500
        assert!(apply_bps(500, 10000) == 500, 1);
        // 50% of 1000 = 500
        assert!(apply_bps(1000, 5000) == 500, 2);
        // 0 bps = 0
        assert!(apply_bps(1000, 0) == 0, 3);
    }

    #[test]
    fun test_to_bps() {
        assert!(to_bps(500, 1000) == 5000, 0); // 50%
        assert!(to_bps(30, 10000) == 30, 1);    // 0.3%
        assert!(to_bps(0, 1000) == 0, 2);
        assert!(to_bps(100, 0) == 0, 3);
    }
}
