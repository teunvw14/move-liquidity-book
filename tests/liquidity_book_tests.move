// Copyright (c) 2025 Teun van Wezel
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module liquidity_book::liquidity_book_tests {

use iota::test_scenario as ts;
use iota::coin::{Self, Coin};
use iota::test_utils::assert_eq;
use iota::clock::{Self, Clock};

use liquidity_book::liquidity_book::{Self, Pool, LiquidityProviderReceipt};
use liquidity_book::ufp256::{Self};

public struct LEFT has drop {}
public struct RIGHT has drop {}

const DEFAULT_BIN_STEP: u64 = 20;
const DEFAULT_PRICE_MANTISSA: u256 = 5000000000000000000; // 0.5
const ONE_BPS: u64 = 10000;


/// Apply fee of `fee_bps` basis points.
#[test_only]
fun apply_fee(amount: u64, fee_bps: u64): u64 {
    let fee_factor = ufp256::from_fraction(fee_bps as u256, ONE_BPS as u256);
    amount - fee_factor.mul_u64(amount)
}

/// Apply fee of `fee_bps` basis points, but on the output of a trade: amount/(1-fee).
#[test_only]
fun apply_fee_inv(amount: u64, fee_bps: u64): u64 {
    ufp256::from_fraction((ONE_BPS - fee_bps) as u256, ONE_BPS as u256)
    .div_u64(amount)
}

/// Start the default scenario, creating a pool with default parameters.
#[test_only]
fun scenario_default_pool(): ts::Scenario {
    let placeholder_addr = @0xABCDEF;
    let mut ts = ts::begin(placeholder_addr);
    liquidity_book::new<LEFT, RIGHT>(
        DEFAULT_BIN_STEP,
        DEFAULT_PRICE_MANTISSA,
        // DEFAULT_FEE_BPS,
        ts.ctx()
    );
    ts
}

/// Start the default scenario, creating a pool with default parameters, and
/// adding liquidity to that pool.
#[test_only]
fun scenario_default_pool_with_liquidity(sender: address, bin_count: u64, left_amount: u64, right_amount: u64): (ts::Scenario, Clock) {
    let mut ts = scenario_default_pool();
    let clock = clock::create_for_testing(ts.ctx());
    ts.next_tx(sender);
    provide_liquidity(&mut ts, sender, left_amount, right_amount, bin_count, &clock);

    (ts, clock)
}

/// End scenario where a clock was involved.
#[test_only]
fun end_scenario_with_clock(ts: ts::Scenario, clock: Clock) {
    ts.end();
    clock.destroy_for_testing();
}

/// Convenience function for making a left-to-right swap in the most recently
/// created pool.
#[test_only]
fun swap_ltr(ts: &mut ts::Scenario, sender: address, coin_amount: u64, clock: &Clock): Coin<RIGHT> {
    ts.next_tx(sender);

    let coin_left = coin::mint_for_testing<LEFT>(coin_amount, ts.ctx());

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();

    let coin_right = pool.swap_ltr(coin_left, clock, ts.ctx());
    // Complete transaction to see swap effects
    ts::return_shared(pool);
    coin_right
}

/// Convenience function for making a left-to-right swap in the most recently
/// created pool. The resulting coin is immediately transferred to the
/// transaction sender.
#[test_only]
fun swap_ltr_and_transfer(ts: &mut ts::Scenario, sender: address, coin_amount: u64, clock: &Clock) {
    let coin_right = swap_ltr(ts, sender, coin_amount, clock);
    transfer::public_transfer(coin_right, sender);
}

/// Convenience function for making a right-to-left swap in the most recently
/// created pool.
#[test_only]
fun swap_rtl(ts: &mut ts::Scenario, sender: address, coin_amount: u64, clock: &Clock): Coin<LEFT> {
    ts.next_tx(sender);
    let coin_right = coin::mint_for_testing<RIGHT>(coin_amount, ts.ctx());

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();

    let coin_left = pool.swap_rtl(coin_right, clock, ts.ctx());

    ts::return_shared(pool);
    coin_left
}

/// Convenience function for making a right-to-left swap in the most recently
/// created pool. The resulting coin is immediately transferred to the
/// transaction sender.
#[test_only]
fun swap_rtl_and_transfer(ts: &mut ts::Scenario, sender: address, coin_amount: u64, clock: &Clock) {
    let coin_left = swap_rtl(ts, sender, coin_amount, clock);
    transfer::public_transfer(coin_left, sender);
}

/// Convenience function for providing liquidity in the most recently created
/// pool.
#[test_only]
fun provide_liquidity(ts: &mut ts::Scenario, sender: address, left_amount: u64, right_amount: u64, bin_count: u64, clock: &Clock) {
    ts.next_tx(sender);

    let coin_left = coin::mint_for_testing<LEFT>(left_amount, ts.ctx());
    let coin_right = coin::mint_for_testing<RIGHT>(right_amount, ts.ctx());

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();

    pool.provide_liquidity_uniformly(bin_count, coin_left, coin_right, clock, ts.ctx());

    ts::return_shared(pool);
}

/// Convenience function for withdrawing liquidity from the most recently
/// created pool.
#[test_only]
fun withdraw_liquidity(ts: &mut ts::Scenario, sender: address): (Coin<LEFT>, Coin<RIGHT>) {
    ts.next_tx(sender);

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();
    let receipt = ts.take_from_address<LiquidityProviderReceipt>(sender);

    pool.withdraw_liquidity(receipt, ts.ctx());

    // Next transaction so that the withdrawal takes effect
    ts.next_tx(sender);
    let coin_left = ts.take_from_address<Coin<LEFT>>(sender);
    let coin_right = ts.take_from_address<Coin<RIGHT>>(sender);

    ts::return_shared(pool);
    (coin_left, coin_right)
}

/// Convenience function for withdrawing liquidity from the most recently
/// created pool and checking the values of the paid out coins.
#[test_only]
fun withdraw_and_check_coin_values(ts: &mut ts::Scenario, sender: address, expected_left_value: u64, expected_right_value: u64) {
    ts.next_tx(sender);

    let (coin_left, coin_right) = withdraw_liquidity(ts, sender);
    assert_eq(coin_left.value(), expected_left_value);
    assert_eq(coin_right.value(), expected_right_value);

    ts::return_to_address(sender, coin_left);
    ts::return_to_address(sender, coin_right);
}


#[test]
fun provide_liquidity_and_withdraw_single() {
    let mut ts = scenario_default_pool();
    let lp_addr = @0xA;

    let left_amount = 10 * 10u64.pow(9);
    let right_amount = 10 * 10u64.pow(9);
    let bin_count = 11; // Doesn't really matter here

    let clock = clock::create_for_testing(ts.ctx());

    // Provide liquidity and immediately withdraw
    provide_liquidity(&mut ts, lp_addr, left_amount, right_amount, bin_count, &clock);
    withdraw_and_check_coin_values(&mut ts, lp_addr, left_amount, right_amount);

    end_scenario_with_clock(ts, clock);
}

/// Test if multiple liquidity providers can provide liquidity and then get all
/// their tokens back by withdrawing.
#[test]
fun provide_liquidity_and_withdraw_plural() {
    let mut ts = scenario_default_pool();
    let clock = clock::create_for_testing(ts.ctx());

    // Define parameters
    let bin_count = 11; // Doesn't really matter
    let lp_addrs = vector[@0xA, @0xB, @0xC, @0xD, @0xE];
    let left_amounts = vector[2, 4, 6, 8, 10];
    let right_amounts = vector[1, 3, 5, 7, 9];

    // First provide all liquidity
    let mut i = 0;
    lp_addrs.do!(|lp_addr|{
        provide_liquidity(&mut ts, lp_addr, left_amounts[i], right_amounts[i], bin_count, &clock);
        i = i + 1;
    });

    // Then withdraw one by one
    let mut i = 0;
    lp_addrs.do!(|lp_addr|{
        withdraw_and_check_coin_values(&mut ts, lp_addr, left_amounts[i], right_amounts[i]);
        i = i + 1;
    });

    clock.destroy_for_testing();

    ts.end();
}

/// Test swaps by doing two swaps, one left-to-right, one right-to left,
/// without crossing over any bins, checking that the received amounts are
/// correct.
// #[test]
// fun swap_single_bin() {
//     let admin_addr = @0xAAAA;
//     let mut ts = ts::begin(admin_addr);

//     // Initialize pool with 10bln LEFT and 10bln RIGHT tokens, all inside 1 bin
//     let bln_10 = 10 * 10u64.pow(9);
//     liquidity_book::new<LEFT, RIGHT>(
//         DEFAULT_BIN_STEP,
//         DEFAULT_PRICE_MANTISSA,
//         ts.ctx()
//     );

//     // Now swap
//     let trader_addr = @0xBBBB;
//     ts.next_tx(trader_addr);

//     // Perform swaps
//     let trade_left = 1 * 10u64.pow(9);
//     let trade_right = 1 * 10u64.pow(9);

//     let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();

//     let coin_left_in = coin::mint_for_testing<LEFT>(trade_left, ts.ctx());
//     let coin_right_in = coin::mint_for_testing<RIGHT>(trade_right, ts.ctx());

//     let coin_right_result = pool.swap_ltr(coin_left_in, ts.ctx());
//     let coin_left_result = pool.swap_rtl(coin_right_in, ts.ctx());

//     // Check swap results
//     let price = ufp256::new(DEFAULT_PRICE_MANTISSA);

//     let expected_value_right = price.mul_u64(trade_left);
//     assert_eq(coin_right_result.value(), expected_value_right);

//     let expected_value_left = price.div_u64(trade_right);
//     assert_eq(coin_left_result.value(), expected_value_left);

//     // Return coins to owner
//     transfer::public_transfer(coin_right_result, trader_addr);
//     transfer::public_transfer(coin_left_result, trader_addr);

//     ts::return_shared(pool);
//     ts.end();
// }

/// Test swaps by doing a swap crossing over one bin, checking that the received
/// amount is correct.
// #[test]
// fun swap_multiple_bins() {
//     let admin_addr = @0xAAAA;
//     let mut ts = ts::begin(admin_addr);

//     // Initialize pool with 2bln LEFT and/or RIGHT per bin.
//     let bin_count = 3;
//     let left_amount_per_bin = 2 * 10u64.pow(9);
//     let right_amount_per_bin = 2 * 10u64.pow(9);
//     let left_amount = left_amount_per_bin * ((bin_count + 1) / 2);
//     let right_amount = right_amount_per_bin * ((bin_count + 1) / 2);
//     liquidity_book::new<LEFT, RIGHT>(
//         DEFAULT_BIN_STEP,
//         DEFAULT_PRICE_MANTISSA,
//         ts.ctx()
//     );

//     // We will trade 6 LEFT for ~3 RIGHT
//     let trade_amount_left = 6 * 10u64.pow(9);

//     // Calculate expected swap results (left-to-right)
//     let first_bin_price = ufp256::new(DEFAULT_PRICE_MANTISSA);
//     let second_bin_price = first_bin_price.mul(ufp256::from_fraction((ONE_BPS+DEFAULT_BIN_STEP) as u256, ONE_BPS as u256));

//     let right_from_first_bin = right_amount_per_bin;
//     let left_traded_in_first_bin = first_bin_price.div_u64(right_amount_per_bin);
//     let left_remaining = trade_amount_left - left_traded_in_first_bin;
//     let right_from_second_bin = second_bin_price.mul_u64(left_remaining);
//     let expected_value_right = right_from_first_bin + right_from_second_bin;

//     // Perform swaps
//     let trader_addr = @0xABAB;
//     ts.next_tx(trader_addr);
//     let coin_left = coin::mint_for_testing<LEFT>(trade_amount_left, ts.ctx());

//     let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();
//     let coin_right = pool.swap_ltr(coin_left, ts.ctx());

//     // Assert that we received the expected amount of RIGHT tokens
//     assert_eq(coin_right.value(), expected_value_right);

//     // Return coins to owner
//     transfer::public_transfer(coin_right, trader_addr);

//     ts::return_shared(pool);
//     ts.end();
// }

}
