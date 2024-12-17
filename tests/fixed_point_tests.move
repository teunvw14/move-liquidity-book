#[test_only]
module iota_rebased_l1dex::fixed_point_128_tests {
    use iota_rebased_l1dex::fixed_point_128::{Self, UFP128};

    const MAX_U64: u64 = 18446744073709551615; // 2^64 - 1
    const DECIMAL_FACTOR: u128 = 18446744073709551616; // 2^64

    #[test]
    fun test_from_fraction() {
        // 3/2 = (1, 2^63)
        assert!(fixed_point_128::from_fraction(3, 2) == fixed_point_128::new(1, 2u64.pow(63)));
        
        // 1/10 = (0, DECIMAL_FACTOR / 10)
        assert!(fixed_point_128::from_fraction(1, 10) == fixed_point_128::new(0, (DECIMAL_FACTOR / 10) as u64));
        
        // 7/4 = (1, 2^63 + 2^62)
        assert!(fixed_point_128::from_fraction(7, 4) == fixed_point_128::new(1, 2u64.pow(63) + 2u64.pow(62)));

        // 2/3 = (0, 2 * DECIMAL_FACTOR / 3)
        assert!(fixed_point_128::from_fraction(2, 3) == fixed_point_128::new(0,  (2 * DECIMAL_FACTOR / 3) as u64));

        // 9/8 = 1.125 (1, 2^63 + 2^62)
        assert!(fixed_point_128::from_fraction(9, 8) == fixed_point_128::new(1, 2u64.pow(61)));
    }

    #[test_only]
    fun test_mul_single(
        first: UFP128,
        second: UFP128,
        expected_result: UFP128
    ) {
        assert!(first.mul(second).eq(expected_result));
    }

    #[test]
    fun test_mul() {
        // 2 * 3 = 6
        test_mul_single(
            fixed_point_128::new(2, 0),
            fixed_point_128::new(3, 0),
            fixed_point_128::new(6, 0)
        );

        // 1/2 * 6 = 3
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(6, 0),
            fixed_point_128::new(3, 0)
        );

