module defi_aggregator::pool {
    use std::signer;
    use std::string;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use defi_aggregator::math_utils;
    use defi_aggregator::percentage;
    use defi_aggregator::admin;
    use defi_aggregator::events;
    use defi_aggregator::lp_token;

    friend defi_aggregator::pool_manager;
    friend defi_aggregator::flash_swap;
    friend defi_aggregator::router;
    friend defi_aggregator::detector;
    friend defi_aggregator::path_finder;
    friend defi_aggregator::executor;
    friend defi_aggregator::swap_aggregator;

    const E_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const E_SLIPPAGE_EXCEEDED: u64 = 2;
    const E_POOL_PAUSED: u64 = 3;
    const E_REENTRANCY: u64 = 4;
    const E_ZERO_AMOUNT: u64 = 5;
    const E_K_INVARIANT_VIOLATED: u64 = 6;
    const E_INVALID_TOKEN: u64 = 7;
    const E_INVALID_FEE: u64 = 8;
    const E_POOL_NOT_FOUND: u64 = 9;
    const E_INSUFFICIENT_INITIAL_LIQUIDITY: u64 = 10;

    const MINIMUM_LIQUIDITY: u64 = 1000;
    const MAX_FEE_BPS: u64 = 1000; // 10% max fee

    struct LiquidityPool has key {
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        token_x_store: Object<FungibleStore>,
        token_y_store: Object<FungibleStore>,
        lp_token_metadata: Object<Metadata>,
        fee_bps: u64,
        protocol_fee_bps: u64, // share of fee going to protocol (bps of fee)
        protocol_fee_x: u64,
        protocol_fee_y: u64,
        lp_total_supply: u128,
        extend_ref: ExtendRef,
        is_paused: bool,
        locked: bool,
    }

    // ======== Pool Creation ========

    public(friend) fun create_pool(
        creator: &signer,
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        fee_bps: u64,
    ): address {
        assert!(fee_bps <= MAX_FEE_BPS, E_INVALID_FEE);

        // Create pool object with deterministic address
        let creator_addr = signer::address_of(creator);
        let seed = get_pool_seed(token_x_metadata, token_y_metadata, fee_bps);
        let constructor_ref = object::create_named_object(creator, seed);
        let pool_signer = object::generate_signer(&constructor_ref);
        let pool_addr = signer::address_of(&pool_signer);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        // Create LP token on the same object
        let lp_name = string::utf8(b"DEX-LP");
        let lp_symbol = string::utf8(b"DLP");
        let lp_token_metadata = lp_token::create_lp_token(
            &constructor_ref,
            lp_name,
            lp_symbol,
            8,
        );

        // Create fungible stores for the pool to hold reserves
        let token_x_store = primary_fungible_store::ensure_primary_store_exists(pool_addr, token_x_metadata);
        let token_y_store = primary_fungible_store::ensure_primary_store_exists(pool_addr, token_y_metadata);

        move_to(&pool_signer, LiquidityPool {
            token_x_metadata,
            token_y_metadata,
            token_x_store,
            token_y_store,
            lp_token_metadata,
            fee_bps,
            protocol_fee_bps: 1667, // 1/6 of fee goes to protocol (like Uniswap)
            protocol_fee_x: 0,
            protocol_fee_y: 0,
            lp_total_supply: 0,
            extend_ref,
            is_paused: false,
            locked: false,
        });

        events::emit_pool_created(pool_addr, token_x_metadata, token_y_metadata, fee_bps);

        _ = creator_addr;
        pool_addr
    }

    // ======== Add Liquidity ========

