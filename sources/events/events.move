module defi_aggregator::events {
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

    friend defi_aggregator::pool;
    friend defi_aggregator::pool_manager;
    friend defi_aggregator::lp_token;
    friend defi_aggregator::flash_swap;
    friend defi_aggregator::router;
    friend defi_aggregator::lending_pool;
    friend defi_aggregator::collateral_manager;
    friend defi_aggregator::liquidation;
    friend defi_aggregator::flash_loan;
    friend defi_aggregator::executor;
    friend defi_aggregator::swap_aggregator;
    friend defi_aggregator::lending_aggregator;
    friend defi_aggregator::master_router;

    // ======== DEX Events ========

    #[event]
    struct PoolCreated has drop, store {
        pool_addr: address,
        token_x: Object<Metadata>,
        token_y: Object<Metadata>,
        fee_bps: u64,
    }

    #[event]
    struct SwapExecuted has drop, store {
        pool_addr: address,
        sender: address,
        token_in: Object<Metadata>,
        token_out: Object<Metadata>,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64,
    }

    #[event]
    struct LiquidityAdded has drop, store {
        pool_addr: address,
        provider: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_minted: u64,
    }

    #[event]
    struct LiquidityRemoved has drop, store {
        pool_addr: address,
        provider: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_burned: u64,
    }

    #[event]
    struct FlashSwapExecuted has drop, store {
        pool_addr: address,
        borrower: address,
        amount_borrowed: u64,
        fee_paid: u64,
    }

    // ======== Lending Events ========

    #[event]
    struct MarketCreated has drop, store {
        market_addr: address,
        asset: Object<Metadata>,
        collateral_factor_bps: u64,
    }

    #[event]
    struct SupplyEvent has drop, store {
        market_addr: address,
        user: address,
        amount: u64,
        shares_minted: u128,
    }

    #[event]
    struct WithdrawEvent has drop, store {
        market_addr: address,
        user: address,
        amount: u64,
        shares_burned: u128,
    }

    #[event]
    struct BorrowEvent has drop, store {
        market_addr: address,
        user: address,
        amount: u64,
    }

    #[event]
    struct RepayEvent has drop, store {
        market_addr: address,
        user: address,
        amount: u64,
    }

    #[event]
    struct LiquidationEvent has drop, store {
        liquidator: address,
        borrower: address,
        repay_market: address,
        collateral_market: address,
        repay_amount: u64,
        collateral_seized: u64,
    }

    #[event]
    struct FlashLoanExecuted has drop, store {
        market_addr: address,
        borrower: address,
        amount: u64,
        fee: u64,
    }

    // ======== Arbitrage Events ========

    #[event]
    struct ArbitrageExecuted has drop, store {
        executor: address,
        path: vector<address>,
        input_amount: u64,
        profit: u64,
        arb_type: u8, // 0 = two-pool, 1 = triangular, 2 = multi-hop
    }

    // ======== Emit Functions (friend-only) ========

    public(friend) fun emit_pool_created(
        pool_addr: address,
        token_x: Object<Metadata>,
        token_y: Object<Metadata>,
        fee_bps: u64,
    ) {
        event::emit(PoolCreated { pool_addr, token_x, token_y, fee_bps });
    }

    public(friend) fun emit_swap(
        pool_addr: address,
        sender: address,
        token_in: Object<Metadata>,
        token_out: Object<Metadata>,
        amount_in: u64,
        amount_out: u64,
        fee_amount: u64,
    ) {
        event::emit(SwapExecuted { pool_addr, sender, token_in, token_out, amount_in, amount_out, fee_amount });
    }

    public(friend) fun emit_liquidity_added(
        pool_addr: address,
        provider: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_minted: u64,
    ) {
        event::emit(LiquidityAdded { pool_addr, provider, amount_x, amount_y, lp_tokens_minted });
    }

    public(friend) fun emit_liquidity_removed(
        pool_addr: address,
        provider: address,
        amount_x: u64,
        amount_y: u64,
        lp_tokens_burned: u64,
    ) {
        event::emit(LiquidityRemoved { pool_addr, provider, amount_x, amount_y, lp_tokens_burned });
    }

    public(friend) fun emit_flash_swap(
        pool_addr: address,
        borrower: address,
        amount_borrowed: u64,
        fee_paid: u64,
    ) {
        event::emit(FlashSwapExecuted { pool_addr, borrower, amount_borrowed, fee_paid });
    }

    public(friend) fun emit_market_created(
        market_addr: address,
        asset: Object<Metadata>,
        collateral_factor_bps: u64,
    ) {
        event::emit(MarketCreated { market_addr, asset, collateral_factor_bps });
    }

    public(friend) fun emit_supply(
        market_addr: address,
        user: address,
        amount: u64,
        shares_minted: u128,
    ) {
        event::emit(SupplyEvent { market_addr, user, amount, shares_minted });
    }

    public(friend) fun emit_withdraw(
        market_addr: address,
        user: address,
        amount: u64,
        shares_burned: u128,
    ) {
        event::emit(WithdrawEvent { market_addr, user, amount, shares_burned });
    }

    public(friend) fun emit_borrow(
        market_addr: address,
        user: address,
        amount: u64,
    ) {
        event::emit(BorrowEvent { market_addr, user, amount });
    }

    public(friend) fun emit_repay(
        market_addr: address,
        user: address,
        amount: u64,
    ) {
        event::emit(RepayEvent { market_addr, user, amount });
    }

    public(friend) fun emit_liquidation(
        liquidator: address,
        borrower: address,
        repay_market: address,
        collateral_market: address,
        repay_amount: u64,
        collateral_seized: u64,
    ) {
        event::emit(LiquidationEvent { liquidator, borrower, repay_market, collateral_market, repay_amount, collateral_seized });
    }

    public(friend) fun emit_flash_loan(
        market_addr: address,
        borrower: address,
        amount: u64,
        fee: u64,
    ) {
        event::emit(FlashLoanExecuted { market_addr, borrower, amount, fee });
    }

    public(friend) fun emit_arbitrage(
        executor: address,
        path: vector<address>,
        input_amount: u64,
        profit: u64,
        arb_type: u8,
    ) {
        event::emit(ArbitrageExecuted { executor, path, input_amount, profit, arb_type });
    }
}
