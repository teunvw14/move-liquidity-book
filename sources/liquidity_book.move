/// Module: liquidity_book
module l1dex::liquidity_book {

    use iota::balance::{Self, Balance};
    use iota::vec_map::{Self, VecMap};
    use iota::coin::{Self, Coin};
    use iota::clock::Clock;

    use l1dex::ufp256::{Self, UFP256};

    const MAX_U64: u64 = 18446744073709551615; // 2^64 - 1
    // The protocol max pool fee in basis points (0.5%)
    const MAX_BASE_FEE_BPS: u64 = 50;

    // Errors
    #[error]
    const EInsufficientPoolLiquidity: vector<u8> = 
        b"There is not enough liquidity inside the pool to fulfill the trade.";
    // Structs

    /// Liquidity Book trading pool type.
    public struct Pool<phantom L, phantom R> has key, store {
        id: UID,
        bins: VecMap<u64, PoolBin<L, R>>, // bins are identified with a unique id
        active_bin_id: u64, // id of the active bin
        bin_step_bps: u64, // The step/delta between bins in basis points (0.0001)
        fee_bps: u64, // The base fee for a swap
    }

    /// Bin type for a Liquidity Book trading pool.
    public struct PoolBin<phantom L, phantom R> has store {
        price: UFP256, // amount(L) * price = amount(R)
        balance_left: Balance<L>,
        balance_right: Balance<R>,
        fee_log_left: vector<FeeLogEntry>,
        fee_log_right: vector<FeeLogEntry>
    }

    public struct FeeLogEntry has store, copy, drop {
        amount: u64,
        timestamp_ms: u64, // When the fee was generated 
        total_bin_size: u64 // The amount of tokens in the bin (expressed in just one token)
    }

    /// A struct representing liquidity provided in a specific bin with amounts
    /// `left` of `Coin<L>` and `right` of `Coin<R>`.
    public struct BinProvidedLiquidity has store, copy, drop {
        bin_id: u64,
        left: u64,
        right: u64
    }

    /// Receipt given to liquidity providers when they provide liquidity. Can be
    /// used to withdraw provided liquidity. No `store` capability so this 
    /// cannot (accidentally) be transferred.
    public struct LiquidityProviderReceipt has key {
        id: UID,
        deposit_time_ms: u64, 
        liquidity: vector<BinProvidedLiquidity>
    }

    /// Create a new Liquidity Book `Pool`
    public entry fun new<L, R>(
        bin_step_bps: u64, 
        starting_price_mantissa: u256,
        fee_bps: u64,
        ctx: &mut TxContext
    ) {
        let starting_price = ufp256::new(starting_price_mantissa);
        let starting_bin = PoolBin {
            price: starting_price,
            balance_left: balance::zero<L>(),
            balance_right: balance::zero<R>(),
            fee_log_left: vector::empty(),
            fee_log_right: vector::empty()
        };
        let starting_bin_id = MAX_U64 / 2;
        let mut bins = vec_map::empty();
        bins.insert(
            starting_bin_id,
            starting_bin
        );

        let fee_bps = MAX_BASE_FEE_BPS.max(fee_bps);

        // Create and share the pool
        let pool = Pool<L, R> {
            id: object::new(ctx),
            bins,
            active_bin_id: starting_bin_id,
            bin_step_bps,
            fee_bps,
        };
        transfer::public_share_object(pool);
    }

    fun fee_bps<L, R>(self: &Pool<L, R>): u64 {
        return self.fee_bps
    }

    public fun get_active_price<L, R>(pool: &Pool<L, R>): UFP256 {
        pool.get_active_bin().price
    }

    public fun get_active_bin_id<L, R>(pool: &Pool<L, R>): u64{
        pool.active_bin_id
    }

    public fun get_active_bin<L, R>(pool: &Pool<L, R>): &PoolBin<L, R>{
        pool.get_bin(&pool.active_bin_id)
    }

