module defi_aggregator::flash_loan {
    use std::signer;
    use aptos_framework::fungible_asset::{Self, FungibleAsset};
    use defi_aggregator::lending_pool;
    use defi_aggregator::percentage;
    use defi_aggregator::events;
    use defi_aggregator::admin;

    friend defi_aggregator::executor;

    const E_INSUFFICIENT_REPAYMENT: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;

    /// Flash loan fee: 0.09% (9 bps)
    const FLASH_LOAN_FEE_BPS: u64 = 9;

    /// Receipt with no `drop` -- MUST be consumed via repay()
    struct FlashLoanReceipt {
        market_addr: address,
        amount: u64,
        fee: u64,
    }

    /// Borrow from lending pool reserves without collateral
    public fun borrow(
        borrower: &signer,
        market_addr: address,
        amount: u64,
    ): (FungibleAsset, FlashLoanReceipt) {
        admin::assert_not_paused();
        assert!(amount > 0, E_ZERO_AMOUNT);

        let fee = (percentage::apply_bps((amount as u128), FLASH_LOAN_FEE_BPS) as u64);
        if (fee == 0) fee = 1; // minimum 1 unit fee

        let tokens = lending_pool::flash_borrow(market_addr, amount);

        let receipt = FlashLoanReceipt {
            market_addr,
            amount,
            fee,
        };

        _ = signer::address_of(borrower);

        (tokens, receipt)
    }

    /// Repay flash loan. Consumes receipt (Move enforces this).
    public fun repay(
        borrower: &signer,
        receipt: FlashLoanReceipt,
        repayment: FungibleAsset,
    ) {
        let FlashLoanReceipt { market_addr, amount, fee } = receipt;

        let repaid = fungible_asset::amount(&repayment);
        assert!(repaid >= amount + fee, E_INSUFFICIENT_REPAYMENT);

        lending_pool::flash_repay(market_addr, repayment);

        events::emit_flash_loan(
            market_addr,
            signer::address_of(borrower),
            amount,
            fee,
        );
    }

    /// Get the required repayment amount
    public fun get_repayment_amount(amount: u64): u64 {
        let fee = (percentage::apply_bps((amount as u128), FLASH_LOAN_FEE_BPS) as u64);
        if (fee == 0) {
            amount + 1
        } else {
            amount + fee
        }
    }

    /// Get the fee for a flash loan
    public fun get_fee(amount: u64): u64 {
        let fee = (percentage::apply_bps((amount as u128), FLASH_LOAN_FEE_BPS) as u64);
        if (fee == 0) 1 else fee
    }
}
