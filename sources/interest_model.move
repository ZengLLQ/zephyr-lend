module zephyr_lend::interest_model {
    use zephyr_lend::fixed_point;

    const SECONDS_PER_YEAR: u64 = 31536000;

    struct JumpRateModel has copy, drop, store {
        base_rate_per_year: u64,
        multiplier_per_year: u64,
        jump_multiplier_per_year: u64,
        kink: u64,
        reserve_factor_bps: u64,
    }

    public fun new_model(
        base_rate: u64,
        multiplier: u64,
        jump_multiplier: u64,
        kink: u64,
        reserve_factor_bps: u64
    ): JumpRateModel {
        JumpRateModel {
            base_rate_per_year: base_rate,
            multiplier_per_year: multiplier,
            jump_multiplier_per_year: jump_multiplier,
            kink,
            reserve_factor_bps,
        }
    }

    /// Compute utilization rate U = borrows / (cash + borrows - reserves) in WAD
    public fun utilization_rate(cash: u64, borrows: u64, reserves: u64): u64 {
        if (borrows == 0) {
            return 0
        };
        let total_assets = cash + borrows;
        if (total_assets <= reserves) {
            return 0
        };
        let net_assets = total_assets - reserves;
        fixed_point::wad_div(borrows, net_assets)
    }

    /// Compute annual borrow rate R_borrow(U) in WAD
    public fun borrow_rate_per_year(model: &JumpRateModel, cash: u64, borrows: u64, reserves: u64): u64 {
        let util = utilization_rate(cash, borrows, reserves);
        let wad = fixed_point::wad();

        if (util <= model.kink) {
            // R = base_rate + (util * multiplier) / kink
            let excess = fixed_point::wad_div(fixed_point::wad_mul(util, model.multiplier_per_year), model.kink);
            model.base_rate_per_year + excess
        } else {
            // Normal rate at kink
            let normal_rate = model.base_rate_per_year + model.multiplier_per_year;
            // Excess utilization beyond kink
            let excess_util = util - model.kink;
            let excess_rate = fixed_point::wad_div(
                fixed_point::wad_mul(excess_util, model.jump_multiplier_per_year),
                wad - model.kink
            );
            normal_rate + excess_rate
        }
    }

    /// Compute annual supply rate: R_supply = U * R_borrow * (1 - reserve_factor)
    public fun supply_rate_per_year(model: &JumpRateModel, cash: u64, borrows: u64, reserves: u64): u64 {
        let util = utilization_rate(cash, borrows, reserves);
        let b_rate = borrow_rate_per_year(model, cash, borrows, reserves);
        let rate_to_suppliers = fixed_point::wad_mul(util, b_rate);
        let reserve_cut = fixed_point::apply_bps(rate_to_suppliers, model.reserve_factor_bps);
        rate_to_suppliers - reserve_cut
    }

    /// Convert annual rate to per-second compounding interest index factor
    public fun rate_per_second(annual_rate: u64): u64 {
        annual_rate / SECONDS_PER_YEAR
    }
}
