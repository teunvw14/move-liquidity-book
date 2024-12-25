/// Module: liquidity_book
module l1dex::liquidity_book {

    use iota::balance::{Self, Balance};
    use iota::vec_map::{Self, VecMap};
    use iota::coin::{Self, Coin};

    use l1dex::ufp256::{Self, UFP256};

    const MAX_U64: u64 = 18446744073709551615; // 2^64 - 1
    // The protocol base fee in basis points (0.2%)
    const BASE_FEE_BPS: u64 = 20;

    // Errors
    const EInsufficientPoolLiquidity: u64 = 1;

    // Structs

    /// Liquidity Book trading pool type.
    public struct Pool<phantom LEFT, phantom RIGHT> has key, store {
        id: UID,
        bins: VecMap<u64, PoolBin<LEFT, RIGHT>>, // bins are identified with a unique id
        active_bin_id: u64,
        bin_step_bps: u64, // The step/delta between bins in basis points (0.0001)
    }


    /// Bin type for a Liquidity Book trading pool.
    public struct PoolBin<phantom LEFT, phantom RIGHT> has store {
        price: UFP256,
        balance_left: Balance<LEFT>,
        balance_right: Balance<RIGHT>
    }

    /// A struct representing liquidity provided in a specific bin with amounts
    /// `left` of `Coin<LEFT>` and `right` of `Coin<RIGHT>`.
    public struct BinProvidedLiquidity has store {
        bin_id: u64,
        left: u64,
        right: u64
    }

    /// Receipt given to liquidity providers when they provide liquidity. Can be
    /// used to withdraw provided liquidity.
    public struct LiquidityProviderReceipt has key, store {
        id: UID,
        liquidity: vector<BinProvidedLiquidity>
    }

    /// Create a new Liquidity Book `Pool`
    public entry fun new<LEFT, RIGHT>(
        bin_step_bps: u64, 
        starting_price_mantissa: u256,
        ctx: &mut TxContext
    ) {
        let starting_price = ufp256::new(starting_price_mantissa);
        let starting_bin = PoolBin {
                price: starting_price,
                balance_left: balance::zero<LEFT>(),
                balance_right: balance::zero<RIGHT>(),
        };
        let starting_bin_id = MAX_U64 / 2;
        let mut bins = vec_map::empty();
        bins.insert(
            starting_bin_id,
            starting_bin
        );

        // Create and share the pool
        let pool = Pool<LEFT, RIGHT> {
            id: object::new(ctx),
            bins,
            active_bin_id: starting_bin_id,
            bin_step_bps,
        };
        transfer::public_share_object(pool);
    }

