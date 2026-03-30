module defi_aggregator::lp_token {
    use std::string::{Self, String};
    use std::option;
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset, MintRef, BurnRef};
    use aptos_framework::object::{Self, Object, ConstructorRef};
    use aptos_framework::primary_fungible_store;

    friend defi_aggregator::pool;

    const E_NOT_AUTHORIZED: u64 = 1;

    /// Stored on each LP token's metadata object
    struct LPTokenRefs has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    /// Create LP token metadata for a pool. Returns the metadata object.
    public(friend) fun create_lp_token(
        constructor_ref: &ConstructorRef,
        name: String,
        symbol: String,
        decimals: u8,
    ): Object<Metadata> {
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(), // no max supply
            name,
            symbol,
            decimals,
            string::utf8(b""), // icon_uri
            string::utf8(b""), // project_uri
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);

        let metadata_signer = object::generate_signer(constructor_ref);
        move_to(&metadata_signer, LPTokenRefs {
            mint_ref,
            burn_ref,
        });

        object::object_from_constructor_ref<Metadata>(constructor_ref)
    }

    /// Mint LP tokens
    public(friend) fun mint(lp_metadata: Object<Metadata>, amount: u64): FungibleAsset acquires LPTokenRefs {
        let lp_addr = object::object_address(&lp_metadata);
        let refs = borrow_global<LPTokenRefs>(lp_addr);
        fungible_asset::mint(&refs.mint_ref, amount)
    }

    /// Burn LP tokens
    public(friend) fun burn(lp_metadata: Object<Metadata>, lp_tokens: FungibleAsset) acquires LPTokenRefs {
        let lp_addr = object::object_address(&lp_metadata);
        let refs = borrow_global<LPTokenRefs>(lp_addr);
        fungible_asset::burn(&refs.burn_ref, lp_tokens);
    }
}