    fun get_active_bin_mut<L, R>(pool: &mut Pool<L, R>): &mut PoolBin<L, R>{
        pool.bins.get_mut(&pool.active_bin_id)
    }

    /// Set `pool` active bin
    fun set_active_bin<L, R>(pool: &mut Pool<L, R>, id: u64) {
        if (pool.bins.contains(&id)) {
            pool.active_bin_id = id;
        }
    }

    /// Get a reference to a bin from a bin `id`
    public fun get_bin<L, R>(self: &Pool<L, R>, id: &u64): &PoolBin<L, R>{
        let bin = self.bins.get(id);
        bin
    }

    /// Calculate the value of two amounts represented as the left
    public fun amount_as_l(price: UFP256, amount_l: u64, amount_r: u64): u64 {
        amount_l + price.div_u64(amount_r)
    }

    public fun get_closest_bin<L, R>(pool: &Pool<L, R>, price: UFP256): u64{
        let mut min_diff = ufp256::new(2u256.pow(254));
        let mut closest_bin = pool.get_active_bin_id();
        pool.bins.keys().do!(|bin_id| {
            let bin_price = pool.bins.get(&bin_id).price;
            let diff = price.diff(bin_price);
            if (diff.min(min_diff) == diff) {
                min_diff = diff;
                closest_bin = bin_id;
            }
        });
        closest_bin
    }

    fun get_bin_mut<L, R>(self: &mut Pool<L, R>, id: u64): &mut PoolBin<L, R>{
        self.bins.get_mut(&id)
    }

    /// Add a bin to a pool at a particular price if it doesn't exist yet
    fun add_bin<L, R>(self: &mut Pool<L, R>, id: u64, price: UFP256) {
        if (!self.bins.contains(&id)) {
            self.bins.insert(id, PoolBin {
                price: price,
                balance_left: balance::zero<L>(),
                balance_right: balance::zero<R>(),
                fee_log_left: vector::empty(),
                fee_log_right: vector::empty()
            });
        };
    }

    /// Get the value of `price` of a bin
    public fun price<L, R>(self: &PoolBin<L, R>): UFP256 {
        self.price
    }

    /// Get the value of `balance_left` of a bin
    public fun balance_left<L, R>(self: &PoolBin<L, R>): u64 {
        self.balance_left.value()
    }

    /// Get the value of `balance_right` of a bin
    public fun balance_right<L, R>(self: &PoolBin<L, R>): u64 {
        self.balance_right.value()
    }

