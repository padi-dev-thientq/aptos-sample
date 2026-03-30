module defi_aggregator::math_utils {

    const E_DIVISION_BY_ZERO: u64 = 1;
    const E_OVERFLOW: u64 = 2;

    /// Safe multiply then divide: (a * b) / c using u256 intermediate to prevent overflow
    public fun mul_div(a: u128, b: u128, c: u128): u128 {
        assert!(c > 0, E_DIVISION_BY_ZERO);
        let result = ((a as u256) * (b as u256)) / (c as u256);
        assert!(result <= (340282366920938463463374607431768211455u256), E_OVERFLOW); // max u128
        (result as u128)
    }

    /// Safe multiply then divide with rounding up
    public fun mul_div_round_up(a: u128, b: u128, c: u128): u128 {
        assert!(c > 0, E_DIVISION_BY_ZERO);
        let numerator = (a as u256) * (b as u256);
        let denominator = (c as u256);
        let result = (numerator + denominator - 1) / denominator;
        (result as u128)
    }

    /// Integer square root using Newton's method
    public fun sqrt(x: u128): u128 {
        if (x == 0) return 0;
        if (x < 4) return 1;

        let z = x;
        let y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        };
        z
    }

    /// Minimum of two u64 values
    public fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    /// Maximum of two u64 values
    public fun max_u64(a: u64, b: u64): u64 {
        if (a > b) a else b
    }

    /// Minimum of two u128 values
    public fun min_u128(a: u128, b: u128): u128 {
        if (a < b) a else b
    }

    /// Maximum of two u128 values
    public fun max_u128(a: u128, b: u128): u128 {
        if (a > b) a else b
    }

    /// Safe subtraction that returns 0 if b > a
    public fun saturating_sub(a: u128, b: u128): u128 {
        if (b > a) 0 else a - b
    }

    #[test]
    fun test_sqrt() {
        assert!(sqrt(0) == 0, 0);
        assert!(sqrt(1) == 1, 1);
        assert!(sqrt(4) == 2, 2);
        assert!(sqrt(9) == 3, 3);
        assert!(sqrt(2) == 1, 4);
        assert!(sqrt(100) == 10, 5);
        assert!(sqrt(10000) == 100, 6);
        assert!(sqrt(1000000000000000000) == 1000000000, 7);
    }

    #[test]
    fun test_mul_div() {
        assert!(mul_div(100, 200, 100) == 200, 0);
        assert!(mul_div(1000000000000, 1000000000000, 1000000000000) == 1000000000000, 1);
        // Test large numbers that would overflow u128 without u256
        assert!(mul_div(340282366920938463463374607431768211455, 1, 1) == 340282366920938463463374607431768211455, 2);
    }

    #[test]
    fun test_mul_div_round_up() {
        assert!(mul_div_round_up(10, 3, 2) == 15, 0);
        assert!(mul_div_round_up(7, 1, 3) == 3, 1); // 7/3 = 2.33 -> 3
    }

    #[test]
    fun test_min_max() {
        assert!(min_u64(1, 2) == 1, 0);
        assert!(max_u64(1, 2) == 2, 1);
        assert!(min_u128(100, 200) == 100, 2);
        assert!(max_u128(100, 200) == 200, 3);
    }

    #[test]
    fun test_saturating_sub() {
        assert!(saturating_sub(10, 5) == 5, 0);
        assert!(saturating_sub(5, 10) == 0, 1);
        assert!(saturating_sub(0, 0) == 0, 2);
    }
}
