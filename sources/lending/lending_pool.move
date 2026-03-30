module defi_aggregator::lending_pool {
    use std::signer;
    use std::vector;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::smart_table::{Self, SmartTable};
    use defi_aggregator::math_utils;
    use defi_aggregator::admin;
    use defi_aggregator::events;
    use defi_aggregator::interest_rate_model;

    friend defi_aggregator::collateral_manager;
    friend defi_aggregator::liquidation;
    friend defi_aggregator::flash_loan;
    friend defi_aggregator::lending_aggregator;
    friend defi_aggregator::master_router;

    const E_ALREADY_INITIALIZED: u64 = 1;
    const E_MARKET_NOT_FOUND: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const E_MARKET_PAUSED: u64 = 5;
    const E_BORROW_CAP_EXCEEDED: u64 = 6;
    const E_SUPPLY_CAP_EXCEEDED: u64 = 7;
    const E_POSITION_NOT_FOUND: u64 = 8;
    const E_INSUFFICIENT_SHARES: u64 = 9;

    /// Scaling factor for indices (1e18)
    const INDEX_SCALE: u128 = 1_000_000_000_000_000_000;

    /// Per-asset lending market
    struct LendingMarket has key {
        asset_metadata: Object<Metadata>,
        asset_store: Object<FungibleStore>,
        total_deposits: u128,
        total_borrows: u128,
        total_supply_shares: u128,
        borrow_index: u128,   // scaled by INDEX_SCALE
        supply_index: u128,   // scaled by INDEX_SCALE
        last_accrual_timestamp: u64,
        // Interest rate model params
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
        reserve_factor_bps: u64,
        reserves: u128,
        // Risk params
        collateral_factor_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        borrow_cap: u128,
        supply_cap: u128,
        // Object refs
        extend_ref: ExtendRef,
        is_paused: bool,
    }

    /// Per-user position in a market
    struct UserPosition has key, store, copy, drop {
        supply_shares: u128,
        borrow_principal: u128,
        borrow_index_snapshot: u128,
        is_collateral: bool,
    }

    /// Registry of all lending markets
    struct LendingRegistry has key {
        markets: SmartTable<address, address>, // asset_metadata_addr -> market_addr
        all_markets: vector<address>,
    }

    /// User positions across all markets
    struct UserPositions has key {
        positions: SmartTable<address, UserPosition>, // market_addr -> position
        active_markets: vector<address>,
    }

    // ======== Initialization ========

    public entry fun initialize(admin_signer: &signer) {
        admin::assert_admin(admin_signer);
        assert!(!exists<LendingRegistry>(@defi_aggregator), E_ALREADY_INITIALIZED);

        move_to(admin_signer, LendingRegistry {
            markets: smart_table::new(),
            all_markets: vector::empty(),
        });
    }

    // ======== Market Management ========

    public entry fun create_market(
        admin_signer: &signer,
        asset_metadata: Object<Metadata>,
        base_rate_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        optimal_utilization_bps: u64,
        reserve_factor_bps: u64,
        collateral_factor_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        borrow_cap: u128,
        supply_cap: u128,
    ) acquires LendingRegistry {
        admin::assert_admin(admin_signer);
        let registry = borrow_global_mut<LendingRegistry>(@defi_aggregator);

        let asset_addr = object::object_address(&asset_metadata);
        let seed = get_market_seed(asset_addr);
        let constructor_ref = object::create_named_object(admin_signer, seed);
        let market_signer = object::generate_signer(&constructor_ref);
        let market_addr = signer::address_of(&market_signer);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        let asset_store = primary_fungible_store::ensure_primary_store_exists(market_addr, asset_metadata);

        move_to(&market_signer, LendingMarket {
            asset_metadata,
            asset_store,
            total_deposits: 0,
            total_borrows: 0,
            total_supply_shares: 0,
            borrow_index: INDEX_SCALE,
            supply_index: INDEX_SCALE,
            last_accrual_timestamp: timestamp::now_seconds(),
            base_rate_bps,
            slope1_bps,
            slope2_bps,
            optimal_utilization_bps,
            reserve_factor_bps,
            reserves: 0,
            collateral_factor_bps,
            liquidation_threshold_bps,
            liquidation_bonus_bps,
            borrow_cap,
            supply_cap,
            extend_ref,
            is_paused: false,
        });

        smart_table::add(&mut registry.markets, asset_addr, market_addr);
        vector::push_back(&mut registry.all_markets, market_addr);

        events::emit_market_created(market_addr, asset_metadata, collateral_factor_bps);
    }

    // ======== Interest Accrual ========

    public fun accrue_interest(market_addr: address) acquires LendingMarket {
        let market = borrow_global_mut<LendingMarket>(market_addr);
        let now = timestamp::now_seconds();
        let time_elapsed = now - market.last_accrual_timestamp;
        if (time_elapsed == 0) return;

        if (market.total_borrows == 0) {
            market.last_accrual_timestamp = now;
            return
        };

        let utilization = interest_rate_model::get_utilization_rate(
            market.total_deposits,
            market.total_borrows,
            market.reserves,
        );

        let borrow_rate = interest_rate_model::get_borrow_rate(
            utilization,
            market.base_rate_bps,
            market.slope1_bps,
            market.slope2_bps,
            market.optimal_utilization_bps,
        );

        let multiplier = interest_rate_model::calculate_interest_multiplier(
            borrow_rate,
            time_elapsed,
        );

        let scale = interest_rate_model::scale();

        // Update borrow index
        let new_borrow_index = math_utils::mul_div(market.borrow_index, multiplier, scale);

        // Calculate interest earned
        let interest_earned = math_utils::mul_div(
            market.total_borrows,
            multiplier - scale,
            scale,
        );

        // Protocol reserves
        let reserve_amount = math_utils::mul_div(
            interest_earned,
            (market.reserve_factor_bps as u128),
            10000,
        );

        market.borrow_index = new_borrow_index;
        market.total_borrows = market.total_borrows + interest_earned;
        market.total_deposits = market.total_deposits + interest_earned - reserve_amount;
        market.reserves = market.reserves + reserve_amount;
        market.last_accrual_timestamp = now;

        // Update supply index
        if (market.total_supply_shares > 0) {
            market.supply_index = math_utils::mul_div(
                market.total_deposits,
                INDEX_SCALE,
                market.total_supply_shares,
            );
        };
    }

    // ======== Supply ========

    public fun supply(
        user: &signer,
        market_addr: address,
        asset: FungibleAsset,
    ) acquires LendingMarket, UserPositions {
        admin::assert_not_paused();
        accrue_interest(market_addr);

        let market = borrow_global_mut<LendingMarket>(market_addr);
        assert!(!market.is_paused, E_MARKET_PAUSED);

        let amount = fungible_asset::amount(&asset);
        assert!(amount > 0, E_ZERO_AMOUNT);

        if (market.supply_cap > 0) {
            assert!(market.total_deposits + (amount as u128) <= market.supply_cap, E_SUPPLY_CAP_EXCEEDED);
        };

        // Calculate shares to mint
        let shares = if (market.total_supply_shares == 0) {
            (amount as u128) * INDEX_SCALE / INDEX_SCALE // 1:1 for first deposit
        } else {
            math_utils::mul_div(
                (amount as u128),
                market.total_supply_shares,
                market.total_deposits,
            )
        };

        // Deposit asset
        fungible_asset::deposit(market.asset_store, asset);
        market.total_deposits = market.total_deposits + (amount as u128);
        market.total_supply_shares = market.total_supply_shares + shares;

        // Update user position
        let user_addr = signer::address_of(user);
        ensure_user_positions(user);
        let positions = borrow_global_mut<UserPositions>(user_addr);

        if (smart_table::contains(&positions.positions, market_addr)) {
            let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);
            pos.supply_shares = pos.supply_shares + shares;
        } else {
            smart_table::add(&mut positions.positions, market_addr, UserPosition {
                supply_shares: shares,
                borrow_principal: 0,
                borrow_index_snapshot: market.borrow_index,
                is_collateral: false,
            });
            vector::push_back(&mut positions.active_markets, market_addr);
        };

        events::emit_supply(market_addr, user_addr, amount, shares);
    }

    // ======== Withdraw ========

    public fun withdraw(
        user: &signer,
        market_addr: address,
        shares_to_burn: u128,
    ): FungibleAsset acquires LendingMarket, UserPositions {
        accrue_interest(market_addr);

        let market = borrow_global_mut<LendingMarket>(market_addr);
        let user_addr = signer::address_of(user);

        assert!(exists<UserPositions>(user_addr), E_POSITION_NOT_FOUND);
        let positions = borrow_global_mut<UserPositions>(user_addr);
        assert!(smart_table::contains(&positions.positions, market_addr), E_POSITION_NOT_FOUND);

        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);
        assert!(pos.supply_shares >= shares_to_burn, E_INSUFFICIENT_SHARES);

        // Calculate underlying amount
        let amount = (math_utils::mul_div(
            shares_to_burn,
            market.total_deposits,
            market.total_supply_shares,
        ) as u64);

        let available = fungible_asset::balance(market.asset_store);
        assert!((amount as u64) <= available, E_INSUFFICIENT_LIQUIDITY);

        pos.supply_shares = pos.supply_shares - shares_to_burn;
        market.total_supply_shares = market.total_supply_shares - shares_to_burn;
        market.total_deposits = market.total_deposits - (amount as u128);

        let market_signer = object::generate_signer_for_extending(&market.extend_ref);
        let withdrawn = fungible_asset::withdraw(&market_signer, market.asset_store, amount);

        events::emit_withdraw(market_addr, user_addr, amount, shares_to_burn);

        withdrawn
    }

    // ======== Borrow ========

    public fun borrow(
        user: &signer,
        market_addr: address,
        amount: u64,
    ): FungibleAsset acquires LendingMarket, UserPositions {
        admin::assert_not_paused();
        accrue_interest(market_addr);

        let market = borrow_global_mut<LendingMarket>(market_addr);
        assert!(!market.is_paused, E_MARKET_PAUSED);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let available = fungible_asset::balance(market.asset_store);
        assert!((amount as u64) <= available, E_INSUFFICIENT_LIQUIDITY);

        if (market.borrow_cap > 0) {
            assert!(market.total_borrows + (amount as u128) <= market.borrow_cap, E_BORROW_CAP_EXCEEDED);
        };

        let user_addr = signer::address_of(user);
        ensure_user_positions(user);
        let positions = borrow_global_mut<UserPositions>(user_addr);

        if (smart_table::contains(&positions.positions, market_addr)) {
            let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);
            // Rebase existing borrow to current index
            if (pos.borrow_principal > 0) {
                pos.borrow_principal = math_utils::mul_div(
                    pos.borrow_principal,
                    market.borrow_index,
                    pos.borrow_index_snapshot,
                );
            };
            pos.borrow_principal = pos.borrow_principal + (amount as u128);
            pos.borrow_index_snapshot = market.borrow_index;
        } else {
            smart_table::add(&mut positions.positions, market_addr, UserPosition {
                supply_shares: 0,
                borrow_principal: (amount as u128),
                borrow_index_snapshot: market.borrow_index,
                is_collateral: false,
            });
            vector::push_back(&mut positions.active_markets, market_addr);
        };

        market.total_borrows = market.total_borrows + (amount as u128);

        let market_signer = object::generate_signer_for_extending(&market.extend_ref);
        let borrowed = fungible_asset::withdraw(&market_signer, market.asset_store, amount);

        events::emit_borrow(market_addr, user_addr, amount);

        // Note: caller must check health factor after borrow
        borrowed
    }

    // ======== Repay ========

    public fun repay(
        user: &signer,
        market_addr: address,
        asset: FungibleAsset,
    ) acquires LendingMarket, UserPositions {
        accrue_interest(market_addr);

        let market = borrow_global_mut<LendingMarket>(market_addr);
        let user_addr = signer::address_of(user);
        let amount = fungible_asset::amount(&asset);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let positions = borrow_global_mut<UserPositions>(user_addr);
        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);

        // Rebase borrow to current index
        let current_borrow = math_utils::mul_div(
            pos.borrow_principal,
            market.borrow_index,
            pos.borrow_index_snapshot,
        );

        let repay_amount = math_utils::min_u128((amount as u128), current_borrow);

        pos.borrow_principal = current_borrow - repay_amount;
        pos.borrow_index_snapshot = market.borrow_index;

        market.total_borrows = math_utils::saturating_sub(market.total_borrows, repay_amount);

        fungible_asset::deposit(market.asset_store, asset);

        events::emit_repay(market_addr, user_addr, (repay_amount as u64));
    }

    // ======== Collateral Management ========

    public entry fun enable_collateral(user: &signer, market_addr: address) acquires UserPositions {
        let user_addr = signer::address_of(user);
        let positions = borrow_global_mut<UserPositions>(user_addr);
        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);
        pos.is_collateral = true;
    }

    public entry fun disable_collateral(user: &signer, market_addr: address) acquires UserPositions {
        let user_addr = signer::address_of(user);
        let positions = borrow_global_mut<UserPositions>(user_addr);
        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);
        pos.is_collateral = false;
        // Note: caller must check health factor after disabling
    }

    // ======== Friend functions for liquidation/flash_loan ========

    public(friend) fun repay_on_behalf(
        market_addr: address,
        borrower: address,
        asset: FungibleAsset,
    ) acquires LendingMarket, UserPositions {
        let market = borrow_global_mut<LendingMarket>(market_addr);
        let amount = fungible_asset::amount(&asset);

        let positions = borrow_global_mut<UserPositions>(borrower);
        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);

        let current_borrow = math_utils::mul_div(
            pos.borrow_principal,
            market.borrow_index,
            pos.borrow_index_snapshot,
        );

        let repay_amount = math_utils::min_u128((amount as u128), current_borrow);
        pos.borrow_principal = current_borrow - repay_amount;
        pos.borrow_index_snapshot = market.borrow_index;

        market.total_borrows = math_utils::saturating_sub(market.total_borrows, repay_amount);

        fungible_asset::deposit(market.asset_store, asset);
    }

    public(friend) fun seize_collateral(
        market_addr: address,
        borrower: address,
        amount: u64,
    ): FungibleAsset acquires LendingMarket, UserPositions {
        let market = borrow_global_mut<LendingMarket>(market_addr);

        // Reduce borrower's supply shares
        let positions = borrow_global_mut<UserPositions>(borrower);
        let pos = smart_table::borrow_mut(&mut positions.positions, market_addr);

        let shares_to_seize = math_utils::mul_div(
            (amount as u128),
            market.total_supply_shares,
            market.total_deposits,
        );

        pos.supply_shares = math_utils::saturating_sub(pos.supply_shares, shares_to_seize);
        market.total_supply_shares = market.total_supply_shares - shares_to_seize;
        market.total_deposits = market.total_deposits - (amount as u128);

        let market_signer = object::generate_signer_for_extending(&market.extend_ref);
        fungible_asset::withdraw(&market_signer, market.asset_store, amount)
    }

    public(friend) fun flash_borrow(
        market_addr: address,
        amount: u64,
    ): FungibleAsset acquires LendingMarket {
        let market = borrow_global<LendingMarket>(market_addr);
        let available = fungible_asset::balance(market.asset_store);
        assert!((amount as u64) <= available, E_INSUFFICIENT_LIQUIDITY);

        let market_signer = object::generate_signer_for_extending(&market.extend_ref);
        fungible_asset::withdraw(&market_signer, market.asset_store, amount)
    }

    public(friend) fun flash_repay(
        market_addr: address,
        asset: FungibleAsset,
    ) acquires LendingMarket {
        let market = borrow_global<LendingMarket>(market_addr);
        fungible_asset::deposit(market.asset_store, asset);
    }

    // ======== View Functions ========

    #[view]
    public fun get_market_info(market_addr: address): (u128, u128, u128, u64, u64) acquires LendingMarket {
        let market = borrow_global<LendingMarket>(market_addr);
        (
            market.total_deposits,
            market.total_borrows,
            market.reserves,
            market.collateral_factor_bps,
            market.liquidation_threshold_bps,
        )
    }

    #[view]
    public fun get_utilization_rate(market_addr: address): u64 acquires LendingMarket {
        let market = borrow_global<LendingMarket>(market_addr);
        interest_rate_model::get_utilization_rate(
            market.total_deposits,
            market.total_borrows,
            market.reserves,
        )
    }

    #[view]
    public fun get_borrow_rate(market_addr: address): u64 acquires LendingMarket {
        let market = borrow_global<LendingMarket>(market_addr);
        let utilization = interest_rate_model::get_utilization_rate(
            market.total_deposits,
            market.total_borrows,
            market.reserves,
        );
        interest_rate_model::get_borrow_rate(
            utilization,
            market.base_rate_bps,
            market.slope1_bps,
            market.slope2_bps,
            market.optimal_utilization_bps,
        )
    }

    #[view]
    public fun get_supply_rate(market_addr: address): u64 acquires LendingMarket {
        let borrow_rate = get_borrow_rate(market_addr);
        let utilization = get_utilization_rate(market_addr);
        let market = borrow_global<LendingMarket>(market_addr);
        interest_rate_model::get_supply_rate(borrow_rate, utilization, market.reserve_factor_bps)
    }

    public fun get_user_position(
        user: address,
        market_addr: address,
    ): (u128, u128, bool) acquires UserPositions, LendingMarket {
        if (!exists<UserPositions>(user)) return (0, 0, false);
        let positions = borrow_global<UserPositions>(user);
        if (!smart_table::contains(&positions.positions, market_addr)) return (0, 0, false);
        let pos = smart_table::borrow(&positions.positions, market_addr);

        let market = borrow_global<LendingMarket>(market_addr);

        // Calculate current borrow amount
        let current_borrow = if (pos.borrow_principal > 0 && pos.borrow_index_snapshot > 0) {
            math_utils::mul_div(pos.borrow_principal, market.borrow_index, pos.borrow_index_snapshot)
        } else {
            0
        };

        // Calculate current supply value
        let supply_value = if (pos.supply_shares > 0 && market.total_supply_shares > 0) {
            math_utils::mul_div(pos.supply_shares, market.total_deposits, market.total_supply_shares)
        } else {
            0
        };

        (supply_value, current_borrow, pos.is_collateral)
    }

    public fun get_user_active_markets(user: address): vector<address> acquires UserPositions {
        if (!exists<UserPositions>(user)) return vector::empty();
        borrow_global<UserPositions>(user).active_markets
    }

    public fun get_market_asset_metadata(market_addr: address): Object<Metadata> acquires LendingMarket {
        borrow_global<LendingMarket>(market_addr).asset_metadata
    }

    public fun get_collateral_factor(market_addr: address): u64 acquires LendingMarket {
        borrow_global<LendingMarket>(market_addr).collateral_factor_bps
    }

    public fun get_liquidation_threshold(market_addr: address): u64 acquires LendingMarket {
        borrow_global<LendingMarket>(market_addr).liquidation_threshold_bps
    }

    public fun get_liquidation_bonus(market_addr: address): u64 acquires LendingMarket {
        borrow_global<LendingMarket>(market_addr).liquidation_bonus_bps
    }

    public fun get_market_addr_by_asset(asset_metadata: Object<Metadata>): address acquires LendingRegistry {
        let registry = borrow_global<LendingRegistry>(@defi_aggregator);
        let asset_addr = object::object_address(&asset_metadata);
        assert!(smart_table::contains(&registry.markets, asset_addr), E_MARKET_NOT_FOUND);
        *smart_table::borrow(&registry.markets, asset_addr)
    }

    public fun get_all_markets(): vector<address> acquires LendingRegistry {
        borrow_global<LendingRegistry>(@defi_aggregator).all_markets
    }

    // ======== Internal ========

    fun ensure_user_positions(user: &signer) {
        let user_addr = signer::address_of(user);
        if (!exists<UserPositions>(user_addr)) {
            move_to(user, UserPositions {
                positions: smart_table::new(),
                active_markets: vector::empty(),
            });
        };
    }

    fun get_market_seed(asset_addr: address): vector<u8> {
        let seed = b"LENDING_MARKET_";
        std::vector::append(&mut seed, std::bcs::to_bytes(&asset_addr));
        seed
    }
}
