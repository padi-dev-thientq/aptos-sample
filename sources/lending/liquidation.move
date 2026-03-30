module defi_aggregator::liquidation {
    use std::signer;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use defi_aggregator::math_utils;
    use defi_aggregator::oracle;
    use defi_aggregator::lending_pool;
    use defi_aggregator::collateral_manager;
    use defi_aggregator::events;
    use defi_aggregator::admin;

    const E_NOT_LIQUIDATABLE: u64 = 1;
    const E_EXCEEDS_CLOSE_FACTOR: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_ZERO_COLLATERAL: u64 = 4;

    /// Close factor: max 50% of debt can be repaid in one liquidation
    const CLOSE_FACTOR_BPS: u64 = 5000;

    /// Max staleness for oracle prices
    const MAX_STALENESS_SECS: u64 = 300;

    /// Price normalization
    const PRICE_DECIMALS: u128 = 100_000_000; // 1e8

    /// Liquidate an unhealthy position
    public fun liquidate(
        liquidator: &signer,
        borrower: address,
        repay_market_addr: address,
        collateral_market_addr: address,
        repay_asset: FungibleAsset,
    ): FungibleAsset {
        admin::assert_not_paused();

        // Accrue interest on both markets
        lending_pool::accrue_interest(repay_market_addr);
        lending_pool::accrue_interest(collateral_market_addr);

        // Verify position is liquidatable
        assert!(collateral_manager::is_liquidatable(borrower), E_NOT_LIQUIDATABLE);

        let repay_amount = fungible_asset::amount(&repay_asset);
        assert!(repay_amount > 0, E_ZERO_AMOUNT);

        // Check close factor
        let max_repay = get_max_liquidation_amount(borrower, repay_market_addr);
        assert!((repay_amount as u128) <= max_repay, E_EXCEEDS_CLOSE_FACTOR);

        // Get prices for both assets
        let repay_metadata = lending_pool::get_market_asset_metadata(repay_market_addr);
        let collateral_metadata = lending_pool::get_market_asset_metadata(collateral_market_addr);
        let (repay_price, _) = oracle::get_price_safe(repay_metadata, MAX_STALENESS_SECS);
        let (collateral_price, _) = oracle::get_price_safe(collateral_metadata, MAX_STALENESS_SECS);

        // Calculate collateral to seize:
        // collateral_amount = repay_amount * repay_price * (1 + liquidation_bonus) / collateral_price
        let liquidation_bonus = lending_pool::get_liquidation_bonus(collateral_market_addr);
        let repay_value = math_utils::mul_div((repay_amount as u128), repay_price, PRICE_DECIMALS);
        let bonus_value = math_utils::mul_div(
            repay_value,
            (10000 + liquidation_bonus as u128),
            10000,
        );
        let collateral_to_seize = (math_utils::mul_div(
            bonus_value,
            PRICE_DECIMALS,
            collateral_price,
        ) as u64);

        assert!(collateral_to_seize > 0, E_ZERO_COLLATERAL);

        // Repay borrower's debt
        lending_pool::repay_on_behalf(repay_market_addr, borrower, repay_asset);

        // Seize collateral from borrower
        let seized_collateral = lending_pool::seize_collateral(
            collateral_market_addr,
            borrower,
            collateral_to_seize,
        );

        events::emit_liquidation(
            signer::address_of(liquidator),
            borrower,
            repay_market_addr,
            collateral_market_addr,
            repay_amount,
            collateral_to_seize,
        );

        seized_collateral
    }

    // Maximum amount a liquidator can repay (close factor * total debt in the market)
    #[view]
    public fun get_max_liquidation_amount(
        borrower: address,
        repay_market_addr: address,
    ): u128 {
        let (_supply, borrow, _is_collateral) = lending_pool::get_user_position(
            borrower,
            repay_market_addr,
        );
        math_utils::mul_div(borrow, (CLOSE_FACTOR_BPS as u128), 10000)
    }
}
