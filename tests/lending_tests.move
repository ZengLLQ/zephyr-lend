#[test_only]
module zephyr_lend::lending_tests {
    use std::signer;
    use aptos_framework::string::utf8;
    use aptos_framework::account;
    use zephyr_lend::fixed_point;
    use zephyr_lend::interest_model;
    use zephyr_lend::pool;

    #[test]
    fun test_fixed_point_arithmetic() {
        let wad = fixed_point::wad();
        assert!(wad == 1000000000, 1);

        // 2 * 3 = 6 in WAD
        let a = 2 * wad;
        let b = 3 * wad;
        let c = fixed_point::wad_mul(a, b);
        assert!(c == 6 * wad, 2);

        // 10 / 2 = 5 in WAD
        let d = 10 * wad;
        let e = 2 * wad;
        let f = fixed_point::wad_div(d, e);
        assert!(f == 5 * wad, 3);

        // 1000 with 500 bps (5%) = 50
        let g = fixed_point::apply_bps(1000, 500);
        assert!(g == 50, 4);
    }

    #[test]
    fun test_jump_rate_model() {
        let wad = fixed_point::wad();
        let base_rate = fixed_point::apply_bps(wad, 200); // 2%
        let slope1 = fixed_point::apply_bps(wad, 1000);   // 10%
        let slope2 = fixed_point::apply_bps(wad, 20000);  // 200%
        let kink = fixed_point::apply_bps(wad, 8000);     // 80%
        let reserve_factor = 1000;                        // 10%

        let model = interest_model::new_model(base_rate, slope1, slope2, kink, reserve_factor);

        // At 0% utilization
        let util0 = interest_model::utilization_rate(10000, 0, 0);
        assert!(util0 == 0, 10);
        let r0 = interest_model::borrow_rate_per_year(&model, 10000, 0, 0);
        assert!(r0 == base_rate, 11);

        // Below kink: 50% utilization (cash 5000, borrow 5000)
        let util50 = interest_model::utilization_rate(5000, 5000, 0);
        assert!(util50 == wad / 2, 12);
        let r50 = interest_model::borrow_rate_per_year(&model, 5000, 5000, 0);
        assert!(r50 > base_rate, 13);

        // Above kink: 90% utilization (cash 1000, borrow 9000)
        let _util90 = interest_model::utilization_rate(1000, 9000, 0);
        let r90 = interest_model::borrow_rate_per_year(&model, 1000, 9000, 0);
        // Rate above kink jumps significantly
        assert!(r90 > base_rate + slope1, 14);
    }

    #[test(admin = @zephyr_lend, alice = @0x101, bob = @0x102)]
    fun test_deposit_borrow_repay(
        admin: &signer,
        alice: &signer,
        bob: &signer
    ) {
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));

        pool::initialize_protocol(admin);

        let wad = fixed_point::wad();
        let model = interest_model::new_model(
            fixed_point::apply_bps(wad, 200),
            fixed_point::apply_bps(wad, 1000),
            fixed_point::apply_bps(wad, 15000),
            fixed_point::apply_bps(wad, 8000),
            1000
        );

        let usdc = utf8(b"USDC");
        pool::create_reserve(admin, usdc, 8000, 8500, 500, model, 1000);

        // Alice deposits 10,000 USDC
        pool::deposit(alice, usdc, 10000);
        assert!(pool::get_user_collateral(signer::address_of(alice), usdc) == 10000, 20);
        assert!(pool::get_reserve_cash(usdc) == 10000, 21);

        // Bob deposits 5,000 collateral and borrows 2,000 USDC
        pool::deposit(bob, usdc, 5000);
        pool::borrow(bob, usdc, 2000);
        assert!(pool::get_user_borrow(signer::address_of(bob), usdc) == 2000, 22);
        assert!(pool::get_reserve_cash(usdc) == 13000, 23);
        assert!(pool::get_reserve_borrows(usdc) == 2000, 24);

        // Bob repays 1,000 USDC
        pool::repay(bob, usdc, 1000);
        assert!(pool::get_user_borrow(signer::address_of(bob), usdc) == 1000, 25);
        assert!(pool::get_reserve_cash(usdc) == 14000, 26);
    }

    #[test(admin = @zephyr_lend, alice = @0x101, liquidator = @0x103)]
    fun test_liquidation_flow(
        admin: &signer,
        alice: &signer,
        liquidator: &signer
    ) {
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(liquidator));

        pool::initialize_protocol(admin);

        let wad = fixed_point::wad();
        let model = interest_model::new_model(
            fixed_point::apply_bps(wad, 200),
            fixed_point::apply_bps(wad, 1000),
            fixed_point::apply_bps(wad, 15000),
            fixed_point::apply_bps(wad, 8000),
            1000
        );

        let usdc = utf8(b"USDC");
        let apt = utf8(b"APT");
        pool::create_reserve(admin, usdc, 8000, 8500, 500, model, 1000);
        pool::create_reserve(admin, apt, 7000, 7500, 500, model, 1000);

        // Liquidator supplies USDC liquidity: 50,000 units
        pool::deposit(liquidator, usdc, 50000 * wad);

        // Alice deposits 10 APT as collateral (APT price $10 = $100)
        pool::deposit(alice, apt, 10 * wad);

        // Alice borrows 50 USDC ($50)
        pool::borrow(alice, usdc, 50 * wad);
        assert!(pool::get_user_borrow(signer::address_of(alice), usdc) == 50 * wad, 30);

        // Price drops: APT drops to $5.50 (collateral is $55, debt is $50 -> undercollateralized)
        // Liquidator liquidates 20 USDC of debt
        // Liquidator repays 20 USDC ($20) + 5% bonus ($21 value seized)
        // Seized APT = $21 / $5.50 = 3.818 APT
        let debt_price_usd = 1 * wad; // $1.00
        let collat_price_usd = (55 * wad) / 10; // $5.50

        pool::liquidate(
            liquidator,
            signer::address_of(alice),
            usdc,
            apt,
            20 * wad,
            debt_price_usd,
            collat_price_usd
        );

        // Verify remaining debt
        assert!(pool::get_user_borrow(signer::address_of(alice), usdc) == 30 * wad, 31);
        // Verify liquidator received seized collateral
        let liq_collat = pool::get_user_collateral(signer::address_of(liquidator), apt);
        assert!(liq_collat > 0, 32);
    }
}