    /// Add liquidity to the pool around the active bin with an equal 
    /// distribution amongst those bins
    entry fun add_liquidity_uniformly<L, R>(
        pool: &mut Pool<L, R>,
        bin_count: u64,
        mut coin_left: Coin<L>,
        mut coin_right: Coin<R>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // An uneven number of bins is required, so that, including the active
        // bin, there is liquidity added to an equal amount of bins to the left
        // and right of the active bins
        assert!(bin_count % 2 == 1);

        // Assert some minimal amount of liquidity is added
        assert!(coin_left.value() > 0 || coin_right.value() > 0);

        let active_bin_id = pool.get_active_bin_id();
        let bin_count_half = (bin_count - 1) / 2; // the amount of bins left and right of the active bin
        let bin_price_factor = ufp256::from_fraction((10000 + pool.bin_step_bps) as u256, 10000u256);

        let mut receipt = LiquidityProviderReceipt {
            id: object::new(ctx),
            deposit_time_ms: clock.timestamp_ms(),
            liquidity: vector::empty()
        };

        // Add left bins
        let coin_left_per_bin = coin_left.value() / (bin_count_half + 1);
        let mut new_bin_price = pool.get_active_price().div(bin_price_factor);
        1u64.range_do_eq!(bin_count_half, |n| {
            let new_bin_id = active_bin_id - n;
            pool.add_bin(new_bin_id, new_bin_price);

            // Add balance to new bin
            let balance_for_bin = coin_left.split(coin_left_per_bin, ctx).into_balance();
            pool.get_bin_mut(new_bin_id).balance_left.join(balance_for_bin);
            // pool.get_bin_mut(new_bin_id).add_provider_position(ctx.sender(), coin_left_per_bin, 0);

            // Update receipt
            receipt.liquidity.push_back(BinProvidedLiquidity{
                bin_id: new_bin_id,
                left: coin_left_per_bin,
                right: 0
            });
            new_bin_price = new_bin_price.div(bin_price_factor);
        });

        // Add right bins
        let coin_right_per_bin = coin_right.value() / (bin_count_half + 1);
        let mut new_bin_price = pool.get_active_price().mul(bin_price_factor);
        1u64.range_do_eq!(bin_count_half, |n| {
            let new_bin_id = active_bin_id + n;
            pool.add_bin(new_bin_id, new_bin_price);

            // Add balance to new bin
            let balance_for_bin = coin_right.split(coin_right_per_bin, ctx).into_balance();
            pool.get_bin_mut(new_bin_id).balance_right.join(balance_for_bin);
            // pool.get_bin_mut(new_bin_id).add_provider_position(ctx.sender(), 0, coin_right_per_bin);

            // Update receipt
            receipt.liquidity.push_back(BinProvidedLiquidity{
                bin_id: new_bin_id,
                left: 0,
                right: coin_right_per_bin
            });
            new_bin_price = new_bin_price.mul(bin_price_factor);
        });

        // Add liquidity to the active bin
        let amount_right_active_bin = coin_left.value();
        let amount_left_active_bin = coin_right.value();
        let active_bin = pool.get_active_bin_mut();
        active_bin.balance_left.join(coin_left.into_balance());
        active_bin.balance_right.join(coin_right.into_balance());
        // active_bin.add_provider_position(ctx.sender(), amount_left_active_bin, amount_right_active_bin);

        // Update receipt for liquidity provided in the pool.active_bin
        receipt.liquidity.push_back(BinProvidedLiquidity{
            bin_id: pool.get_active_bin_id(),
            left: amount_right_active_bin,
            right: amount_left_active_bin
        });

        // Give receipt
        transfer::transfer(receipt, ctx.sender());
    }

