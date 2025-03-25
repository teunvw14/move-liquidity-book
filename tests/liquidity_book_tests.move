// Copyright (c) 2025 Teun van Wezel
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module liquidity_book::liquidity_book_tests {

use iota::test_scenario as ts;
use iota::coin::{Self};
use iota::test_utils::assert_eq;

use liquidity_book::liquidity_book::{Self, Pool};
use liquidity_book::ufp256::{Self};

public struct LEFT has drop {}
public struct RIGHT has drop {}

const DEFAULT_BIN_STEP: u64 = 20;
const DEFAULT_PRICE_MANTISSA: u256 = 5000000000000000000; // 0.5
const ONE_BPS: u64 = 10000;


// ================
// Helper functions
// ================

/// Test swaps by doing two swaps, one left-to-right, one right-to left,
/// without crossing over any bins, checking that the received amounts are
/// correct.
#[test]
fun swap_single_bin() {
    let admin_addr = @0xAAAA;
    let mut ts = ts::begin(admin_addr);

    // Initialize pool with 10bln LEFT and 10bln RIGHT tokens, all inside 1 bin
    let bln_10 = 10 * 10u64.pow(9);
    liquidity_book::new<LEFT, RIGHT>(
        DEFAULT_BIN_STEP,
        DEFAULT_PRICE_MANTISSA,
        coin::mint_for_testing<LEFT>(bln_10, ts.ctx()),
        coin::mint_for_testing<RIGHT>(bln_10, ts.ctx()),
        1,
        ts.ctx()
    );

    // Now swap
    let trader_addr = @0xBBBB;
    ts.next_tx(trader_addr);

    // Perform swaps
    let trade_left = 1 * 10u64.pow(9);
    let trade_right = 1 * 10u64.pow(9);

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();

    let coin_left_in = coin::mint_for_testing<LEFT>(trade_left, ts.ctx());
    let coin_right_in = coin::mint_for_testing<RIGHT>(trade_left, ts.ctx());

    let coin_right_result = pool.swap_ltr(coin_left_in, ts.ctx());
    let coin_left_result = pool.swap_rtl(coin_right_in, ts.ctx());

    // Check swap results
    let price = ufp256::new(DEFAULT_PRICE_MANTISSA);

    let expected_value_right = price.mul_u64(trade_left);
    assert_eq(coin_right_result.value(), expected_value_right);

    let expected_value_left = price.div_u64(trade_right);
    assert_eq(coin_left_result.value(), expected_value_left);

    // Return coins to owner
    transfer::public_transfer(coin_right_result, trader_addr);
    transfer::public_transfer(coin_left_result, trader_addr);

    ts::return_shared(pool);
    ts.end();
}

/// Test swaps by doing two swaps, one left-to-right, one right-to left, without
/// crossing over any bins, checking that the received amounts are correct.
#[test]
fun swap_multiple_bins() {
    let admin_addr = @0xAAAA;
    let mut ts = ts::begin(admin_addr);

    // Initialize pool with 2bln LEFT and/or RIGHT per bin.
    let bin_count = 3;
    let left_amount_per_bin = 2 * 10u64.pow(9);
    let right_amount_per_bin = 2 * 10u64.pow(9);
    let left_amount = left_amount_per_bin * ((bin_count + 1) / 2);
    let right_amount = right_amount_per_bin * ((bin_count + 1) / 2);
    liquidity_book::new<LEFT, RIGHT>(
        DEFAULT_BIN_STEP,
        DEFAULT_PRICE_MANTISSA,
        coin::mint_for_testing<LEFT>(left_amount, ts.ctx()),
        coin::mint_for_testing<RIGHT>(right_amount, ts.ctx()),
        bin_count,
        ts.ctx()
    );

    // We will trade 6 LEFT for ~3 RIGHT
    let trade_amount_left = 6 * 10u64.pow(9);

    // Calculate expected swap results (left-to-right)
    let first_bin_price = ufp256::new(DEFAULT_PRICE_MANTISSA);
    let second_bin_price = first_bin_price.mul(ufp256::from_fraction((ONE_BPS+DEFAULT_BIN_STEP) as u256, ONE_BPS as u256));

    let right_from_first_bin = right_amount_per_bin;
    let left_traded_in_first_bin = first_bin_price.div_u64(right_amount_per_bin);
    let left_remaining = trade_amount_left - left_traded_in_first_bin;
    let right_from_second_bin = second_bin_price.mul_u64(left_remaining);
    let expected_value_right = right_from_first_bin + right_from_second_bin;

    // Perform swaps
    let trader_addr = @0xABAB;
    ts.next_tx(trader_addr);
    let coin_left = coin::mint_for_testing<LEFT>(trade_amount_left, ts.ctx());

    let mut pool= ts.take_shared<Pool<LEFT, RIGHT>>();
    let coin_right = pool.swap_ltr(coin_left, ts.ctx());

    // Assert that we received the expected amount of RIGHT tokens
    assert_eq(coin_right.value(), expected_value_right);

    // Return coins to owner
    transfer::public_transfer(coin_right, trader_addr);

    ts::return_shared(pool);
    ts.end();
}

}
