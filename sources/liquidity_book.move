// Copyright (c) 2025 Teun van Wezel
// SPDX-License-Identifier: Apache-2.0

module liquidity_book::liquidity_book {

use iota::balance::{Self, Balance};
use iota::vec_map::{Self, VecMap};
use iota::coin::{Self, Coin};

use liquidity_book::ufp256::{Self, UFP256};

const MID_U64: u64 = 9223372036854775808; // 2^64 / 2
const ONE_BPS: u64 = 10000;

// ======
// Errors
// ======

#[error]
const EInsufficientPoolLiquidity: vector<u8> =
    b"Insufficient Pool Liquidity: There is not enough liquidity inside the pool to fulfill the trade.";

#[error]
const EEvenBincount: vector<u8> =
    b"Illegal bin count. Bin count is even but should be odd.";

// =======
// Structs
// =======

/// Liquidity Book trading pool type.
public struct Pool<phantom L, phantom R> has key {
    id: UID,
    bins: VecMap<u64, PoolBin<L, R>>, // bins are identified with a unique id
    active_bin_id: u64, // id of the active bin
    bin_step_bps: u64, // The step/delta between bins in basis points (0.0001)
}

/// Bin type for a Liquidity Book trading pool. Trades in this bin exchange
/// 1 L token for `price` R tokens.
public struct PoolBin<phantom L, phantom R> has store {
    price: UFP256, // The trading price inside this bin
    balance_left: Balance<L>,
    balance_right: Balance<R>,
}

// =========
// Functions
// =========

/// Create a new Liquidity Book `Pool`
entry fun new<L, R>(
    bin_step_bps: u64,
    starting_price_mantissa: u256,
    mut starting_liquidity_left: Coin<L>,
    mut starting_liquidity_right: Coin<R>,
    bin_count: u64,
    ctx: &mut TxContext
) {
    // An uneven number of bins is required, so that, including the active
    // bin, there is liquidity added to an equal amount of bins to the left
    // and right of the active bin
    assert!(bin_count % 2 == 1, EEvenBincount);

    // Start the first bin with ID in the middle of the u64 range, so as the
    // number of bins increase, the ID's don't over- or underflow
    let starting_active_bin_id = MID_U64;
    let starting_price = ufp256::new(starting_price_mantissa);
    let mut bins = vec_map::empty();

    let bins_each_side = (bin_count - 1) / 2; // the amount of bins left and right of the active bin
    let coin_left_per_bin = starting_liquidity_left.value() / (bins_each_side + 1);
    
    let bin_step_price_factor = ufp256::from_fraction((ONE_BPS + bin_step_bps) as u256, ONE_BPS as u256);
    let mut new_bin_price = starting_price.div(bin_step_price_factor);
    1u64.range_do_eq!(bins_each_side, |n| {
        // Initialize new bin
        let new_bin_id = starting_active_bin_id - n;
        let balance_for_bin = starting_liquidity_left.split(coin_left_per_bin, ctx).into_balance();

        let new_bin = PoolBin {
            price: new_bin_price,
            balance_left: balance_for_bin,
            balance_right: balance::zero(),
        };

        // Add bin
        bins.insert(new_bin_id, new_bin);
        new_bin_price = new_bin_price.div(bin_step_price_factor);
    });

    // Add right bins
    let coin_right_per_bin = starting_liquidity_right.value() / (bins_each_side + 1);
    let mut new_bin_price = starting_price.mul(bin_step_price_factor);
    1u64.range_do_eq!(bins_each_side, |n| {
        // Initialize new bin
        let new_bin_id = starting_active_bin_id + n;
        let balance_for_bin = starting_liquidity_right.split(coin_right_per_bin, ctx).into_balance();

        let new_bin = PoolBin {
            price: new_bin_price,
            balance_left: balance::zero(),
            balance_right: balance_for_bin,
        };

        // Add bin
        bins.insert(new_bin_id, new_bin);
        new_bin_price = new_bin_price.mul(bin_step_price_factor);
    });

    let starting_bin = PoolBin {
        price: starting_price,
        balance_left: starting_liquidity_left.into_balance(),
        balance_right: starting_liquidity_right.into_balance()
    };
    bins.insert(starting_active_bin_id, starting_bin);

    // Create and share the pool
    let pool = Pool<L, R> {
        id: object::new(ctx),
        bins,
        active_bin_id: starting_active_bin_id,
        bin_step_bps,
    };

    transfer::share_object(pool);
}

/// Returns a reference to a bin from a bin `id`.
public fun get_bin<L, R>(self: &Pool<L, R>, id: &u64): &PoolBin<L, R> {
    let bin = self.bins.get(id);
    bin
}

/// Public accessor for `pool.active_bin_id`.
public fun get_active_bin_id<L, R>(self: &Pool<L, R>): u64 {
    self.active_bin_id
}

/// Returns the pool's active bin price.
public fun get_active_price<L, R>(self: &Pool<L, R>): UFP256 {
    self.get_active_bin().price
}

/// Returns a reference to the pool `active_bin`.
public fun get_active_bin<L, R>(self: &Pool<L, R>): &PoolBin<L, R> {
    self.get_bin(&self.active_bin_id)
}

/// Private mutable accessor for the pool `active_bin`.
fun get_active_bin_mut<L, R>(self: &mut Pool<L, R>): &mut PoolBin<L, R> {
    self.bins.get_mut(&self.active_bin_id)
}

/// Setter for `pool.active_bin_id`.
fun set_active_bin<L, R>(self: &mut Pool<L, R>, id: u64) {
    if (self.bins.contains(&id)) {
        self.active_bin_id = id;
    }
}

/// Public accessor for `bin.price`.
public fun price<L, R>(self: &PoolBin<L, R>): UFP256 {
    self.price
}

/// Returns the left balance of a bin.
public fun balance_left<L, R>(self: &PoolBin<L, R>): u64 {
    self.balance_left.value()
}

/// Returns the right balance of a bin.
public fun balance_right<L, R>(self: &PoolBin<L, R>): u64 {
    self.balance_right.value()
}

// Swap `coin_left` for an equivalent amount of `R` in a `Pool`
public fun swap_ltr<L, R>(self: &mut Pool<L, R>, mut coin_left: Coin<L>, ctx: &mut TxContext): Coin<R> {
    let mut result_coin = coin::zero<R>(ctx);

    // Keep emptying bins until `coin_left` is fully swapped
    while (coin_left.value() > 0) {
        let active_bin = self.get_active_bin_mut();

        let mut swap_left = coin_left.value();
        let mut swap_right = active_bin.price.mul_u64(swap_left);

        // If there's not enough balance in this bin to fulfill
        // swap, adjust swap amounts to maximum.
        let bin_balance_right = active_bin.balance_right();
        if (swap_right > bin_balance_right) {
            swap_right = bin_balance_right;
            swap_left = active_bin.price.div_u64(bin_balance_right);
        };

        // Execute swap
        active_bin.balance_left.join(coin_left.split(swap_left, ctx).into_balance());
        result_coin.join(active_bin.balance_right.split(swap_right).into_coin(ctx));

        // Cross over one bin right if active bin is empty after swap,
        // abort if swap is not complete and no bins are left
        if (active_bin.balance_right() == 0) {
            let bin_right_id = self.active_bin_id + 1;
            if (coin_left.value() > 0) {
                assert!(self.bins.contains(&bin_right_id), EInsufficientPoolLiquidity);
            };
            self.set_active_bin(bin_right_id);
        };
    };
    coin_left.destroy_zero();

    result_coin
}

// Swap `coin_right` for an equivalent amount of `L` in a `Pool`.
public fun swap_rtl<L, R>(self: &mut Pool<L, R>, mut coin_right: Coin<R>, ctx: &mut TxContext): Coin<L> {
    let mut result_coin = coin::zero<L>(ctx);

    // Keep emptying bins until `coin_right` is fully swapped
    while (coin_right.value() > 0) {
        let active_bin = self.get_active_bin_mut();

        let mut swap_right = coin_right.value();
        let mut swap_left = active_bin.price.div_u64(swap_right);

        // If there's not enough balance in this bin to fulfill
        // swap, adjust swap amounts to maximum.
        let bin_balance_left = active_bin.balance_left();
        if (swap_left > bin_balance_left) {
            swap_left = bin_balance_left;
            swap_right = active_bin.price.mul_u64(swap_left);
        };

        // Execute swap
        active_bin.balance_right.join(coin_right.split(swap_right, ctx).into_balance());
        result_coin.join(active_bin.balance_left.split(swap_left).into_coin(ctx));

        // Cross over one bin left if active bin is empty after swap,
        // abort if swap is not complete and no bins are left
        if (active_bin.balance_left() == 0) {
            let bin_left_id = self.active_bin_id - 1;
            if (coin_right.value() > 0) {
                assert!(self.bins.contains(&bin_left_id), EInsufficientPoolLiquidity);
            };
            self.set_active_bin(bin_left_id);
        };
    };
    coin_right.destroy_zero();

    result_coin
}

}
