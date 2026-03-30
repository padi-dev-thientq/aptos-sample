module defi_aggregator::lending_aggregator {
    use std::vector;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use defi_aggregator::lending_pool;
    use defi_aggregator::admin;

    const E_NO_MARKET_FOUND: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;

    #[view]
    public fun best_supply_rate(asset_metadata: Object<Metadata>): (address, u64) {
        let markets = lending_pool::get_all_markets();
        let best_market = @0x0;
        let best_rate = 0u64;

        let i = 0;
        let len = vector::length(&markets);
        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let market_asset = lending_pool::get_market_asset_metadata(market_addr);

            if (object::object_address(&market_asset) == object::object_address(&asset_metadata)) {
                let rate = lending_pool::get_supply_rate(market_addr);
                if (rate > best_rate || best_market == @0x0) {
                    best_rate = rate;
                    best_market = market_addr;
                };
            };

            i = i + 1;
        };

        (best_market, best_rate)
    }

    #[view]
    public fun best_borrow_rate(asset_metadata: Object<Metadata>): (address, u64) {
        let markets = lending_pool::get_all_markets();
        let best_market = @0x0;
        let best_rate = 18446744073709551615u64; // max u64

        let i = 0;
        let len = vector::length(&markets);
        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let market_asset = lending_pool::get_market_asset_metadata(market_addr);

            if (object::object_address(&market_asset) == object::object_address(&asset_metadata)) {
                let rate = lending_pool::get_borrow_rate(market_addr);
                if (rate < best_rate) {
                    best_rate = rate;
                    best_market = market_addr;
                };
            };

            i = i + 1;
        };

        if (best_market == @0x0) {
            best_rate = 0;
        };

        (best_market, best_rate)
    }

    /// Supply to the best-rate market for the given asset
    public entry fun supply_best_rate(
        user: &signer,
        asset_metadata: Object<Metadata>,
        amount: u64,
    ) {
        admin::assert_not_paused();
        assert!(amount > 0, E_ZERO_AMOUNT);

        let (best_market, _rate) = best_supply_rate(asset_metadata);
        assert!(best_market != @0x0, E_NO_MARKET_FOUND);

        let asset = primary_fungible_store::withdraw(user, asset_metadata, amount);
        lending_pool::supply(user, best_market, asset);
    }

    #[view]
    public fun get_all_rates(asset_metadata: Object<Metadata>): (vector<address>, vector<u64>, vector<u64>) {
        let markets = lending_pool::get_all_markets();
        let market_addrs = vector::empty<address>();
        let supply_rates = vector::empty<u64>();
        let borrow_rates = vector::empty<u64>();

        let i = 0;
        let len = vector::length(&markets);
        while (i < len) {
            let market_addr = *vector::borrow(&markets, i);
            let market_asset = lending_pool::get_market_asset_metadata(market_addr);

            if (object::object_address(&market_asset) == object::object_address(&asset_metadata)) {
                vector::push_back(&mut market_addrs, market_addr);
                vector::push_back(&mut supply_rates, lending_pool::get_supply_rate(market_addr));
                vector::push_back(&mut borrow_rates, lending_pool::get_borrow_rate(market_addr));
            };

            i = i + 1;
        };

        (market_addrs, supply_rates, borrow_rates)
    }
}