    entry fun withdraw_liquidity<L, R> (pool: &mut Pool<L, R>, receipt: LiquidityProviderReceipt, ctx: &mut TxContext) {
        let LiquidityProviderReceipt {id: receipt_id, deposit_time_ms, mut liquidity} = receipt;
        
        let mut result_coin_left = coin::zero<L>(ctx);
        let mut result_coin_right = coin::zero<R>(ctx);

        while (!liquidity.is_empty()) {
            let provided_liquidity = liquidity.pop_back();
            let bin = pool.get_bin_mut(provided_liquidity.bin_id);

            // Calculate earned fees on `right` provided liquidity
            let mut fees_earned_left = 0;
            if (provided_liquidity.right > 0) {
                // Traverse `fee_log_left` backwards to avoid deletion complexity
                let mut i = bin.fee_log_left.length();
                while (i > 0){
                    let mut fee_log = bin.fee_log_left[i - 1];
                    if (fee_log.timestamp_ms >= deposit_time_ms) {
                        let fee = ufp256::from_fraction((fee_log.amount as u256) * (provided_liquidity.right as u256), fee_log.total_bin_size as u256).truncate_to_u64();
                        fees_earned_left = fees_earned_left + fee;
                        // Update fee log and delete if empty
                        fee_log.amount = fee_log.amount - fee;
                        fee_log.total_bin_size = fee_log.total_bin_size - provided_liquidity.right;
                        if (fee_log.amount == 0) {
                            bin.fee_log_left.remove(i - 1);
                        };
                    };
                    i = i - 1;
                }
            };
            // Calculate earned fees on `left` provided liquidity
            let mut fees_earned_right = 0;
            if (provided_liquidity.left > 0) {
                // Traverse `fee_log_right` backwards to avoid deletion complexity
                let mut i = bin.fee_log_right.length();
                while (i > 0){
                    let mut fee_log = bin.fee_log_right[i - 1];
                    if (fee_log.timestamp_ms >= deposit_time_ms) {
                        let fee = ufp256::from_fraction((fee_log.amount as u256) * (provided_liquidity.left as u256), fee_log.total_bin_size as u256).truncate_to_u64();
                        fees_earned_right = fees_earned_right + fee;
                        // Update fee log and delete if empty
                        fee_log.amount = fee_log.amount - fee;
                        fee_log.total_bin_size = fee_log.total_bin_size - provided_liquidity.left;
                        if (fee_log.amount == 0) {
                            bin.fee_log_right.remove(i - 1);
                        };
                    };
                    i = i - 1;
                }
            };

            // Withdraw left liquidity
            if (provided_liquidity.left > 0) {
                let payout_left_amount = provided_liquidity.left + fees_earned_left;
                if (bin.balance_left.value() >= payout_left_amount) {
                    result_coin_left.join(bin.balance_left.split(payout_left_amount).into_coin(ctx));
                } else {
                    let remainder = payout_left_amount - bin.balance_left.value();
                    result_coin_left.join(bin.balance_left.withdraw_all().into_coin(ctx));
                    let remainder_in_r = bin.price.mul_u64(remainder);
                    // TODO: clean this up, this is ugly
                    if (bin.balance_right.value() >= remainder_in_r) {
                        result_coin_right.join(bin.balance_right.split(remainder_in_r).into_coin(ctx));
                    } else {
                        result_coin_right.join(bin.balance_right.withdraw_all().into_coin(ctx));
                    };
                };
            };

            // Withdraw right liquidity
            if (provided_liquidity.right > 0) {
                let payout_right_amount = provided_liquidity.right + fees_earned_right;
                if (bin.balance_right.value() >= payout_right_amount) {
                    result_coin_right.join(bin.balance_right.split(payout_right_amount).into_coin(ctx));
                } else {
                    let remainder = payout_right_amount - bin.balance_right.value();
                    result_coin_right.join(bin.balance_right.withdraw_all().into_coin(ctx));
                    let remainder_in_l = bin.price.div_u64(remainder);
                    if (bin.balance_left.value() >= remainder_in_l) {
                        result_coin_left.join(bin.balance_left.split(remainder_in_l).into_coin(ctx));
                    } else {
                        result_coin_left.join(bin.balance_left.withdraw_all().into_coin(ctx));
                    };
                };
            };
        };
        liquidity.destroy_empty();

        // Send the liquidity back to the liquidity provider
        let sender = ctx.sender();
    
        transfer::public_transfer(result_coin_left, sender);
        transfer::public_transfer(result_coin_right, sender);

        // Delete the receipt so liquidity can't be withdrawn twice
        object::delete(receipt_id);
    }

    /// Calculate fee of `fee_bps` basis points.
    fun get_fee(amount: u64, fee_bps: u64): u64 {
        let fee_factor = ufp256::from_fraction(fee_bps as u256, 10000);
        fee_factor.mul_u64(amount)
    }
    
    /// Calculate fee of `fee_bps` basis points, but on the output of a trade: amount/(1-fee) - amount.
    fun get_fee_inv(amount: u64, fee_bps: u64): u64 {
        ufp256::from_fraction((10000 - fee_bps) as u256, 10000)
        .div_u64(amount)
        - amount
    }