        // 1/2 * 1/4 = 1/8
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(0, 2u64.pow(61))
        );

        // 3/4 * 12 = 9
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63) + 2u64.pow(62)),
            fixed_point_128::new(12, 0),
            fixed_point_128::new(9, 0)
        );

        // 2 * 1/2 = 1
        test_mul_single(
            fixed_point_128::new(2, 0),
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(1, 0)
        );

        // 1/8 * 16 = 2
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(61)),
            fixed_point_128::new(16, 0),
            fixed_point_128::new(2, 0)
        );

        // 1/3 * 3 = 1
        test_mul_single(
            fixed_point_128::new(0, (MAX_U64 / 3)),  // Approximation of 1/3
            fixed_point_128::new(3, 0),
            fixed_point_128::new(0, MAX_U64)
        );

        // 5/8 * 16/5 = 2
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63) + 2u64.pow(61)),
            fixed_point_128::new(3,  (MAX_U64 / 5)),
            fixed_point_128::new(1, MAX_U64)
        );

        // 0 * 1/4 = 0
        test_mul_single(
            fixed_point_128::new(0, 0),
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(0, 0)
        );

        // 1/4 * 1/4 = 1/16
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(0, 2u64.pow(60))
        );

        // 1_000_000 * 1/2 = 500_000
        test_mul_single(
            fixed_point_128::new(1_000_000, 0),
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(500_000, 0)
        );

        // (1/2) * (1/8) = 1/16
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(0, 2u64.pow(60)),
            fixed_point_128::new(0, 2u64.pow(59))
        );

        // 3/4 * 5/8 = 15/32
        test_mul_single(
            fixed_point_128::new(0, 2u64.pow(63) + 2u64.pow(62)),
            fixed_point_128::new(0, 2u64.pow(63) + 2u64.pow(61)),
            fixed_point_128::new(0, 2u64.pow(62) + 2u64.pow(61) + 2u64.pow(60) + 2u64.pow(59))
        );

        // 7 * 1/8 = 7/8
        test_mul_single(
            fixed_point_128::new(7, 0),
            fixed_point_128::new(0, 2u64.pow(60)),
            fixed_point_128::new(0, 7 * 2u64.pow(60))
        );

    }

    #[test_only]
    fun test_add_single(
        first: UFP128,
        second: UFP128,
        expected_result: UFP128
    ) {
        assert!(first.add(second) == expected_result);
    }

    #[test]
    fun test_add() {
        // 1 + 1 = 2
        test_add_single(
            fixed_point_128::new(1, 0),
            fixed_point_128::new(1, 0),
            fixed_point_128::new(2, 0)
        );
        
        // 0.5 + 0.25 = 0.75
        test_add_single(
            fixed_point_128::new(0, 2u64.pow(63)),
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(0, 2u64.pow(63) + 2u64.pow(62))
        );

        // 1.5 + 3.75 = 5.25
        test_add_single(
            fixed_point_128::new(1, 2u64.pow(63)),
            fixed_point_128::new(3, 2u64.pow(63) + 2u64.pow(62)),
            fixed_point_128::new(5, 2u64.pow(62))
        );

        // 0.25 + 9.75 = 10
        test_add_single(
            fixed_point_128::new(0, 2u64.pow(62)),
            fixed_point_128::new(9, 2u64.pow(63) + 2u64.pow(62)),
            fixed_point_128::new(10, 0)
        );
    }

    #[test_only]
    fun test_diff_single(
        first: UFP128,
        second: UFP128,
        expected_result: UFP128
    ) {
        assert!(first.diff(second).eq(expected_result));
    }

    #[test]
    fun test_diff() {
       // diff(5, 3) = 2
        test_diff_single(
            fixed_point_128::new(5, 0),
            fixed_point_128::new(3, 0),
            fixed_point_128::new(2, 0)
        );

        // diff(4.5, 3.25) = 1.25
        test_diff_single(
            fixed_point_128::new(4, 2u64.pow(63)),
            fixed_point_128::new(3, 2u64.pow(62)),
            fixed_point_128::new(1, 2u64.pow(62))
        );

        // diff(3.0, 2.5) = 0.5
        test_diff_single(
            fixed_point_128::new(3, 0),
            fixed_point_128::new(2, 2u64.pow(63)),
            fixed_point_128::new(0, 2u64.pow(63))
        );

        // diff(6.75, 6.75) = 0
        test_diff_single(
            fixed_point_128::new(6, 2u64.pow(62) + 2u64.pow(61)),
            fixed_point_128::new(6, 2u64.pow(62) + 2u64.pow(61)),
            fixed_point_128::new(0, 0)
        );

        // diff(MAX_U64, MAX_U64 / 2) = MAX_U64 / 2
        test_diff_single(
            fixed_point_128::new(MAX_U64, 0),
            fixed_point_128::new(MAX_U64 / 2, 0),
            fixed_point_128::new(MAX_U64 - MAX_U64 / 2, 0)
        );

        // diff((MAX_U64, 2^63), (MAX_U64 / 2, 2^62)) = (MAX_U64 / 2, 2^62)
        test_diff_single(
            fixed_point_128::new(MAX_U64, 2u64.pow(63)),
            fixed_point_128::new(MAX_U64 / 2, 2u64.pow(62)),
            fixed_point_128::new(MAX_U64 - MAX_U64 / 2, 2u64.pow(62))
        );
    }

    #[test_only]
    fun test_pow_single(
        n: UFP128,
        power: u64,
        expected_result: UFP128
    ) {
        assert!(n.pow(power).eq(expected_result));
    }

    #[test]
    fun test_pow() {
        // 2 ^ 2 = 4
        test_pow_single(
            fixed_point_128::new(2, 0),
            2,
            fixed_point_128::new(4, 0)
        );

        // 3 ^ 3 = 27
        test_pow_single(
            fixed_point_128::new(3, 0),
            3,
            fixed_point_128::new(27, 0)
        );

        // (1/2) ^ 3 = 1/8
        test_pow_single(
            fixed_point_128::new(0, 2u64.pow(63)),
            3,
            fixed_point_128::new(0, 2u64.pow(61))
        );

        // 1.5 ^ 2 = 2.25 (2, 2^62)
        test_pow_single(
            fixed_point_128::new(1, 2u64.pow(63)),
            2,
            fixed_point_128::new(2, 2u64.pow(62))
        );

        // MAX_U64 ^ 1 = MAX_U64
        test_pow_single(
            fixed_point_128::new(MAX_U64, 0),
            1,
            fixed_point_128::new(MAX_U64, 0)
        );
    }

    #[test_only]
    fun test_div_single(
        n: UFP128,
        other: UFP128,
        expected_result: UFP128
    ) {
        assert!(n.div(other) == expected_result);
    }

    #[test]
    fun test_div() {
        // 1/2 = 1/2
        test_div_single(
            fixed_point_128::new(1, 0),
            fixed_point_128::new(2, 0),
            fixed_point_128::new(0, 2u64.pow(63))
        );

        // 10 / 10 = 1
        test_div_single(
            fixed_point_128::new(10, 0),
            fixed_point_128::new(10, 0),
            fixed_point_128::new(1, 0)
        );        

        // MAX_U64 / 5 = MAX_U64 / 5
        test_div_single(
            fixed_point_128::new(MAX_U64, 0),
            fixed_point_128::new(5, 0),
            fixed_point_128::new(3689348814741910323, 0)
        );

        // 3 / 2 = 1.5
        test_div_single(
            fixed_point_128::new(3, 0),
            fixed_point_128::new(2, 0),
            fixed_point_128::new(1, 2u64.pow(63))
        );

        // 7.5 / 2.5 = 3
        test_div_single(
            fixed_point_128::new(7, 2u64.pow(63)),
            fixed_point_128::new(2, 2u64.pow(63)),
            fixed_point_128::new(3, 0)
        );

        // 1 / 3 = 2^-64 * DECIMAL_FACTOR / 3
        test_div_single(
            fixed_point_128::new(1, 0),
            fixed_point_128::new(3, 0),
            fixed_point_128::new(0, (DECIMAL_FACTOR / 3) as u64)
        );
    }

    #[test_only]
    fun test_pow_neg_single(
        n: UFP128,
        power: u64,
        expected_result: UFP128
    ) {
        assert!(n.pow_neg(power) == expected_result);
    }

    #[test]
    fun test_pow_neg() {
        // 5^-0 = 1
        test_pow_neg_single(
            fixed_point_128::new(5, 0),
            0,
            fixed_point_128::new(1, 0)
        );

        // 4^-1 = 1/4
        test_pow_neg_single(
            fixed_point_128::new(4, 0),
            1,
            fixed_point_128::new(0, 2u64.pow(62))
        );

        // 2^-64 = 2^-64
        test_pow_neg_single(
            fixed_point_128::new(2, 0),
            64,
            fixed_point_128::new(0, 1)
        );
    }
}
