/// Module: fixed_point_128
module iota_rebased_l1dex::fixed_point_128 {

    const MAX_U64: u64 = 18446744073709551615; // 2^64 - 1
    const DECIMAL_FACTOR: u128 = 18446744073709551616; // 2^64

    // A 128-bit unsigned fixed point number for high-precision calculations.
    public struct UFP128 has store, copy, drop {
        units: u64,
        decimals: u64 // the decimals scaled by 2^64 = DECIMAL_FACTOR
    }

    // Create a new 128-bit unsigned fixed point integer (type UFP128)
    public fun new(units: u64, decimals: u64): UFP128 {
        UFP128 {
            units,
            decimals
        }
    }

    public fun zero(): UFP128 {
        UFP128 {
            units: 0,
            decimals: 0
        }
    }

    // Create a fixed point number from a fraction. Mostly used for testing and
    // calculating bin pricing 
    public fun from_fraction(numerator: u64, denominator: u64) : UFP128 {
        assert!(denominator != 0);

        let units = numerator / denominator;
        let numerator_fractional = numerator - (units * denominator);
        let decimals = ((numerator_fractional as u128) * DECIMAL_FACTOR / (denominator as u128)) as u64;
        UFP128 {
            units,
            decimals
        }
    }

    // Get the units
    public fun units(n: &UFP128): u64 {
        n.units
    }

    // Get the decimals
    public fun decimals(n: &UFP128): u64 {
        n.decimals
    }

    // Find `n * m` where `m` is a u64
    public fun mul_u64(n: &UFP128, m: u64): u64 {
        let result = new(m, 0).mul(*n);

        result.units
    }

    // TODO: figure out if this works as intended?
    // Find `left` where: `left = n / right`. That is, get the amount of 
    // `left` corresponding to the given amount of `right`.
    public fun div_u64(n: &UFP128, right: u64): u64 {
        let right_scaled = (right as u128) * DECIMAL_FACTOR;
        let n_scaled = (n.units as u128) * DECIMAL_FACTOR + (n.decimals as u128);
        let result_scaled = right_scaled / n_scaled;
        
        let result = result_scaled / DECIMAL_FACTOR;

        // Make sure the cast is safe
        assert!(result <= MAX_U64 as u128);

        result as u64
    }

    // Get max(first, second), i.e. the largest of `first` and `second`
    public fun max(first: UFP128, second: UFP128): UFP128 {
        if (first.units == second.units) {
            if (first.decimals >= second.decimals) {
                return first
            } else {
                return second
            }
        }
        else if (first.units > second.units) {
            return first
        } else {
            return second
        }
    }

    // Get min(first, second), i.e. the smallest of `first` and `second`
    public fun min(first: UFP128, second: UFP128): UFP128 {
        if (first.units == second.units) {
            if (first.decimals >= second.decimals) {
                return second
            } else {
                return first
            }
        }
        else if (first.units > second.units) {
            return second
        } else {
            return first
        }
    }

    // Will return true if the difference between two UFP128s is either
    // zero, or the  smallest distance possible between two UFP128s
    public fun eq(n: &UFP128, other: UFP128): bool {
        let delta = n.diff(other);
        if (delta.units == 0 && delta.decimals <= 1) {
            return true
        } else {
            return false
        }
    }

    // Calculate sums: `n.add(other) = n + other`
    public fun add(n: &UFP128, other: UFP128): UFP128 {
        let decimals_u128 = (n.decimals as u128) + (other.decimals as u128);
        let units_in_decimals = (decimals_u128 / DECIMAL_FACTOR);

        let units = n.units + other.units + (units_in_decimals as u64);
        let decimals = (decimals_u128 - (units_in_decimals * DECIMAL_FACTOR)) as u64;

        return UFP128 {
            units,
            decimals
        }
    }

    // Calculate absolute differences: `n.diff(n, other) = abs(n - other)`
    public fun diff(n: &UFP128, other: UFP128): UFP128 {
        let min = min(*n, other);
        let max = max(*n, other);
        let mut units = max.units - min.units;
        let decimals;
        if (min.decimals > max.decimals) {
            decimals = MAX_U64 - (min.decimals - max.decimals);
            units = units - 1;
        } else {
            decimals = max.decimals - min.decimals;
        };
        UFP128 {
            units,
            decimals
        }
    }

    // Calculate products: `n.mul(other) = n * other`
    public fun mul(n: &UFP128, other: UFP128): UFP128 {
        let mut units = n.units * other.units;
        let decimals_u128 = 
            ((n.units as u128) * (other.decimals as u128))
          + ((other.units as u128) * (n.decimals as u128))
          + ((n.decimals as u128) * (other.decimals as u128) / DECIMAL_FACTOR);
        // "Clean up" decimals, since it might contains units.
        let units_in_decimals = decimals_u128 / DECIMAL_FACTOR;
        units = units + (units_in_decimals as u64);
        // Cast to u64 to get rid of units
        let decimals = (decimals_u128 - (units_in_decimals * DECIMAL_FACTOR)) as u64;

        UFP128 {
            units,
            decimals
        }
    }

    // Calculate powers of n: `n.pow(p) = n^p`
    public fun pow(n: &UFP128, p: u64): UFP128 {
        let base = *n;
        let mut result = new(1, 0);
        p.do!(|_| result = result.mul(base));
        result
    }

    // Calculate quotients: `n.div(other) = n / other`
    public fun div(n: &UFP128, other: UFP128): UFP128 {
        let n_scaled = (n.units as u128) * 2u128.pow(64) + (n.decimals as u128);
        let other_scaled = (other.units as u128) * 2u128.pow(64) + (other.decimals as u128);
        
        // Get units using floor division 
        let units = (n_scaled / other_scaled) as u64;
        
        // Calculate the decimals
        let mut decimals = 0;
        let mut rest = n_scaled - ((units as u128) * other_scaled);
        let mut pow = 1;
        while (pow <= 64 && rest > 0) {
            if (other_scaled / 2u128.pow(pow) <= rest) {
                decimals = decimals + 2u64.pow(64-pow);
                rest = rest - other_scaled / 2u128.pow(pow);
            };
            pow = pow + 1;
        };

        UFP128 {
            units,
            decimals
        }
    }

    // Calculate negative powers: `n.pow_neg(p) = n^-p`
    public fun pow_neg(n: &UFP128, p: u64): UFP128 {
        let base = *n;
        let mut result = new(1, 0);
        p.do!(|_| result = result.div(base));
        result
    }
}