    // Swap `coin_left` for an equivalent amount of `R` in `pool`.
    public fun swap_ltr<L, R>(pool: &mut Pool<L, R>, mut coin_left: Coin<L>, clock: &Clock, ctx: &mut TxContext) {
        let mut result_coin = coin::zero<R>(ctx);
        let fee_bps = pool.fee_bps();
        // Keep emptying bins until `coin_left` is fully swapped
        while (coin_left.value() > 0) { 
            let active_bin = pool.get_active_bin_mut();
            let active_bin_right_starting_balance = active_bin.balance_right();

            let mut fee = get_fee(coin_left.value(), fee_bps);

            let mut swap_left = coin_left.value() - fee;
            let mut swap_right = active_bin.price.mul_u64(swap_left);

            let bin_balance_right = active_bin.balance_right();
            if (swap_right > bin_balance_right) {
                // Not enough balance after fees in this bin to fulfill swap.
                swap_right = bin_balance_right;
                swap_left = active_bin.price.div_u64(bin_balance_right);
                fee = get_fee_inv(swap_left, fee_bps);
            };

            // Execute swap
            active_bin.balance_left.join(coin_left.split(swap_left, ctx).into_balance());
            result_coin.join(active_bin.balance_right.split(swap_right).into_coin(ctx));

            // Register fees
            active_bin.balance_left.join(coin_left.split(fee, ctx).into_balance());
            active_bin.fee_log_left.push_back(
                FeeLogEntry {
                    amount: fee,
                    timestamp_ms: clock.timestamp_ms(),
                    total_bin_size: active_bin_right_starting_balance
                }
            );

            // Cross over one bin right if active bin is empty after swap, 
            // abort if swap is not complete and no bins are left 
            if (active_bin.balance_right() == 0) {
                let bin_right_id = pool.active_bin_id + 1;
                if (coin_left.value() > 0) {
                    assert!(pool.bins.contains(&bin_right_id), EInsufficientPoolLiquidity);
                };
                pool.set_active_bin(bin_right_id);
            };
        };
        coin_left.destroy_zero();
        transfer::public_transfer(result_coin, ctx.sender());
    }

    // Swap `coin_right` for an equivalent amount of `L` in `pool`.
    public fun swap_rtl<L, R>(pool: &mut Pool<L, R>, mut coin_right: Coin<R>, clock: &Clock, ctx: &mut TxContext) {
        let mut result_coin = coin::zero<L>(ctx);
        let fee_bps = pool.fee_bps();
        // Keep emptying bins until `coin_right` is fully swapped
        while (coin_right.value() > 0) { 
            let active_bin = pool.get_active_bin_mut();
            let active_bin_left_starting_balance = active_bin.balance_left();

            let mut fee = get_fee(coin_right.value(), fee_bps);

            let mut swap_right = coin_right.value() - fee;
            let mut swap_left = active_bin.price.div_u64(swap_right);

            let bin_balance_left = active_bin.balance_left();
            if (swap_left > bin_balance_left) {
                // Not enough balance after fees in this bin to fulfill swap.
                swap_left = bin_balance_left;
                swap_right = active_bin.price.mul_u64(swap_left);
                fee = get_fee_inv(swap_right, fee_bps);
            };

            // Execute swap
            active_bin.balance_right.join(coin_right.split(swap_right, ctx).into_balance());
            result_coin.join(active_bin.balance_left.split(swap_left).into_coin(ctx));

            // Register fees
            active_bin.balance_right.join(coin_right.split(fee, ctx).into_balance());
            active_bin.fee_log_right.push_back(
                FeeLogEntry {
                    amount: fee,
                    timestamp_ms: clock.timestamp_ms(),
                    total_bin_size: active_bin_left_starting_balance
                }
            );

            // Cross over one bin left if active bin is empty after swap, 
            // abort if swap is not complete and no bins are left 
            if (active_bin.balance_left() == 0) {
                let bin_left_id = pool.active_bin_id - 1;
                if (coin_right.value() > 0) {
                    assert!(pool.bins.contains(&bin_left_id), EInsufficientPoolLiquidity);
                };
                pool.set_active_bin(bin_left_id);
            };
        };
        coin_right.destroy_zero();
        transfer::public_transfer(result_coin, ctx.sender());
    }
}