    public fun add_liquidity(
        provider: &signer,
        pool_addr: address,
        token_x: FungibleAsset,
        token_y: FungibleAsset,
        min_lp_tokens: u64,
    ): (FungibleAsset, FungibleAsset, FungibleAsset) acquires LiquidityPool {
        admin::assert_not_paused();
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(!pool.is_paused, E_POOL_PAUSED);
        assert!(!pool.locked, E_REENTRANCY);
        pool.locked = true;

        let amount_x = fungible_asset::amount(&token_x);
        let amount_y = fungible_asset::amount(&token_y);
        assert!(amount_x > 0 && amount_y > 0, E_ZERO_AMOUNT);

        let reserve_x = fungible_asset::balance(pool.token_x_store);
        let reserve_y = fungible_asset::balance(pool.token_y_store);
        let total_supply = pool.lp_total_supply;

        let (lp_to_mint, actual_x, actual_y) = if (total_supply == 0) {
            // First deposit: LP = sqrt(x * y) - MINIMUM_LIQUIDITY
            let lp_amount = math_utils::sqrt((amount_x as u128) * (amount_y as u128));
            assert!(lp_amount > (MINIMUM_LIQUIDITY as u128), E_INSUFFICIENT_INITIAL_LIQUIDITY);
            let lp_amount = lp_amount - (MINIMUM_LIQUIDITY as u128);
            // Mint MINIMUM_LIQUIDITY to zero address (lock forever)
            pool.lp_total_supply = (MINIMUM_LIQUIDITY as u128);
            let locked_lp = lp_token::mint(pool.lp_token_metadata, MINIMUM_LIQUIDITY);
            // Deposit locked LP to the pool itself
            let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
            primary_fungible_store::deposit(signer::address_of(&pool_signer), locked_lp);
            (lp_amount, amount_x, amount_y)
        } else {
            // Subsequent deposits: maintain ratio
            let lp_x = math_utils::mul_div((amount_x as u128), total_supply, (reserve_x as u128));
            let lp_y = math_utils::mul_div((amount_y as u128), total_supply, (reserve_y as u128));
            let lp_amount = math_utils::min_u128(lp_x, lp_y);

            let actual_x = if (lp_amount == lp_x) {
                amount_x
            } else {
                (math_utils::mul_div(lp_amount, (reserve_x as u128), total_supply) as u64)
            };
            let actual_y = if (lp_amount == lp_y) {
                amount_y
            } else {
                (math_utils::mul_div(lp_amount, (reserve_y as u128), total_supply) as u64)
            };
            (lp_amount, actual_x, actual_y)
        };

        assert!((lp_to_mint as u64) >= min_lp_tokens, E_SLIPPAGE_EXCEEDED);

        // Deposit tokens into pool stores
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);

        // Handle refunds for excess tokens
        let refund_x = if (actual_x < amount_x) {
            fungible_asset::extract(&mut token_x, amount_x - actual_x)
        } else {
            fungible_asset::zero(pool.token_x_metadata)
        };
        let refund_y = if (actual_y < amount_y) {
            fungible_asset::extract(&mut token_y, amount_y - actual_y)
        } else {
            fungible_asset::zero(pool.token_y_metadata)
        };

        fungible_asset::deposit(pool.token_x_store, token_x);
        fungible_asset::deposit(pool.token_y_store, token_y);

        // Mint LP tokens
        pool.lp_total_supply = pool.lp_total_supply + lp_to_mint;
        let lp_tokens = lp_token::mint(pool.lp_token_metadata, (lp_to_mint as u64));

        events::emit_liquidity_added(
            pool_addr,
            signer::address_of(provider),
            actual_x,
            actual_y,
            (lp_to_mint as u64),
        );

        _ = pool_signer;
        pool.locked = false;

