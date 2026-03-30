module defi_aggregator::admin {
    use std::signer;
    use aptos_framework::object::{Self, ExtendRef};

    friend defi_aggregator::events;
    friend defi_aggregator::oracle;
    friend defi_aggregator::pool;
    friend defi_aggregator::pool_manager;
    friend defi_aggregator::lp_token;
    friend defi_aggregator::flash_swap;
    friend defi_aggregator::router;
    friend defi_aggregator::lending_pool;
    friend defi_aggregator::collateral_manager;
    friend defi_aggregator::liquidation;
    friend defi_aggregator::flash_loan;
    friend defi_aggregator::interest_rate_model;
    friend defi_aggregator::detector;
    friend defi_aggregator::executor;
    friend defi_aggregator::path_finder;
    friend defi_aggregator::swap_aggregator;
    friend defi_aggregator::lending_aggregator;
    friend defi_aggregator::master_router;

    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_PENDING_ADMIN: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_ALREADY_INITIALIZED: u64 = 4;
    const E_NOT_GUARDIAN: u64 = 5;
    const E_ZERO_ADDRESS: u64 = 6;

    const SEED: vector<u8> = b"DEFI_AGGREGATOR_ADMIN";

    struct GlobalConfig has key {
        admin: address,
        pending_admin: address,
        is_paused: bool,
        fee_collector: address,
        extend_ref: ExtendRef,
    }

    struct EmergencyAdmin has key {
        guardian: address,
    }

    public entry fun initialize(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        assert!(!exists<GlobalConfig>(deployer_addr), E_ALREADY_INITIALIZED);

        let constructor_ref = object::create_named_object(deployer, SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(deployer, GlobalConfig {
            admin: deployer_addr,
            pending_admin: @0x0,
            is_paused: false,
            fee_collector: deployer_addr,
            extend_ref,
        });

        move_to(deployer, EmergencyAdmin {
            guardian: deployer_addr,
        });
    }

    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(get_config_address());
        assert!(signer::address_of(admin) == config.admin, E_NOT_ADMIN);
        assert!(new_admin != @0x0, E_ZERO_ADDRESS);
        config.pending_admin = new_admin;
    }

    public entry fun accept_admin(new_admin: &signer) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(get_config_address());
        assert!(signer::address_of(new_admin) == config.pending_admin, E_NOT_PENDING_ADMIN);
        config.admin = config.pending_admin;
        config.pending_admin = @0x0;
    }

    public entry fun set_fee_collector(admin: &signer, collector: address) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(get_config_address());
        assert!(signer::address_of(admin) == config.admin, E_NOT_ADMIN);
        config.fee_collector = collector;
    }

    public entry fun global_pause(guardian: &signer) acquires GlobalConfig, EmergencyAdmin {
        let emergency = borrow_global<EmergencyAdmin>(get_config_address());
        assert!(signer::address_of(guardian) == emergency.guardian, E_NOT_GUARDIAN);
        let config = borrow_global_mut<GlobalConfig>(get_config_address());
        config.is_paused = true;
    }

    public entry fun global_unpause(admin: &signer) acquires GlobalConfig {
        let config = borrow_global_mut<GlobalConfig>(get_config_address());
        assert!(signer::address_of(admin) == config.admin, E_NOT_ADMIN);
        config.is_paused = false;
    }

    public entry fun set_emergency_guardian(admin: &signer, guardian: address) acquires GlobalConfig, EmergencyAdmin {
        let config = borrow_global<GlobalConfig>(get_config_address());
        assert!(signer::address_of(admin) == config.admin, E_NOT_ADMIN);
        let emergency = borrow_global_mut<EmergencyAdmin>(get_config_address());
        emergency.guardian = guardian;
    }

    // --- Public accessors used by other modules ---

    public fun assert_admin(account: &signer) acquires GlobalConfig {
        let config = borrow_global<GlobalConfig>(get_config_address());
        assert!(signer::address_of(account) == config.admin, E_NOT_ADMIN);
    }

    public fun assert_not_paused() acquires GlobalConfig {
        let config = borrow_global<GlobalConfig>(get_config_address());
        assert!(!config.is_paused, E_PAUSED);
    }

    public fun get_admin(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(get_config_address()).admin
    }

    public fun get_fee_collector(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(get_config_address()).fee_collector
    }

    public fun is_paused(): bool acquires GlobalConfig {
        borrow_global<GlobalConfig>(get_config_address()).is_paused
    }

    fun get_config_address(): address {
        @defi_aggregator
    }
}
