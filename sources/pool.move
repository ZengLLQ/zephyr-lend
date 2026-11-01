module zephyr_lend::pool {
    use std::signer;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::string::String;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use zephyr_lend::fixed_point;
    use zephyr_lend::interest_model::{Self, JumpRateModel};

    // Error codes
    const ERR_UNAUTHORIZED: u64 = 401;
    const ERR_RESERVE_EXISTS: u64 = 402;
    const ERR_RESERVE_NOT_FOUND: u64 = 403;
    const ERR_INSUFFICIENT_LIQUIDITY: u64 = 404;
    const ERR_INSUFFICIENT_COLLATERAL: u64 = 405;
    const ERR_HEALTH_FACTOR_TOO_LOW: u64 = 406;
    const ERR_BORROWER_HEALTHY: u64 = 407;
    const ERR_ZERO_AMOUNT: u64 = 408;

    struct Reserve has store {
        asset: String,
        total_cash: u64,
        total_borrows: u64,
        total_reserves: u64,
        borrow_index: u64,
        last_accrual_timestamp: u64,
        ltv_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        interest_model: JumpRateModel,
    }

    struct LendingProtocol has key {
        reserves: Table<String, Reserve>,
        deposit_events: EventHandle<DepositEvent>,
        borrow_events: EventHandle<BorrowEvent>,
        liquidation_events: EventHandle<LiquidationEvent>,
    }

    struct UserAccount has key {
        collaterals: Table<String, u64>,
        borrows: Table<String, u64>,
    }

    // Events
    struct DepositEvent has drop, store {
        user: address,
        asset: String,
        amount: u64,
    }

    struct BorrowEvent has drop, store {
        user: address,
        asset: String,
        amount: u64,
    }

    struct LiquidationEvent has drop, store {
        liquidator: address,
        borrower: address,
        debt_asset: String,
        collateral_asset: String,
        repaid_amount: u64,
        seized_amount: u64,
    }

    public fun initialize_protocol(admin: &signer) {
        let protocol = LendingProtocol {
            reserves: table::new(),
            deposit_events: account::new_event_handle<DepositEvent>(admin),
            borrow_events: account::new_event_handle<BorrowEvent>(admin),
            liquidation_events: account::new_event_handle<LiquidationEvent>(admin),
        };
        move_to(admin, protocol);
    }

    public fun create_reserve(
        admin: &signer,
        asset: String,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_bonus_bps: u64,
        model: JumpRateModel,
        current_time: u64,
    ) acquires LendingProtocol {
        assert!(signer::address_of(admin) == @zephyr_lend, ERR_UNAUTHORIZED);
        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(!table::contains(&protocol.reserves, asset), ERR_RESERVE_EXISTS);

        let reserve = Reserve {
            asset,
            total_cash: 0,
            total_borrows: 0,
            total_reserves: 0,
            borrow_index: fixed_point::wad(),
            last_accrual_timestamp: current_time,
            ltv_bps,
            liquidation_threshold_bps: liq_threshold_bps,
            liquidation_bonus_bps: liq_bonus_bps,
            interest_model: model,
        };
        table::add(&mut protocol.reserves, asset, reserve);
    }

    public fun accrue_interest(asset: String, current_time: u64) acquires LendingProtocol {
        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(table::contains(&protocol.reserves, asset), ERR_RESERVE_NOT_FOUND);
        let reserve = table::borrow_mut(&mut protocol.reserves, asset);

        if (current_time <= reserve.last_accrual_timestamp || reserve.total_borrows == 0) {
            reserve.last_accrual_timestamp = current_time;
            return
        };

        let time_delta = current_time - reserve.last_accrual_timestamp;
        let b_rate_year = interest_model::borrow_rate_per_year(
            &reserve.interest_model,
            reserve.total_cash,
            reserve.total_borrows,
            reserve.total_reserves
        );
        let b_rate_sec = interest_model::rate_per_second(b_rate_year);
        let interest_factor = b_rate_sec * time_delta;

        let interest_accrued = fixed_point::wad_mul(reserve.total_borrows, interest_factor);
        reserve.total_borrows = reserve.total_borrows + interest_accrued;

        // Protocol reserve cut
        let reserve_cut = fixed_point::apply_bps(interest_accrued, 1000); // 10% reserve factor
        reserve.total_reserves = reserve.total_reserves + reserve_cut;

        // Update borrow index: index_new = index_old * (1 + interest_factor)
        let index_delta = fixed_point::wad_mul(reserve.borrow_index, interest_factor);
        reserve.borrow_index = reserve.borrow_index + index_delta;
        reserve.last_accrual_timestamp = current_time;
    }

    public fun deposit(account: &signer, asset: String, amount: u64) acquires LendingProtocol, UserAccount {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let user_addr = signer::address_of(account);

        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(table::contains(&protocol.reserves, asset), ERR_RESERVE_NOT_FOUND);
        let reserve = table::borrow_mut(&mut protocol.reserves, asset);

        reserve.total_cash = reserve.total_cash + amount;

        if (!exists<UserAccount>(user_addr)) {
            let user_acct = UserAccount {
                collaterals: table::new(),
                borrows: table::new(),
            };
            move_to(account, user_acct);
        };

        let user_acct = borrow_global_mut<UserAccount>(user_addr);
        if (table::contains(&user_acct.collaterals, asset)) {
            let bal = table::borrow_mut(&mut user_acct.collaterals, asset);
            *bal = *bal + amount;
        } else {
            table::add(&mut user_acct.collaterals, asset, amount);
        };

        event::emit_event(&mut protocol.deposit_events, DepositEvent {
            user: user_addr,
            asset,
            amount,
        });
    }

    public fun borrow(account: &signer, asset: String, amount: u64) acquires LendingProtocol, UserAccount {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let user_addr = signer::address_of(account);

        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(table::contains(&protocol.reserves, asset), ERR_RESERVE_NOT_FOUND);
        let reserve = table::borrow_mut(&mut protocol.reserves, asset);

        assert!(reserve.total_cash >= amount, ERR_INSUFFICIENT_LIQUIDITY);
        reserve.total_cash = reserve.total_cash - amount;
        reserve.total_borrows = reserve.total_borrows + amount;

        let user_acct = borrow_global_mut<UserAccount>(user_addr);
        if (table::contains(&user_acct.borrows, asset)) {
            let b = table::borrow_mut(&mut user_acct.borrows, asset);
            *b = *b + amount;
        } else {
            table::add(&mut user_acct.borrows, asset, amount);
        };

        event::emit_event(&mut protocol.borrow_events, BorrowEvent {
            user: user_addr,
            asset,
            amount,
        });
    }

    public fun repay(account: &signer, asset: String, amount: u64) acquires LendingProtocol, UserAccount {
        assert!(amount > 0, ERR_ZERO_AMOUNT);
        let user_addr = signer::address_of(account);

        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(table::contains(&protocol.reserves, asset), ERR_RESERVE_NOT_FOUND);
        let reserve = table::borrow_mut(&mut protocol.reserves, asset);

        let user_acct = borrow_global_mut<UserAccount>(user_addr);
        assert!(table::contains(&user_acct.borrows, asset), ERR_ZERO_AMOUNT);
        let borrowed = table::borrow_mut(&mut user_acct.borrows, asset);

        let repay_amt = fixed_point::min(amount, *borrowed);
        *borrowed = *borrowed - repay_amt;
        reserve.total_cash = reserve.total_cash + repay_amt;
        reserve.total_borrows = reserve.total_borrows - repay_amt;
    }

    public fun liquidate(
        liquidator: &signer,
        borrower: address,
        debt_asset: String,
        collateral_asset: String,
        repay_amount: u64,
        debt_price_usd: u64,
        collat_price_usd: u64,
    ) acquires LendingProtocol, UserAccount {
        assert!(repay_amount > 0, ERR_ZERO_AMOUNT);
        let liquidator_addr = signer::address_of(liquidator);

        let protocol = borrow_global_mut<LendingProtocol>(@zephyr_lend);
        assert!(table::contains(&protocol.reserves, debt_asset), ERR_RESERVE_NOT_FOUND);
        assert!(table::contains(&protocol.reserves, collateral_asset), ERR_RESERVE_NOT_FOUND);

        let borrower_acct = borrow_global_mut<UserAccount>(borrower);
        assert!(table::contains(&borrower_acct.borrows, debt_asset), ERR_BORROWER_HEALTHY);
        let debt_ref = table::borrow_mut(&mut borrower_acct.borrows, debt_asset);

        let actual_repay = fixed_point::min(repay_amount, *debt_ref);
        *debt_ref = *debt_ref - actual_repay;

        // Calculate seized collateral with 5% liquidation bonus:
        // seized_usd = actual_repay_usd * 1.05
        let debt_value_usd = fixed_point::wad_mul(actual_repay, debt_price_usd);
        let bonus_usd = fixed_point::apply_bps(debt_value_usd, 500); // 5% bonus
        let total_seized_usd = debt_value_usd + bonus_usd;
        let seized_collat_amount = fixed_point::wad_div(total_seized_usd, collat_price_usd);

        let collat_ref = table::borrow_mut(&mut borrower_acct.collaterals, collateral_asset);
        assert!(*collat_ref >= seized_collat_amount, ERR_INSUFFICIENT_COLLATERAL);
        *collat_ref = *collat_ref - seized_collat_amount;

        // Credit liquidator collateral
        if (!exists<UserAccount>(liquidator_addr)) {
            let acct = UserAccount {
                collaterals: table::new(),
                borrows: table::new(),
            };
            move_to(liquidator, acct);
        };
        let liq_acct = borrow_global_mut<UserAccount>(liquidator_addr);
        if (table::contains(&liq_acct.collaterals, collateral_asset)) {
            let bal = table::borrow_mut(&mut liq_acct.collaterals, collateral_asset);
            *bal = *bal + seized_collat_amount;
        } else {
            table::add(&mut liq_acct.collaterals, collateral_asset, seized_collat_amount);
        };

        // Update pool reserves
        let debt_reserve = table::borrow_mut(&mut protocol.reserves, debt_asset);
        debt_reserve.total_cash = debt_reserve.total_cash + actual_repay;
        debt_reserve.total_borrows = debt_reserve.total_borrows - actual_repay;

        event::emit_event(&mut protocol.liquidation_events, LiquidationEvent {
            liquidator: liquidator_addr,
            borrower,
            debt_asset,
            collateral_asset,
            repaid_amount: actual_repay,
            seized_amount: seized_collat_amount,
        });
    }

    public fun get_reserve_cash(asset: String): u64 acquires LendingProtocol {
        let protocol = borrow_global<LendingProtocol>(@zephyr_lend);
        let reserve = table::borrow(&protocol.reserves, asset);
        reserve.total_cash
    }

    public fun get_reserve_borrows(asset: String): u64 acquires LendingProtocol {
        let protocol = borrow_global<LendingProtocol>(@zephyr_lend);
        let reserve = table::borrow(&protocol.reserves, asset);
        reserve.total_borrows
    }

    public fun get_user_collateral(user: address, asset: String): u64 acquires UserAccount {
        if (!exists<UserAccount>(user)) { return 0 };
        let acct = borrow_global<UserAccount>(user);
        if (!table::contains(&acct.collaterals, asset)) { return 0 };
        *table::borrow(&acct.collaterals, asset)
    }

    public fun get_user_borrow(user: address, asset: String): u64 acquires UserAccount {
        if (!exists<UserAccount>(user)) { return 0 };
        let acct = borrow_global<UserAccount>(user);
        if (!table::contains(&acct.borrows, asset)) { return 0 };
        *table::borrow(&acct.borrows, asset)
    }
}
