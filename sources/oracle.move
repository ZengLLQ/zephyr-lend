module zephyr_lend::oracle {
    use std::signer;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::string::String;

    struct PriceRegistry has key {
        prices: Table<String, u64>,
    }

    const ERR_UNAUTHORIZED: u64 = 301;
    const ERR_PRICE_NOT_FOUND: u64 = 302;

    public fun initialize(admin: &signer) {
        let registry = PriceRegistry {
            prices: table::new(),
        };
        move_to(admin, registry);
    }

    public fun set_price(admin: &signer, asset: String, price_usd_wad: u64) acquires PriceRegistry {
        assert!(signer::address_of(admin) == @zephyr_lend, ERR_UNAUTHORIZED);
        let registry = borrow_global_mut<PriceRegistry>(@zephyr_lend);
        if (table::contains(&registry.prices, asset)) {
            let p = table::borrow_mut(&mut registry.prices, asset);
            *p = price_usd_wad;
        } else {
            table::add(&mut registry.prices, asset, price_usd_wad);
        };
    }

    public fun get_price(asset: String): u64 acquires PriceRegistry {
        let registry = borrow_global<PriceRegistry>(@zephyr_lend);
        assert!(table::contains(&registry.prices, asset), ERR_PRICE_NOT_FOUND);
        *table::borrow(&registry.prices, asset)
    }
}
