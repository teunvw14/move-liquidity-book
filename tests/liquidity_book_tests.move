// Copyright (c) 2025 Teun van Wezel
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module liquidity_book::liquidity_book_tests {

use iota::test_scenario as ts;
use iota::coin::{Self, Coin};
use iota::test_utils::assert_eq;
use iota::clock::{Self, Clock};

use liquidity_book::liquidity_book::{Self, Pool, LiquidityProviderReceipt, get_fee};
use liquidity_book::ufp256::{Self};

public struct LEFT has drop {}
public struct RIGHT has drop {}

const DEFAULT_FEE_BPS: u64 = 20;
const DEFAULT_BIN_STEP: u64 = 20;
const DEFAULT_PRICE_MANTISSA: u256 = 5000000000000000000; // 0.5
const ONE_BPS: u64 = 10000;


// ================
// Helper functions
// ================

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
        DEFAULT_FEE_BPS,
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

// =====
// Tests
// =====

/// Test if a single liquidity providers can provide liquidity and then get all
/// their tokens back by withdrawing.
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

/// Test if fees are properly distributed when there is a single liquidity
/// providers for a pool.
#[test]
fun earn_fees_single_lp() {
    let mut ts = scenario_default_pool();
    let lp_addr = @0xA;
    let trader_addr = @0xB;

    let left_supplied = 300 * 10u64.pow(9);
    let right_supplied = 300 * 10u64.pow(9);
    let bin_count = 3; // Doesn't really matter here

    let clock = clock::create_for_testing(ts.ctx());

    provide_liquidity(&mut ts, lp_addr, left_supplied, right_supplied, bin_count, &clock);

    // Perform swaps
    let trade_left = 1 * 10u64.pow(9);
    let trade_right = ufp256::new(DEFAULT_PRICE_MANTISSA).mul_u64(trade_left);

    let expected_earned_fee_left = get_fee(trade_left, DEFAULT_FEE_BPS);
    let expected_earned_fee_right = get_fee(trade_right, DEFAULT_FEE_BPS);

    swap_ltr_and_transfer(&mut ts, trader_addr, trade_left, &clock);
    swap_rtl_and_transfer(&mut ts, trader_addr, trade_right, &clock);

    // Check that the expected amount of fees are earned
    withdraw_and_check_coin_values(&mut ts, lp_addr, left_supplied + expected_earned_fee_left, right_supplied + expected_earned_fee_right);
    end_scenario_with_clock(ts, clock);
}

/// Test if fees are properly distributed when there are multiple liquidity
/// providers for a pool.
#[test]
fun earn_fees_multi_lp() {
    let mut ts = scenario_default_pool();
    let trader_addr = @0xB;
    let clock = clock::create_for_testing(ts.ctx());

    let lp_addrs = vector[@0xA, @0xB, @0xC, @0xD, @0xE];
    let left_supplied = 100 * 10u64.pow(9);
    let right_supplied = 100 * 10u64.pow(9);

    // First provide all liquidity
    let bin_count = 3; // Doesn't really matter here
    let mut i = 0;
    lp_addrs.do!(|lp_addr|{
        provide_liquidity(&mut ts, lp_addr, left_supplied, right_supplied, bin_count, &clock);
        i = i + 1;
    });

    // Perform swaps
    let trade_left = 1 * 10u64.pow(9);
    let trade_right = ufp256::new(DEFAULT_PRICE_MANTISSA).mul_u64(trade_left);

    // Expected earned fees per liquidity provider
    let expected_earned_fee_left = get_fee(trade_left, DEFAULT_FEE_BPS) / 5;
    let expected_earned_fee_right = get_fee(trade_right, DEFAULT_FEE_BPS) / 5;

    swap_ltr_and_transfer(&mut ts, trader_addr, trade_left, &clock);
    swap_rtl_and_transfer(&mut ts, trader_addr, trade_right, &clock);

    // Check that the expected amount of fees are earned
    // Then withdraw one by one
    let mut i = 0;
    lp_addrs.do!(|lp_addr|{
        withdraw_and_check_coin_values(&mut ts, lp_addr, left_supplied + expected_earned_fee_left, right_supplied + expected_earned_fee_right);
        i = i + 1;
    });

    end_scenario_with_clock(ts, clock);
}

/// Test scenario where only RIGHT liquidity is provided, but payout is purely
/// in LEFT.
#[test]
fun earn_fees_single_lp_impermanent_loss() {
    let mut ts = scenario_default_pool();
    let lp_addr = @0xA;

    let left_supplied = 0;
    let right_supplied = 10 * 10u64.pow(9);
    let bin_count = 1;

    let clock = clock::create_for_testing(ts.ctx());

    provide_liquidity(&mut ts, lp_addr, left_supplied, right_supplied, bin_count, &clock);

    // Perform swaps
    let trader_addr = @0xA;
    let max_trade_no_fees = ufp256::new(DEFAULT_PRICE_MANTISSA).div_u64(right_supplied);
    let max_trade = apply_fee_inv(max_trade_no_fees, DEFAULT_FEE_BPS);
    swap_ltr_and_transfer(&mut ts, trader_addr, max_trade, &clock);

    // Check that the expected amount of fees are earned
    withdraw_and_check_coin_values(&mut ts, lp_addr, max_trade, 0);
    end_scenario_with_clock(ts, clock);
}


/// Test that a liquidity provider doesn't earn any fees for trades that happen
/// before they supplied liquidity.
#[test]
fun no_fee_hijacking() {
    let (mut ts, mut clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        1,
        10 * 10u64.pow(9),
        10 * 10u64.pow(9)
    );
    let second_lp = @0xB;

    let coin_amount = 1 * 10u64.pow(9);
    swap_ltr_and_transfer(&mut ts, @0x12345, coin_amount, &clock);

    // Important: increment the clock
    clock.increment_for_testing(1);

    // Provide a large amount of liquidity
    let left_supplied = 10u64.pow(15);
    let right_supplied = 10u64.pow(15);
    provide_liquidity(&mut ts, second_lp, left_supplied, right_supplied, 1, &clock);
    withdraw_and_check_coin_values(&mut ts, second_lp, left_supplied, right_supplied);

    end_scenario_with_clock(ts, clock);
}

/// Test swaps by doing two swaps, one left-to-right, one right-to left,
/// without crossing over any bins, checking that the received amounts are
/// correct.
#[test]
fun swap_single_bin() {
    let (mut ts, clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        1,
        10 * 10u64.pow(9),
        10 * 10u64.pow(9)
    );

    // Perform swaps
    let trader_addr = @0xABAB;
    let trade_left = 1 * 10u64.pow(9);
    let trade_right = 1 * 10u64.pow(9);
    let coin_right = swap_ltr(&mut ts, trader_addr, trade_left, &clock);
    let coin_left = swap_rtl(&mut ts, trader_addr, trade_right, &clock);

    // Check swap results
    let price = ufp256::new(DEFAULT_PRICE_MANTISSA);

    let trade_left_after_fees = trade_left * (ONE_BPS - DEFAULT_FEE_BPS) / ONE_BPS;
    let expected_value_right = price.mul_u64(trade_left_after_fees);
    assert_eq(coin_right.value(), expected_value_right);

    let trade_right_after_fees = trade_right * (ONE_BPS - DEFAULT_FEE_BPS) / ONE_BPS;
    let expected_value_left = price.div_u64(trade_right_after_fees);
    assert_eq(coin_left.value(), expected_value_left);

    // Return coins to owner
    transfer::public_transfer(coin_right, trader_addr);
    transfer::public_transfer(coin_left, trader_addr);

    end_scenario_with_clock(ts, clock);
}

/// Test swaps by doing two swaps, one left-to-right, one right-to left, without
/// crossing over any bins, checking that the received amounts are correct.
#[test]
fun swap_multiple_bins() {
    // Deposit 2bln LEFT and/or RIGHT per bin.
    let bin_count = 3;
    let left_amount_per_bin = 2 * 10u64.pow(9);
    let right_amount_per_bin = 2 * 10u64.pow(9);
    let left_amount = left_amount_per_bin * ((bin_count + 1) / 2);
    let right_amount = right_amount_per_bin * ((bin_count + 1) / 2);
    let (mut ts, clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        bin_count,
        left_amount,
        right_amount
    );

    // Perform swaps
    let trader_addr = @0xABAB;
    let trade_amount_left = 6 * 10u64.pow(9);
    let trade_amount_right = 3 * 10u64.pow(9);

    // Calculate expected swap results (left-to-right)
    let first_bin_price = ufp256::new(DEFAULT_PRICE_MANTISSA);
    let second_bin_price = first_bin_price.mul(ufp256::from_fraction((ONE_BPS+DEFAULT_BIN_STEP) as u256, ONE_BPS as u256));

    let right_from_first_bin = right_amount_per_bin;
    let left_traded_in_first_bin_no_fees = first_bin_price.div_u64(right_amount_per_bin);
    let left_remaining = trade_amount_left - (apply_fee_inv(left_traded_in_first_bin_no_fees, DEFAULT_FEE_BPS));
    let right_from_second_bin = second_bin_price.mul_u64(apply_fee(left_remaining, DEFAULT_FEE_BPS));

    let expected_value_right = right_from_first_bin + right_from_second_bin;
    let coin_right = swap_ltr(&mut ts, trader_addr, trade_amount_left, &clock);
    assert_eq(coin_right.value(), expected_value_right);

    // Calculate expected swap results (right-to-left)
    let left_for_full_first_bin_no_fee = first_bin_price.div_u64(right_amount_per_bin);
    let left_from_second_bin = trade_amount_left - (apply_fee_inv(left_for_full_first_bin_no_fee, DEFAULT_FEE_BPS));
    let right_remaining =  trade_amount_right - (apply_fee_inv(second_bin_price.mul_u64(left_from_second_bin), DEFAULT_FEE_BPS));
    let left_from_first_bin = first_bin_price.div_u64(apply_fee(right_remaining, DEFAULT_FEE_BPS));

    let expected_value_left = left_from_first_bin + left_from_second_bin;

    let coin_left = swap_rtl(&mut ts, trader_addr, trade_amount_right, &clock);
    assert_eq(coin_left.value(), expected_value_left);

    // Return coins to owner
    transfer::public_transfer(coin_right, trader_addr);
    transfer::public_transfer(coin_left, trader_addr);

    end_scenario_with_clock(ts, clock);
}

/// Test that a large number (100) of swaps can be performed inside just one
/// bin, as long as the left-to-right and right-to-left swaps counteract each
/// other, keeping the liquidity inside the bin stable.
#[test]
fun swap_single_bin_lots_of_swaps() {
    let (mut ts, clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        1,
        5 * 10u64.pow(9),
        5 * 10u64.pow(9)
    );

    // Set equivalent left and right amount so trades don't change active bin
    let trader_addr = @0xABAB;
    let trade_left = 1 * 10u64.pow(9);
    let trade_right = ufp256::new(DEFAULT_PRICE_MANTISSA).mul_u64(trade_left);

    // Perform 100 swaps
    let mut i = 0;
    while (i < 100) {
        swap_ltr_and_transfer(&mut ts, trader_addr, trade_left, &clock);
        swap_rtl_and_transfer(&mut ts, trader_addr, trade_right, &clock);
        i = i + 1;
    };

    end_scenario_with_clock(ts, clock);
}

/// Test that a receipt received from pool A can't be used to withdraw
/// liquidity from pool B.
#[test]
#[expected_failure(abort_code = liquidity_book::EInvalidPoolID)]
fun reject_invalid_receipt() {
    let lp_addr = @0xA;
    let left_supplied = 5 * 10u64.pow(9);
    let right_supplied = 5 * 10u64.pow(9);
    let (mut ts, clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        1,
        left_supplied,
        right_supplied
    );

    // Create second pool have `lp_addr` provide the same liquidity as already
    // exists in the first pool
    liquidity_book::new<LEFT, RIGHT>(
        DEFAULT_BIN_STEP,
        DEFAULT_PRICE_MANTISSA,
        DEFAULT_FEE_BPS,
        ts.ctx()
    );
    provide_liquidity(&mut ts, lp_addr, left_supplied, right_supplied, 1, &clock);

    // Get receipt to try to withdraw liquidity from the other pool
    ts.next_tx(lp_addr);
    let receipt = ts.take_from_address<LiquidityProviderReceipt>(lp_addr);

    // Call take_shared twice to get the first pool
    let second_pool = ts.take_shared<Pool<LEFT, RIGHT>>();
    let mut first_pool = ts.take_shared<Pool<LEFT, RIGHT>>();

    // Try to withdraw from the wrong pool
    first_pool.withdraw_liquidity(receipt, ts.ctx());

    ts::return_shared(second_pool);
    ts::return_shared(first_pool);
    end_scenario_with_clock(ts, clock);
}

/// Test that a trade aborts when there is not enough liquidity in a pool.
#[test]
#[expected_failure(abort_code = liquidity_book::EInsufficientPoolLiquidity)]
fun abort_too_large_trade() {
    let left_supplied = 10 * 10u64.pow(9);
    let right_supplied = 10 * 10u64.pow(9);
    let (mut ts, clock) = scenario_default_pool_with_liquidity(
        @0xABCDEF,
        1,
        left_supplied,
        right_supplied
    );

    // Max left-to-right trade for 10bln RIGHT is 20bln LEFT plus fees.
    // Applying fees rounds down so this only errors starting at `+2` (instead
    // of the expected `+1`).
    let trader_addr = @0xA;
    let max_trade_no_fees = ufp256::new(DEFAULT_PRICE_MANTISSA).div_u64(right_supplied);
    let max_trade = apply_fee_inv(max_trade_no_fees, DEFAULT_FEE_BPS);
    let too_large_amount = max_trade + 2;
    swap_ltr_and_transfer(&mut ts, trader_addr, too_large_amount, &clock);

    end_scenario_with_clock(ts, clock);
}

/// Test that a supplying liquidity with an even number of bins fails.
#[test]
#[expected_failure(abort_code = liquidity_book::EEvenBincount)]
fun provide_liquidity_uniformly_abort_on_odd_bin_count() {
    let mut ts = scenario_default_pool();

    let bin_count = 2;
    let clock = clock::create_for_testing(ts.ctx());
    provide_liquidity(&mut ts, @0xABCDEF, 2, 2, bin_count, &clock);

    end_scenario_with_clock(ts, clock);
}

/// Test that a supplying 0 liquidity fails.
#[test]
#[expected_failure(abort_code = liquidity_book::ENoLiquidityProvided)]
fun provide_liquidity_uniformly_abort_on_no_liquidity() {
    let mut ts = scenario_default_pool();

    let bin_count = 1;
    let clock = clock::create_for_testing(ts.ctx());
    provide_liquidity(&mut ts, @0xABCDEF, 0, 0, bin_count, &clock);

    end_scenario_with_clock(ts, clock);
}

}
