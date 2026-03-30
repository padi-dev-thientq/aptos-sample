module defi_aggregator::oracle {
    use std::signer;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use aptos_std::smart_table::{Self, SmartTable};

    friend defi_aggregator::collateral_manager;
    friend defi_aggregator::liquidation;
    friend defi_aggregator::lending_pool;
    friend defi_aggregator::detector;
    friend defi_aggregator::path_finder;
    friend defi_aggregator::lending_aggregator;
    friend defi_aggregator::master_router;

    const E_NOT_ADMIN: u64 = 1;
    const E_PRICE_NOT_FOUND: u64 = 2;
    const E_PRICE_STALE: u64 = 3;
    const E_ALREADY_INITIALIZED: u64 = 4;
    const E_ZERO_PRICE: u64 = 5;

    /// Price is stored as USD * 10^decimals (e.g., $1.00 with decimals=8 => 100_000_000)
    struct PriceFeed has store, drop, copy {
        price: u128,
        decimals: u8,
        last_updated: u64,
        confidence_bps: u64,
    }

    struct OracleConfig has key {
        admin: address,
        price_feeds: SmartTable<address, PriceFeed>, // key = metadata object address
    }

    public entry fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<OracleConfig>(@defi_aggregator), E_ALREADY_INITIALIZED);
        move_to(admin, OracleConfig {
            admin: admin_addr,
            price_feeds: smart_table::new(),
        });
    }

    public entry fun update_price(
        admin: &signer,
        asset_metadata: Object<Metadata>,
        price: u128,
        decimals: u8,
        confidence_bps: u64,
    ) acquires OracleConfig {
        let config = borrow_global_mut<OracleConfig>(@defi_aggregator);
        assert!(signer::address_of(admin) == config.admin, E_NOT_ADMIN);
        assert!(price > 0, E_ZERO_PRICE);

        let asset_addr = object::object_address(&asset_metadata);
        let feed = PriceFeed {
            price,
            decimals,
            last_updated: timestamp::now_seconds(),
            confidence_bps,
        };

        if (smart_table::contains(&config.price_feeds, asset_addr)) {
            *smart_table::borrow_mut(&mut config.price_feeds, asset_addr) = feed;
        } else {
            smart_table::add(&mut config.price_feeds, asset_addr, feed);
        };
    }

    /// Get price without staleness check
    public fun get_price(asset_metadata: Object<Metadata>): (u128, u8, u64) acquires OracleConfig {
        let config = borrow_global<OracleConfig>(@defi_aggregator);
        let asset_addr = object::object_address(&asset_metadata);
        assert!(smart_table::contains(&config.price_feeds, asset_addr), E_PRICE_NOT_FOUND);
        let feed = smart_table::borrow(&config.price_feeds, asset_addr);
        (feed.price, feed.decimals, feed.last_updated)
    }

    /// Get price with staleness check - aborts if price is older than max_staleness_secs
    public fun get_price_safe(
        asset_metadata: Object<Metadata>,
        max_staleness_secs: u64,
    ): (u128, u8) acquires OracleConfig {
        let (price, decimals, last_updated) = get_price(asset_metadata);
        let now = timestamp::now_seconds();
        assert!(now - last_updated <= max_staleness_secs, E_PRICE_STALE);
        (price, decimals)
    }

    /// Get price normalized to 8 decimals
    public fun get_price_u128_8dec(asset_metadata: Object<Metadata>): u128 acquires OracleConfig {
        let (price, decimals, _) = get_price(asset_metadata);
        if (decimals == 8) {
            price
        } else if (decimals < 8) {
            price * pow10((8 - decimals as u8))
        } else {
            price / pow10((decimals - 8 as u8))
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

    /// Check if a price exists for the given asset
    public fun has_price(asset_metadata: Object<Metadata>): bool acquires OracleConfig {
        let config = borrow_global<OracleConfig>(@defi_aggregator);
        let asset_addr = object::object_address(&asset_metadata);
        smart_table::contains(&config.price_feeds, asset_addr)
    }

    use aptos_framework::object;
}
