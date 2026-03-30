module defi_aggregator::executor {
    use std::signer;
    use std::vector;
    use aptos_framework::fungible_asset::{Self};
    use aptos_framework::primary_fungible_store;
    use defi_aggregator::pool;
    use defi_aggregator::flash_swap;
    use defi_aggregator::flash_loan;
    use defi_aggregator::events;
    use defi_aggregator::admin;

    const E_NO_PROFIT: u64 = 1;
    const E_INSUFFICIENT_PROFIT: u64 = 2;
    const E_EMPTY_PATH: u64 = 3;

    /// Execute a two-pool arbitrage using flash swap from pool A
    /// Flow: flash borrow from pool_a -> swap in pool_b -> repay pool_a -> keep profit
    public entry fun execute_two_pool_arb(
        executor: &signer,
        pool_a: address,
        pool_b: address,
        amount: u64,
        is_token_x: bool,
        min_profit: u64,
    ) {
        admin::assert_not_paused();
        let executor_addr = signer::address_of(executor);

        // Flash borrow from pool A
        let (borrowed_tokens, receipt) = flash_swap::borrow(executor, pool_a, amount, is_token_x);

        // Swap in pool B
        let swapped_tokens = pool::swap(executor_addr, pool_b, borrowed_tokens, 0);

        // Calculate repayment needed
        let repayment_amount = flash_swap::get_repayment_amount(amount);
        let total_received = fungible_asset::amount(&swapped_tokens);
        assert!(total_received > repayment_amount, E_NO_PROFIT);

        let profit = total_received - repayment_amount;
        assert!(profit >= min_profit, E_INSUFFICIENT_PROFIT);

        // Extract repayment and keep profit
        let repayment = fungible_asset::extract(&mut swapped_tokens, repayment_amount);
        flash_swap::repay(executor, receipt, repayment);

        // Deposit profit to executor
        primary_fungible_store::deposit(executor_addr, swapped_tokens);

        let path = vector::empty<address>();
        vector::push_back(&mut path, pool_a);
        vector::push_back(&mut path, pool_b);
        events::emit_arbitrage(executor_addr, path, amount, profit, 0);
    }

    /// Execute triangular arbitrage using flash loan from lending pool
    /// Flow: flash loan -> swap pool1 -> swap pool2 -> swap pool3 -> repay loan -> keep profit
    public entry fun execute_triangular_arb_flash_loan(
        executor: &signer,
        flash_loan_market: address,
        pool1: address,
        pool2: address,
        pool3: address,
        amount: u64,
        min_profit: u64,
    ) {
        admin::assert_not_paused();
        let executor_addr = signer::address_of(executor);

        // Flash loan from lending pool
        let (borrowed, receipt) = flash_loan::borrow(executor, flash_loan_market, amount);

        // Swap through 3 pools
        let after_pool1 = pool::swap(executor_addr, pool1, borrowed, 0);
        let after_pool2 = pool::swap(executor_addr, pool2, after_pool1, 0);
        let after_pool3 = pool::swap(executor_addr, pool3, after_pool2, 0);

        // Calculate repayment
        let repayment_amount = flash_loan::get_repayment_amount(amount);
        let total_received = fungible_asset::amount(&after_pool3);
        assert!(total_received > repayment_amount, E_NO_PROFIT);

        let profit = total_received - repayment_amount;
        assert!(profit >= min_profit, E_INSUFFICIENT_PROFIT);

        // Repay flash loan
        let repayment = fungible_asset::extract(&mut after_pool3, repayment_amount);
        flash_loan::repay(executor, receipt, repayment);

        // Keep profit
        primary_fungible_store::deposit(executor_addr, after_pool3);

        let path = vector::empty<address>();
        vector::push_back(&mut path, pool1);
        vector::push_back(&mut path, pool2);
        vector::push_back(&mut path, pool3);
        events::emit_arbitrage(executor_addr, path, amount, profit, 1);
    }

    /// Execute multi-hop arbitrage using flash swap (no lending needed)
    /// The first pool provides the flash swap, then swap through remaining pools, repay first pool
    public entry fun execute_multihop_arb_flash_swap(
        executor: &signer,
        pools: vector<address>,
        amount: u64,
        is_token_x: bool,
        min_profit: u64,
    ) {
        admin::assert_not_paused();
        let executor_addr = signer::address_of(executor);
        let num_pools = vector::length(&pools);
        assert!(num_pools >= 2, E_EMPTY_PATH);

        let first_pool = *vector::borrow(&pools, 0);

        // Flash borrow from first pool
        let (borrowed, receipt) = flash_swap::borrow(executor, first_pool, amount, is_token_x);

        // Swap through remaining pools
        let current_tokens = borrowed;
        let i = 1;
        while (i < num_pools) {
            let next_pool = *vector::borrow(&pools, i);
            current_tokens = pool::swap(executor_addr, next_pool, current_tokens, 0);
            i = i + 1;
        };

        // Repay flash swap
        let repayment_amount = flash_swap::get_repayment_amount(amount);
        let total_received = fungible_asset::amount(&current_tokens);
        assert!(total_received > repayment_amount, E_NO_PROFIT);

        let profit = total_received - repayment_amount;
        assert!(profit >= min_profit, E_INSUFFICIENT_PROFIT);

        let repayment = fungible_asset::extract(&mut current_tokens, repayment_amount);
        flash_swap::repay(executor, receipt, repayment);

        primary_fungible_store::deposit(executor_addr, current_tokens);

        events::emit_arbitrage(executor_addr, pools, amount, profit, 2);
    }
}
