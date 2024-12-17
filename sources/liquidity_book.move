/// Module: liquidity_book
module iota_rebased_l1dex::liquidity_book {

    use iota::balance::{Self, Balance};
    use iota::vec_map::{Self, VecMap};
    use iota::coin::{Coin};

    use iota_rebased_l1dex::fixed_point_128::{Self, UFP128};

    public struct PoolBin<phantom LEFT, phantom RIGHT> has store {
        price: UFP128,
        balance_left: Balance<LEFT>,
        balance_right: Balance<RIGHT>
    }

    // Get the value of `balance_left` of a bin
    public fun balance_left<LEFT, RIGHT>(bin: &PoolBin<LEFT, RIGHT>): u64 {
        bin.balance_left.value()
    }

    // Get the value of `balance_right` of a bin
    public fun balance_right<LEFT, RIGHT>(bin: &PoolBin<LEFT, RIGHT>): u64 {
        bin.balance_right.value()
    }

    public struct Pool<phantom LEFT, phantom RIGHT> has key, store {
        id: UID,
        bins: VecMap<UFP128, PoolBin<LEFT, RIGHT>>,
        active_price: UFP128,
        bin_step_bps: u64, // The step/delta between bins in basis points (0.0001)
    }

    public entry fun new<LEFT, RIGHT>(
        pair_left: Coin<LEFT>, 
        pair_right: Coin<RIGHT>, 
        bin_step_bps: u64, 
        starting_price_units: u64, 
        starting_price_decimals: u64, 
        ctx: &mut TxContext
    ) {
        let starting_price = fixed_point_128::new(starting_price_units, starting_price_decimals);

        let mut bins = vec_map::empty();
        bins.insert(
            starting_price,
            PoolBin {
                price: starting_price,
                balance_left: balance::zero<LEFT>(),
                balance_right: balance::zero<RIGHT>(),
            }
        );

        // Create and share the pool
        let pool = Pool<LEFT, RIGHT> {
            id: object::new(ctx),
            bins,
            active_price: starting_price,
            bin_step_bps,
        };
        transfer::public_share_object(pool);

        // Cleanup: send back the coins
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(pair_left, sender);
        transfer::public_transfer(pair_right, sender);
    }

    fun get_active_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>): UFP128 {
        pool.active_price
    }

    public fun get_active_bin<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>): &PoolBin<LEFT, RIGHT>{
        pool.bins.get(&pool.active_price)
    }

    fun get_active_bin_mut<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>): &mut PoolBin<LEFT, RIGHT>{
        let active_price = pool.active_price;
        pool.bins.get_mut(&active_price)
    }

    public fun get_bin<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, price: &UFP128): &PoolBin<LEFT, RIGHT>{
        pool.bins.get(price)
    }

    fun get_bin_mut<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, price: &UFP128): &mut PoolBin<LEFT, RIGHT>{
        pool.bins.get_mut(price)
    }

    public fun bin_prev_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, bin: &PoolBin<LEFT, RIGHT>): UFP128 {
        let bin_price_factor = fixed_point_128::from_fraction(10000 + pool.bin_step_bps, 10000);
        bin.price.div(bin_price_factor)
    }

    public fun bin_next_price<LEFT, RIGHT>(pool: &Pool<LEFT, RIGHT>, bin: &PoolBin<LEFT, RIGHT>): UFP128 {
        let bin_price_factor = fixed_point_128::from_fraction(10000 + pool.bin_step_bps, 10000);
        bin.price.mul(bin_price_factor)
    }

    // Add a bin to a pool at a particular price
    fun add_bin<LEFT, RIGHT>(pool: &mut Pool<LEFT, RIGHT>, price: UFP128) {
        pool.bins.insert(price, PoolBin {
            price,
            balance_left: balance::zero<LEFT>(),
            balance_right: balance::zero<RIGHT>(),
        })
    }

    // Add liquidity to the pool around the active bin with an equal 
    // distribution amongst those bins
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

        let bin_count_half = bin_count / 2;
        let bin_price_factor = fixed_point_128::from_fraction(10000 + pool.bin_step_bps, 10000);

        // Add left bins
        let coin_left_per_bin = coin_left.value() / (bin_count_half + 1);
        let mut last_bin = pool.get_active_bin();
        1u64.range_do_eq!(bin_count_half, |_| {
            let new_bin_price = pool.bin_prev_price(last_bin);
            add_bin(pool, new_bin_price);
            pool.get_bin_mut(&new_bin_price).balance_left.join(coin_left.split(coin_left_per_bin, ctx).into_balance());
            last_bin = pool.get_bin(&new_bin_price);
        });
        pool.get_active_bin_mut().balance_left.join(coin_left.into_balance());

        // Add right bins
        let coin_right_per_bin = coin_right.value() / (bin_count_half + 1);
        let mut last_bin = pool.get_active_bin();
        1u64.range_do_eq!(bin_count_half, |n| {
            let new_bin_price = pool.bin_next_price(last_bin);
            add_bin(pool, new_bin_price);
            pool.bins.get_mut(&new_bin_price).balance_right.join(coin_right.split(coin_right_per_bin, ctx).into_balance());
            last_bin = pool.get_bin(&new_bin_price);
        });
        pool.get_active_bin_mut().balance_right.join(coin_right.into_balance());    
    }
}