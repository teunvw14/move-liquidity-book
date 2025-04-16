// Copyright (c) 2025 Teun van Wezel
// SPDX-License-Identifier: Apache-2.0

module liquidity_book::liquidity_book {

use iota::balance::{Self, Balance};
use iota::vec_map::{Self, VecMap};
use iota::coin::{Self, Coin};
use iota::clock::Clock;

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

#[error]
const ENoLiquidityProvided: vector<u8> =
    b"No tokens supplied.";

#[error]
const EInvalidPoolID: vector<u8> =
    b"Mismatched Pool ID: The Pool ID in the receipt does not match the Pool ID for withdrawal.";

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

/// A struct representing liquidity provided in a specific bin with amounts
/// `left` of `Coin<L>` and `right` of `Coin<R>`.
public struct BinProvidedLiquidity has store, copy, drop {
    bin_id: u64,
    left: u64,
    right: u64
}

/// Receipt given to liquidity providers when they provide liquidity. Is used to
/// withdraw provided liquidity. No `store` capability so this cannot
/// (accidentally) be transferred.
public struct LiquidityProviderReceipt has key {
    id: UID,
    pool_id: ID, // The id that the liquidity was provided in
    deposit_time_ms: u64, // Timestamp from the moment the liquidity was provided
    liquidity: vector<BinProvidedLiquidity> // A record of how much liquidity was provided
}

// =========
// Functions
// =========

/// Create a new Liquidity Book `Pool`
entry fun new<L, R>(
    bin_step_bps: u64,
    starting_price_mantissa: u256,
    ctx: &mut TxContext
) {
    let starting_price = ufp256::new(starting_price_mantissa);
    let starting_bin = PoolBin {
        price: starting_price,
        balance_left: balance::zero<L>(),
        balance_right: balance::zero<R>(),
    };
    // Start the first bin with ID in the middle of the u64 range, so as the
    // number of bins increase, the ID's don't over- or underflow
    let starting_bin_id = MID_U64;
    let mut bins = vec_map::empty();
    bins.insert(
        starting_bin_id,
        starting_bin
    );

    // Create and share the pool
    let pool = Pool<L, R> {
        id: object::new(ctx),
        bins,
        active_bin_id: starting_bin_id,
        bin_step_bps,
    };
    transfer::share_object(pool);
}

/// Private mutable accessor for pool bin with id `id`.
fun get_bin_mut<L, R>(self: &mut Pool<L, R>, id: u64): &mut PoolBin<L, R>{
    self.bins.get_mut(&id)
}

/// Add a bin to a pool at a particular price if it doesn't exist yet.
fun add_bin<L, R>(self: &mut Pool<L, R>, id: u64, price: UFP256) {
    if (!self.bins.contains(&id)) {
        self.bins.insert(id, PoolBin {
            price: price,
            balance_left: balance::zero<L>(),
            balance_right: balance::zero<R>()
        });
    };
}

entry fun provide_liquidity_uniformly<L, R>(
    self: &mut Pool<L, R>,
    bin_count: u64,
    mut coin_left: Coin<L>,
    mut coin_right: Coin<R>,
    clock: &Clock,
    ctx: &mut TxContext
) {
    // An uneven number of bins is required, so that, including the active
    // bin, there is liquidity added to an equal amount of bins to the left
    // and right of the active bins
    assert!(bin_count % 2 == 1, EEvenBincount);

    // Assert some minimal amount of liquidity is added
    assert!(coin_left.value() > 0 || coin_right.value() > 0,
        ENoLiquidityProvided);

    let active_bin_id = self.get_active_bin_id();
    let bins_each_side = (bin_count - 1) / 2; // the amount of bins left and right of the active bin
    let bin_step_price_factor = ufp256::from_fraction((ONE_BPS + self.bin_step_bps) as u256, ONE_BPS as u256);

    // Create receipt that will function as proof of providing liquidity
    let mut receipt = LiquidityProviderReceipt {
        id: object::new(ctx),
        pool_id: self.id.to_inner(),
        deposit_time_ms: clock.timestamp_ms(),
        liquidity: vector::empty()
    };

    // Add left bins
    let coin_left_per_bin = coin_left.value() / (bins_each_side + 1);
    let mut new_bin_price = self.get_active_price().div(bin_step_price_factor);
    1u64.range_do_eq!(bins_each_side, |n| {
        // Initialize new bin
        let new_bin_id = active_bin_id - n;
        self.add_bin(new_bin_id, new_bin_price);
        let new_bin = self.get_bin_mut(new_bin_id);

        // Add balance to new bin
        let balance_for_bin = coin_left.split(coin_left_per_bin, ctx).into_balance();
        new_bin.balance_left.join(balance_for_bin);
        // new_bin.provided_left = new_bin.provided_left + coin_left_per_bin;

        // Update receipt
        receipt.liquidity.push_back(BinProvidedLiquidity{
            bin_id: new_bin_id,
            left: coin_left_per_bin,
            right: 0
        });
        new_bin_price = new_bin_price.div(bin_step_price_factor);
    });

    // Add right bins
    let coin_right_per_bin = coin_right.value() / (bins_each_side + 1);
    let mut new_bin_price = self.get_active_price().mul(bin_step_price_factor);
    1u64.range_do_eq!(bins_each_side, |n| {
        // Initialize new bin
        let new_bin_id = active_bin_id + n;
        self.add_bin(new_bin_id, new_bin_price);
        let new_bin = self.get_bin_mut(new_bin_id);

        // Add balance to new bin
        let balance_for_bin = coin_right.split(coin_right_per_bin, ctx).into_balance();
        new_bin.balance_right.join(balance_for_bin);
        // new_bin.provided_right = new_bin.provided_right + coin_right_per_bin;

        // Update receipt
        receipt.liquidity.push_back(BinProvidedLiquidity{
            bin_id: new_bin_id,
            left: 0,
            right: coin_right_per_bin
        });
        new_bin_price = new_bin_price.mul(bin_step_price_factor);
    });

    // Add remaining liquidity to the active bin
    let amount_left_active_bin = coin_left.value();
    let amount_right_active_bin = coin_right.value();
    let active_bin = self.get_active_bin_mut();
    active_bin.balance_left.join(coin_left.into_balance());
    active_bin.balance_right.join(coin_right.into_balance());
    // active_bin.provided_left = active_bin.provided_left + amount_left_active_bin;
    // active_bin.provided_right = active_bin.provided_right + amount_right_active_bin;

    // Update receipt for liquidity provided in the pool.active_bin
    receipt.liquidity.push_back(BinProvidedLiquidity{
        bin_id: self.get_active_bin_id(),
        left: amount_left_active_bin,
        right: amount_right_active_bin
    });

    // Give receipt
    transfer::transfer(receipt, ctx.sender());
}

/// Withdraw all provided liquidity from `pool` using a
/// `LiquidityProviderReceipt`.
entry fun withdraw_liquidity<L, R> (self: &mut Pool<L, R>, receipt: LiquidityProviderReceipt, ctx: &mut TxContext) {
    let LiquidityProviderReceipt {id: receipt_id, pool_id: receipt_pool_id, deposit_time_ms, liquidity: mut provided_liquidity} = receipt;

    // Make sure that he receipt was given for liquidity in this pool
    assert!(self.id.to_inner() == receipt_pool_id, EInvalidPoolID);

    let mut result_coin_left = coin::zero<L>(ctx);
    let mut result_coin_right = coin::zero<R>(ctx);

    while (!provided_liquidity.is_empty()) {
        let bin_provided_liquidity = provided_liquidity.pop_back();
        let bin = self.get_bin_mut(bin_provided_liquidity.bin_id);

        // Withdraw left liquidity
        let payout_left_amount = bin_provided_liquidity.left;
        if (bin.balance_left.value() >= payout_left_amount) {
            result_coin_left.join(bin.balance_left.split(payout_left_amount).into_coin(ctx));
        } else {
            let remainder = payout_left_amount - bin.balance_left.value();
            result_coin_left.join(bin.balance_left.withdraw_all().into_coin(ctx));
            let mut remainder_as_r = bin.price.mul_u64(remainder);
            // Sometimes due to rounding, the bin might contain 1 RIGHT
            // 'too little', in which case `remainder_as_r - 1` is returned
            if (remainder_as_r - bin.balance_right.value() == 1) {
                remainder_as_r = remainder_as_r - 1;
            };
            result_coin_right.join(bin.balance_right.split(remainder_as_r).into_coin(ctx));
        };

        // Withdraw right liquidity
        let payout_right_amount = bin_provided_liquidity.right;
        if (bin.balance_right.value() >= payout_right_amount) {
            result_coin_right.join(bin.balance_right.split(payout_right_amount).into_coin(ctx));
        } else {
            let remainder = payout_right_amount - bin.balance_right.value();
            result_coin_right.join(bin.balance_right.withdraw_all().into_coin(ctx));
            let mut remainder_as_l = bin.price.div_u64(remainder);
            // Sometimes due to rounding, the bin might contain 1 LEFT
            // 'too little', in which case `remainder_as_l - 1` is returned
            if (remainder_as_l - bin.balance_left.value() == 1) {
                remainder_as_l = remainder_as_l - 1;
            };
            result_coin_left.join(bin.balance_left.split(remainder_as_l).into_coin(ctx));
        };
    };
    provided_liquidity.destroy_empty();

    // Send the liquidity back to the liquidity provider
    let sender = ctx.sender();

    transfer::public_transfer(result_coin_left, sender);
    transfer::public_transfer(result_coin_right, sender);

    // Delete the receipt so liquidity can't be withdrawn twice
    object::delete(receipt_id);
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
public fun swap_ltr<L, R>(self: &mut Pool<L, R>, mut coin_left: Coin<L>, clock: &Clock, ctx: &mut TxContext): Coin<R> {
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
public fun swap_rtl<L, R>(self: &mut Pool<L, R>, mut coin_right: Coin<R>, clock: &Clock, ctx: &mut TxContext): Coin<L> {
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