        (lp_tokens, refund_x, refund_y)
    }

    // ======== Remove Liquidity ========

    public fun remove_liquidity(
        provider: &signer,
        pool_addr: address,
        lp_tokens: FungibleAsset,
        min_x_out: u64,
        min_y_out: u64,
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool {
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(!pool.locked, E_REENTRANCY);
        pool.locked = true;

        let lp_amount = fungible_asset::amount(&lp_tokens);
        assert!(lp_amount > 0, E_ZERO_AMOUNT);

        let reserve_x = fungible_asset::balance(pool.token_x_store);
        let reserve_y = fungible_asset::balance(pool.token_y_store);
        let total_supply = pool.lp_total_supply;

        let amount_x = (math_utils::mul_div((lp_amount as u128), (reserve_x as u128), total_supply) as u64);
        let amount_y = (math_utils::mul_div((lp_amount as u128), (reserve_y as u128), total_supply) as u64);

        assert!(amount_x >= min_x_out, E_SLIPPAGE_EXCEEDED);
        assert!(amount_y >= min_y_out, E_SLIPPAGE_EXCEEDED);

        // Burn LP tokens
        lp_token::burn(pool.lp_token_metadata, lp_tokens);
        pool.lp_total_supply = pool.lp_total_supply - (lp_amount as u128);

        // Withdraw tokens from pool
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let token_x_out = fungible_asset::withdraw(&pool_signer, pool.token_x_store, amount_x);
        let token_y_out = fungible_asset::withdraw(&pool_signer, pool.token_y_store, amount_y);

        events::emit_liquidity_removed(
            pool_addr,
            signer::address_of(provider),
            amount_x,
            amount_y,
            lp_amount,
        );

        pool.locked = false;

        (token_x_out, token_y_out)
    }

    // ======== Swap ========

    public fun swap(
        sender: address,
        pool_addr: address,
        token_in: FungibleAsset,
        min_amount_out: u64,
    ): FungibleAsset acquires LiquidityPool {
        admin::assert_not_paused();
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(!pool.is_paused, E_POOL_PAUSED);
        assert!(!pool.locked, E_REENTRANCY);
        pool.locked = true;

        let amount_in = fungible_asset::amount(&token_in);
        assert!(amount_in > 0, E_ZERO_AMOUNT);

        let token_in_metadata = fungible_asset::metadata_from_asset(&token_in);
        let is_x_to_y = token_in_metadata == pool.token_x_metadata;
        let is_y_to_x = token_in_metadata == pool.token_y_metadata;
        assert!(is_x_to_y || is_y_to_x, E_INVALID_TOKEN);

        let reserve_x = (fungible_asset::balance(pool.token_x_store) as u128);
        let reserve_y = (fungible_asset::balance(pool.token_y_store) as u128);

        // Calculate output with fee
        let fee_amount = percentage::apply_bps((amount_in as u128), pool.fee_bps);
        let amount_in_after_fee = (amount_in as u128) - fee_amount;

        let (reserve_in, reserve_out) = if (is_x_to_y) {
            (reserve_x, reserve_y)
        } else {
            (reserve_y, reserve_x)
        };

        // Constant product: amount_out = reserve_out * amount_in_after_fee / (reserve_in + amount_in_after_fee)
        let amount_out = math_utils::mul_div(
            reserve_out,
            amount_in_after_fee,
            reserve_in + amount_in_after_fee,
        );

        assert!((amount_out as u64) >= min_amount_out, E_SLIPPAGE_EXCEEDED);
        assert!(amount_out < reserve_out, E_INSUFFICIENT_LIQUIDITY);

        // Protocol fee tracking
        let protocol_fee = percentage::apply_bps(fee_amount, pool.protocol_fee_bps);
        if (is_x_to_y) {
            pool.protocol_fee_x = pool.protocol_fee_x + (protocol_fee as u64);
        } else {
            pool.protocol_fee_y = pool.protocol_fee_y + (protocol_fee as u64);
        };

        // Deposit input token
        if (is_x_to_y) {
            fungible_asset::deposit(pool.token_x_store, token_in);
        } else {
            fungible_asset::deposit(pool.token_y_store, token_in);
        };

        // Withdraw output token
        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        let token_out = if (is_x_to_y) {
            fungible_asset::withdraw(&pool_signer, pool.token_y_store, (amount_out as u64))
        } else {
            fungible_asset::withdraw(&pool_signer, pool.token_x_store, (amount_out as u64))
        };

        // Verify K invariant
        let new_reserve_x = (fungible_asset::balance(pool.token_x_store) as u256);
        let new_reserve_y = (fungible_asset::balance(pool.token_y_store) as u256);
        let old_k = (reserve_x as u256) * (reserve_y as u256);
        assert!(new_reserve_x * new_reserve_y >= old_k, E_K_INVARIANT_VIOLATED);

        let (token_in_meta, token_out_meta) = if (is_x_to_y) {
            (pool.token_x_metadata, pool.token_y_metadata)
        } else {
            (pool.token_y_metadata, pool.token_x_metadata)
        };

        events::emit_swap(
            pool_addr,
            sender,
            token_in_meta,
            token_out_meta,
            amount_in,
            (amount_out as u64),
            (fee_amount as u64),
        );

        pool.locked = false;

        token_out
    }

    // ======== Flash Swap Support (friend-only) ========

    public(friend) fun flash_withdraw(
        pool_addr: address,
        amount: u64,
        is_token_x: bool,
    ): FungibleAsset acquires LiquidityPool {
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        assert!(!pool.locked, E_REENTRANCY);

        let pool_signer = object::generate_signer_for_extending(&pool.extend_ref);
        if (is_token_x) {
            fungible_asset::withdraw(&pool_signer, pool.token_x_store, amount)
        } else {
            fungible_asset::withdraw(&pool_signer, pool.token_y_store, amount)
        }
    }

    public(friend) fun flash_repay(
        pool_addr: address,
        token_in: FungibleAsset,
        reserve_x_before: u128,
        reserve_y_before: u128,
    ) acquires LiquidityPool {
        let pool = borrow_global_mut<LiquidityPool>(pool_addr);
        let token_in_metadata = fungible_asset::metadata_from_asset(&token_in);

        if (token_in_metadata == pool.token_x_metadata) {
            fungible_asset::deposit(pool.token_x_store, token_in);
        } else {
            fungible_asset::deposit(pool.token_y_store, token_in);
        };

        // Verify K invariant is maintained
        let new_x = (fungible_asset::balance(pool.token_x_store) as u256);
        let new_y = (fungible_asset::balance(pool.token_y_store) as u256);
        let old_k = (reserve_x_before as u256) * (reserve_y_before as u256);
        assert!(new_x * new_y >= old_k, E_K_INVARIANT_VIOLATED);
    }

    // ======== View Functions ========

    #[view]
    public fun get_reserves(pool_addr: address): (u64, u64) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        (
            fungible_asset::balance(pool.token_x_store),
            fungible_asset::balance(pool.token_y_store),
        )
    }

    #[view]
    public fun get_amount_out(pool_addr: address, amount_in: u64, is_x_to_y: bool): u64 acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        let reserve_x = (fungible_asset::balance(pool.token_x_store) as u128);
        let reserve_y = (fungible_asset::balance(pool.token_y_store) as u128);

        let fee_amount = percentage::apply_bps((amount_in as u128), pool.fee_bps);
        let amount_in_after_fee = (amount_in as u128) - fee_amount;

        let (reserve_in, reserve_out) = if (is_x_to_y) {
            (reserve_x, reserve_y)
        } else {
            (reserve_y, reserve_x)
        };

        (math_utils::mul_div(reserve_out, amount_in_after_fee, reserve_in + amount_in_after_fee) as u64)
    }

    #[view]
    public fun get_fee_bps(pool_addr: address): u64 acquires LiquidityPool {
        borrow_global<LiquidityPool>(pool_addr).fee_bps
    }

    #[view]
    public fun get_lp_total_supply(pool_addr: address): u128 acquires LiquidityPool {
        borrow_global<LiquidityPool>(pool_addr).lp_total_supply
    }

    #[view]
    public fun get_token_metadata(pool_addr: address): (Object<Metadata>, Object<Metadata>) acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        (pool.token_x_metadata, pool.token_y_metadata)
    }

    public fun get_lp_token_metadata(pool_addr: address): Object<Metadata> acquires LiquidityPool {
        borrow_global<LiquidityPool>(pool_addr).lp_token_metadata
    }

    public(friend) fun get_pool_signer(pool_addr: address): signer acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool>(pool_addr);
        object::generate_signer_for_extending(&pool.extend_ref)
    }

    // ======== Internal ========

    fun get_pool_seed(
        token_x_metadata: Object<Metadata>,
        token_y_metadata: Object<Metadata>,
        fee_bps: u64,
    ): vector<u8> {
        let seed = b"POOL_";
        let x_addr = object::object_address(&token_x_metadata);
        let y_addr = object::object_address(&token_y_metadata);
        std::vector::append(&mut seed, std::bcs::to_bytes(&x_addr));
        std::vector::append(&mut seed, std::bcs::to_bytes(&y_addr));
        std::vector::append(&mut seed, std::bcs::to_bytes(&fee_bps));
        seed
    }
}