    fun get_active_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>): UFP256 {
        pool.get_active_bin().price
    }

    public fun get_active_bin_id<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>): u64{
        pool.active_bin_id
    }

    public fun get_active_bin<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>): &PoolBin<LEFT, RIGHT>{
        pool.get_bin(&pool.active_bin_id)
    }

    fun get_active_bin_mut<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>): &mut PoolBin<LEFT, RIGHT>{
        pool.bins.get_mut(&pool.active_bin_id)
    }

    /// Set `pool` active bin
    fun set_active_bin<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, id: u64) {
        if (pool.bins.contains(&id)) {
            pool.active_bin_id = id;
        }
    }

    /// Get a reference to a bin from a bin `id`
    public fun get_bin<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, id: &u64): &PoolBin<LEFT, RIGHT>{
        let bin = pool.bins.get(id);
        bin
    }

    public fun get_closest_bin<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, price: UFP256): u64{
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

    fun get_bin_mut<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, id: u64): &mut PoolBin<LEFT, RIGHT>{
        pool.bins.get_mut(&id)
    }

    // public fun bin_prev_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, bin_id: u64): ufp256 {
    //     let bin_price_factor = ufp256::from_fraction(10000 + pool.bin_step_bps, 10000);
    //     // use mul, pow_neg(1) for consistency with bin creation
    //     bin.price.mul(bin_price_factor.pow_neg(1))
    // }

    // public fun bin_next_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, bin: &PoolBin<LEFT, RIGHT>): ufp256 {
    //     let bin_price_factor = ufp256::from_fraction(10000 + pool.bin_step_bps, 10000);
    //     // use mul, pow(1) for consistency with bin creation
    //     bin.price.mul(bin_price_factor.pow(1))
    // }

    /// Add a bin to a pool at a particular price if it doesn't exist yet
    fun add_bin<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, id: u64, price: UFP256) {
        if (!pool.bins.contains(&id)) {
            pool.bins.insert(id, PoolBin {
                price,
                balance_left: balance::zero<LEFT>(),
                balance_right: balance::zero<RIGHT>(),
            });
        };
    }

    /// Get the value of `price` of a bin
    public fun price<LEFT, RIGHT>(bin: &PoolBin<LEFT, RIGHT>): UFP256 {
        bin.price
    }

    /// Get the value of `balance_left` of a bin
    public fun balance_left<LEFT, RIGHT>(bin: &PoolBin<LEFT, RIGHT>): u64 {
        bin.balance_left.value()
    }

    /// Get the value of `balance_right` of a bin
    public fun balance_right<LEFT, RIGHT>(bin: &PoolBin<LEFT, RIGHT>): u64 {
        bin.balance_right.value()
    }

    /// Add liquidity to the pool around the active bin with an equal 
    /// distribution amongst those bins
    public entry fun add_liquidity_linear<LEFT, RIGHT>(
        pool: &mut Pool<LEFT, RIGHT>, 
        bin_count: u64, 
        mut coin_left: Coin<LEFT>, 
        mut coin_right: Coin<RIGHT>,
        ctx: &mut TxContext
    ) {
        // An uneven number of bins is required, so that, including the active
        // bin, there is liquidity added to an equal amount of bins to the left
        // and right of the active bins
        assert!(bin_count % 2 == 1);

        // Assert some minimal amount of liquidity is added
        assert!(coin_left.value() > 0 || coin_right.value() > 0);

        let active_bin_id_id = pool.get_active_bin_id();
        let bin_count_half = bin_count / 2;
        let bin_price_factor = ufp256::from_fraction((10000 + pool.bin_step_bps) as u256, 10000u256);

        let mut receipt = LiquidityProviderReceipt {
            id: object::new(ctx),
            liquidity: vector::empty()
        };

        // Add left bins
        let coin_left_per_bin = coin_left.value() / (bin_count_half + 1);
        1u64.range_do_eq!(bin_count_half, |n| {
            let new_bin_price = pool.get_active_price().mul(bin_price_factor.pow_neg(n));
            let new_bin_id = active_bin_id_id-n;
            pool.add_bin(new_bin_id, new_bin_price);

            // Add balance to new bin
            let balance_for_bin = coin_left.split(coin_left_per_bin, ctx).into_balance();
            pool.get_bin_mut(new_bin_id).balance_left.join(balance_for_bin);

            // Update receipt
            receipt.liquidity.push_back(BinProvidedLiquidity{
                bin_id: new_bin_id,
                left: coin_left_per_bin,
                right: 0
            });
        });
        let coin_left_leftover_value = coin_left.value();
        pool.get_active_bin_mut().balance_left.join(coin_left.into_balance());

        // Add right bins
        let coin_right_per_bin = coin_right.value() / (bin_count_half + 1);
        1u64.range_do_eq!(bin_count_half, |n| {
            let new_bin_price = pool.get_active_price().mul(bin_price_factor.pow(n));
            let new_bin_id = active_bin_id_id+n;
            pool.add_bin(new_bin_id, new_bin_price);

            // Add balance to new bin
            let balance_for_bin = coin_right.split(coin_right_per_bin, ctx).into_balance();
            pool.get_bin_mut(new_bin_id).balance_right.join(balance_for_bin);

            // Update receipt
            receipt.liquidity.push_back(BinProvidedLiquidity{
                bin_id: new_bin_id,
                left: 0,
                right: coin_right_per_bin
            });
        });
        let coin_right_leftover_value = coin_right.value();
        pool.get_active_bin_mut().balance_right.join(coin_right.into_balance());

        // Update receipt for liquidity provided in the pool.active_bin
        receipt.liquidity.push_back(BinProvidedLiquidity{
            bin_id: pool.get_active_bin_id(),
            left: coin_left_leftover_value,
            right: coin_right_leftover_value
        });

        // Give receipt
        transfer::transfer(receipt, ctx.sender());
    }

    /// Apply fee of `fee_bps` basis points to the output of the trade
    fun apply_fee_out(amount: u64, fee_bps: u64): u64 {
        let fee_factor = ufp256::from_fraction((10000 - fee_bps) as u256, 10000u256);
        fee_factor.mul_u64(amount)
    }

    /// Apply fee of `fee_bps` basis points to the input of the trade
    fun apply_fee_in(amount: u64, fee_bps: u64): u64 {
        let fee_factor = ufp256::from_fraction((10000 + fee_bps) as u256, 10000u256);
        fee_factor.mul_u64(amount)
    }

    public entry fun swap_ltr<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, mut coin_left: Coin<LEFT>, ctx: &mut TxContext) {
        let mut result_coin = coin::zero<RIGHT>(ctx);
        while (coin_left.value() > 0) { 
            let active_bin = pool.get_active_bin_mut();

            let mut swap_left = coin_left.value();
            let mut swap_right = apply_fee_out(active_bin.price.mul_u64(swap_left), BASE_FEE_BPS);

            let bin_balance_right = active_bin.balance_right();
            if (swap_right > bin_balance_right) {
                // Not enough balance after fees in this bin to fulfill swap.
                // Because we can only trade `bin_balance_right` inside this bin,
                // we apply fees by increasing the `left` paid for this portion
                // of the swap.
                swap_left = apply_fee_in(active_bin.price.div_u64(bin_balance_right), BASE_FEE_BPS);
                swap_right = bin_balance_right;
            };

            // Execute swap
            active_bin.balance_left.join(coin_left.split(swap_left, ctx).into_balance());
            result_coin.join(active_bin.balance_right.split(swap_right).into_coin(ctx));

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

    public entry fun swap_rtl<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, mut coin_right: Coin<RIGHT>, ctx: &mut TxContext) {
        let mut result_coin = coin::zero<LEFT>(ctx);
        while (coin_right.value() > 0) { 
            let active_bin = pool.get_active_bin_mut();

            let mut swap_right = coin_right.value();
            let mut swap_left = apply_fee_out(active_bin.price.div_u64(swap_right), BASE_FEE_BPS);

            let bin_balance_left = active_bin.balance_left();
            if (swap_left > bin_balance_left) {
                // Not enough balance after fees in this bin to fulfill swap.
                // Because we can only trade `bin_balance_left` inside this bin,
                // we apply fees by increasing the `left` paid for this portion
                // of the swap.
                swap_right = apply_fee_in(active_bin.price.mul_u64(bin_balance_left), BASE_FEE_BPS);
                swap_left = bin_balance_left;
            };

            // Execute swap
            active_bin.balance_right.join(coin_right.split(swap_right, ctx).into_balance());
            result_coin.join(active_bin.balance_left.split(swap_left).into_coin(ctx));

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