module zephyr_lend::fixed_point {
    const WAD: u128 = 1000000000; // 1e9 fixed-point precision
    const HALF_WAD: u128 = 500000000;

    const ERR_DIV_BY_ZERO: u64 = 101;
    const ERR_OVERFLOW: u64 = 102;

    public fun wad(): u64 {
        (WAD as u64)
    }

    /// Multiply two WAD numbers: (a * b + HALF_WAD) / WAD
    public fun wad_mul(a: u64, b: u64): u64 {
        let prod = (a as u128) * (b as u128);
        let result = (prod + HALF_WAD) / WAD;
        (result as u64)
    }

    /// Divide two WAD numbers: (a * WAD + b / 2) / b
    public fun wad_div(a: u64, b: u64): u64 {
        assert!(b > 0, ERR_DIV_BY_ZERO);
        let numer = (a as u128) * WAD + ((b as u128) / 2);
        let result = numer / (b as u128);
        (result as u64)
    }

    /// Calculate percentage: (val * bps) / 10000
    public fun apply_bps(val: u64, bps: u64): u64 {
        let res = ((val as u128) * (bps as u128)) / 10000;
        (res as u64)
    }

    public fun min(a: u64, b: u64): u64 {
        if (a < b) { a } else { b }
    }

    public fun max(a: u64, b: u64): u64 {
        if (a > b) { a } else { b }
    }
}
