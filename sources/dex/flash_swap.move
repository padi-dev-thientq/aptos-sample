module defi_aggregator::flash_swap {
    use std::signer;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use defi_aggregator::pool;
    use defi_aggregator::percentage;
    use defi_aggregator::events;

    friend defi_aggregator::executor;
    friend defi_aggregator::router;

    const E_INSUFFICIENT_REPAYMENT: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;

    const FLASH_SWAP_FEE_BPS: u64 = 30; // 0.3% flash swap fee

    /// Receipt that MUST be consumed before tx ends.
    /// No `drop` ability = Move compiler enforces repayment.
    struct FlashSwapReceipt {
        pool_addr: address,
        amount_borrowed: u64,
        is_token_x: bool,
        fee_amount: u64,
        reserve_x_before: u128,
        reserve_y_before: u128,
    }

    /// Borrow tokens from a pool without upfront payment.
    /// Returns tokens + receipt. Receipt MUST be consumed via repay().
    public fun borrow(
        borrower: &signer,
        pool_addr: address,
        amount: u64,
        is_token_x: bool,
    ): (FungibleAsset, FlashSwapReceipt) {
        assert!(amount > 0, E_ZERO_AMOUNT);

        let (reserve_x, reserve_y) = pool::get_reserves(pool_addr);
        let fee_amount = (percentage::apply_bps((amount as u128), FLASH_SWAP_FEE_BPS) as u64);

        let tokens = pool::flash_withdraw(pool_addr, amount, is_token_x);

        let receipt = FlashSwapReceipt {
            pool_addr,
            amount_borrowed: amount,
            is_token_x,
            fee_amount,
            reserve_x_before: (reserve_x as u128),
            reserve_y_before: (reserve_y as u128),
        };

        _ = signer::address_of(borrower);

        (tokens, receipt)
    }

    /// Repay the flash swap. Consumes receipt (enforced by Move type system).
    public fun repay(
        borrower: &signer,
        receipt: FlashSwapReceipt,
        repayment: FungibleAsset,
    ) {
        let FlashSwapReceipt {
            pool_addr,
            amount_borrowed,
            is_token_x: _,
            fee_amount,
            reserve_x_before,
            reserve_y_before,
        } = receipt;

        let repaid_amount = fungible_asset::amount(&repayment);
        assert!(repaid_amount >= amount_borrowed + fee_amount, E_INSUFFICIENT_REPAYMENT);

        // Deposit back to pool and verify K invariant
        pool::flash_repay(pool_addr, repayment, reserve_x_before, reserve_y_before);

        events::emit_flash_swap(
            pool_addr,
            signer::address_of(borrower),
            amount_borrowed,
            fee_amount,
        );
    }

    /// Get the required repayment amount for a flash swap
    public fun get_repayment_amount(amount: u64): u64 {
        let fee = (percentage::apply_bps((amount as u128), FLASH_SWAP_FEE_BPS) as u64);
        amount + fee
    }
}
