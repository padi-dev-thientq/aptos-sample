module defi_aggregator::collateral_manager {
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use defi_aggregator::math_utils;
    use defi_aggregator::oracle;
    use defi_aggregator::lending_pool;

    friend defi_aggregator::liquidation;
    friend defi_aggregator::master_router;

    const E_UNHEALTHY_POSITION: u64 = 1;

    /// Max staleness for oracle prices (5 minutes)
    const MAX_STALENESS_SECS: u64 = 300;

    /// Health factor base (10000 = 1.0)
    const HEALTH_FACTOR_BASE: u64 = 10000;

    /// Price decimals normalization target
    const PRICE_DECIMALS: u128 = 100_000_000; // 1e8

    /// Get total collateral value in USD (scaled by 1e8) adjusted by collateral factors
    public fun get_total_collateral_value(user: address): u128 {
        let markets = lending_pool::get_user_active_markets(user);
        let total = 0u128;
        let i = 0;
        let len = vector::length(&markets);

        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let (supply_value, _borrow, is_collateral) = lending_pool::get_user_position(user, market_addr);

            if (is_collateral && supply_value > 0) {
                let asset_metadata = lending_pool::get_market_asset_metadata(market_addr);
                let price = get_asset_price_usd(asset_metadata);
                let collateral_factor = lending_pool::get_collateral_factor(market_addr);

                // value = supply_value * price * collateral_factor / (PRICE_DECIMALS * 10000)
                let value = math_utils::mul_div(supply_value, price, PRICE_DECIMALS);
                let adjusted = math_utils::mul_div(value, (collateral_factor as u128), 10000);
                total = total + adjusted;
            };

            i = i + 1;
        };

        total
    }

    /// Get total borrow value in USD (scaled by 1e8)
    public fun get_total_borrow_value(user: address): u128 {
        let markets = lending_pool::get_user_active_markets(user);
        let total = 0u128;
        let i = 0;
        let len = vector::length(&markets);

        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let (_supply, borrow, _is_collateral) = lending_pool::get_user_position(user, market_addr);

            if (borrow > 0) {
                let asset_metadata = lending_pool::get_market_asset_metadata(market_addr);
                let price = get_asset_price_usd(asset_metadata);
                let value = math_utils::mul_div(borrow, price, PRICE_DECIMALS);
                total = total + value;
            };

            i = i + 1;
        };

        total
    }

    /// Get total collateral value adjusted by liquidation threshold
    public fun get_liquidation_threshold_value(user: address): u128 {
        let markets = lending_pool::get_user_active_markets(user);
        let total = 0u128;
        let i = 0;
        let len = vector::length(&markets);

        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let (supply_value, _borrow, is_collateral) = lending_pool::get_user_position(user, market_addr);

            if (is_collateral && supply_value > 0) {
                let asset_metadata = lending_pool::get_market_asset_metadata(market_addr);
                let price = get_asset_price_usd(asset_metadata);
                let liq_threshold = lending_pool::get_liquidation_threshold(market_addr);

                let value = math_utils::mul_div(supply_value, price, PRICE_DECIMALS);
                let adjusted = math_utils::mul_div(value, (liq_threshold as u128), 10000);
                total = total + adjusted;
            };

            i = i + 1;
        };

        total
    }

    // Health factor = liquidation_threshold_value / total_borrow_value * 10000
    // Returns 10000 for exactly 1.0, >10000 for healthy, <10000 for liquidatable
    #[view]
    public fun get_health_factor(user: address): u64 {
        let borrow_value = get_total_borrow_value(user);
        if (borrow_value == 0) return 1_000_000; // effectively infinite

        let threshold_value = get_liquidation_threshold_value(user);
        (math_utils::mul_div(threshold_value, 10000, borrow_value) as u64)
    }

    /// Assert that a user's position is healthy (health factor >= 1.0)
    public fun assert_healthy(user: address) {
        let health_factor = get_health_factor(user);
        assert!(health_factor >= HEALTH_FACTOR_BASE, E_UNHEALTHY_POSITION);
    }

    /// Check if a position is liquidatable
    public fun is_liquidatable(user: address): bool {
        let health_factor = get_health_factor(user);
        health_factor < HEALTH_FACTOR_BASE
    }

    /// Get max additional borrow amount (in asset units) that keeps position healthy
    public fun get_max_borrowable(
        user: address,
        market_addr: address,
    ): u64 {
        let collateral_value = get_total_collateral_value(user);
        let borrow_value = get_total_borrow_value(user);

        if (collateral_value <= borrow_value) return 0;

        let remaining_value = collateral_value - borrow_value;

        // Convert USD value back to asset amount
        let asset_metadata = lending_pool::get_market_asset_metadata(market_addr);
        let price = get_asset_price_usd(asset_metadata);
        if (price == 0) return 0;

        (math_utils::mul_div(remaining_value, PRICE_DECIMALS, price) as u64)
    }

    // ======== Internal ========

    fun get_asset_price_usd(asset_metadata: Object<Metadata>): u128 {
        let (price, decimals) = oracle::get_price_safe(asset_metadata, MAX_STALENESS_SECS);
        // Normalize to 8 decimals
        if ((decimals as u128) == 8) {
            price
        } else if ((decimals as u128) < 8) {
            price * pow10(8 - (decimals as u8))
        } else {
            price / pow10((decimals as u8) - 8)
        }
    }

    fun pow10(exp: u8): u128 {
        let result = 1u128;
        let i = 0u8;
        while (i < exp) {
            result = result * 10;
            i = i + 1;
        };
        result
    }
}
