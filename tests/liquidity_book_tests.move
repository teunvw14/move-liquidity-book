#[test_only]
module l1dex::liquidity_book_tests {
    use iota::test_scenario as ts;
    use iota::coin::{Self, Coin};
    use iota::test_utils;
    use iota::test_utils::assert_eq;
    use iota::clock;

    use l1dex::liquidity_book::{Self, Pool, LiquidityProviderReceipt};
    use l1dex::ufp256::{Self};
    
    public struct LEFT has drop {}
    public struct RIGHT has drop {}

    #[test]
    fun pool_full_lifecycle() {
        let adm_adr = @0x11;
        let lp_adr = @0x12;
        let trd_adr = @0x13;

        let mut ts = ts::begin(adm_adr);

        // Start with price R = 0.5L
        let starting_price = ufp256::from_fraction(1, 2);
        let liquidity_provided_amount =  10u64.pow(10);

        let clock = clock::create_for_testing(ts.ctx());

        // Create pool
        {
            ts.next_tx(adm_adr);
            liquidity_book::new<LEFT, RIGHT>(
                20, 
                starting_price.mantissa(),
                20,
                ts.ctx()
            );
        };

        // Add liquidity
        {
            ts.next_tx(lp_adr);

            // Create 10 billion of both LEFT and RIGHT to deposit
            let coin_left = coin::mint_for_testing<LEFT>(liquidity_provided_amount, ts.ctx());
            let coin_right = coin::mint_for_testing<RIGHT>(liquidity_provided_amount, ts.ctx());

            let mut pool: Pool<LEFT, RIGHT> = ts.take_shared();

            // Add liquidity with 5 bins holding LEFT, and 5 holding 
            // RIGHT. Creates 4 bins left of the active bin, and 4 bins to
            // the right.
            let bin_count = 11;
            pool.add_liquidity_uniformly(bin_count, coin_left, coin_right, &clock, ts.ctx());
            
            let active_bin = pool.get_active_bin();
            let distinct_bins = ((bin_count - 1)/ 2) + 1;
            let coin_active_bin_amount = liquidity_provided_amount - ((distinct_bins-1) *  (liquidity_provided_amount / distinct_bins));
            assert_eq(active_bin.balance_left(), coin_active_bin_amount);
            assert_eq(active_bin.balance_right(), coin_active_bin_amount);


            let bin_left_1 = pool.get_bin(&(pool.get_active_bin_id() - 1));
            assert_eq(bin_left_1.balance_left(), liquidity_provided_amount / distinct_bins);
            assert_eq(bin_left_1.balance_right(), 0);

            ts::return_shared(pool);
        };

        // Make swap (left to right)
        {
            ts.next_tx(trd_adr);
            
            // Trade 5 LEFT for RIGHT (leaving 15 LEFT and 7.5 RIGHT)
            let coin_amount = 5 * 10u64.pow(9);
            let coin_left = coin::mint_for_testing<LEFT>(coin_amount, ts.ctx());

            // test_utils::print(b"Trading LEFT amount:");
            // std::debug::print(&coin_left.value());

            let mut pool: Pool<LEFT, RIGHT> = ts.take_shared();
            pool.swap_ltr(coin_left, &clock, ts.ctx());

            // Complete transaction to see swap effects
            ts.next_tx(trd_adr);
            let coin_right = ts.take_from_address<Coin<RIGHT>>(trd_adr);

            test_utils::print(b"Got RIGHT amount:");
            std::debug::print(&coin_right.value());

            ts::return_to_address(trd_adr, coin_right);
            ts::return_shared(pool);
        };

        // Make swap (right to left)
        {
            ts.next_tx(trd_adr);
            
            // Trade 7 RIGHT for LEFT
            let coin_amount = 7 * 10u64.pow(9);
            let coin_right = coin::mint_for_testing<RIGHT>(coin_amount, ts.ctx());

            // test_utils::print(b"Trading RIGHT amount:");
            // std::debug::print(&coin_right.value());

            let mut pool: Pool<LEFT, RIGHT> = ts.take_shared();

            pool.swap_rtl(coin_right, &clock, ts.ctx());

            // Complete transaction to see swap effects
            ts.next_tx(trd_adr);
            let coin_left = ts.take_from_address<Coin<LEFT>>(trd_adr);

            // test_utils::print(b"Got LEFT amount:");
            // std::debug::print(&coin_left.value());

            ts::return_to_address(trd_adr, coin_left);
            ts::return_shared(pool);
        };

        // Withdraw liquidity
        ts.next_tx(lp_adr);
        {
            let mut pool: Pool<LEFT, RIGHT> = ts.take_shared();
            std::debug::print(&pool);

            let receipt = ts.take_from_address<LiquidityProviderReceipt>(lp_adr);
            pool.withdraw_liquidity(receipt, ts.ctx());

            // Go to next transaction to see withdrawal effects
            ts.next_tx(lp_adr); 
            let coin_left = ts.take_from_address<Coin<LEFT>>(lp_adr);
            let coin_right = ts.take_from_address<Coin<RIGHT>>(lp_adr);

            let starting_value_as_l = liquidity_book::amount_as_l(starting_price, liquidity_provided_amount, liquidity_provided_amount);
            let ending_value_as_l = liquidity_book::amount_as_l(pool.get_active_price(), coin_left.value(), coin_right.value());
            test_utils::print(b"Starting value:");
            std::debug::print(&starting_value_as_l);
            test_utils::print(b"Ending value:");
            std::debug::print(&ending_value_as_l);



            std::debug::print(&pool.get_active_price());
            test_utils::print(b"Withdrew L:");
            std::debug::print(&coin_left);
            test_utils::print(b"Withdrew R:");
            std::debug::print(&coin_right);

            ts::return_to_address(lp_adr, coin_left);
            ts::return_to_address(lp_adr, coin_right);
            // std::debug::print(&pool);
            ts::return_shared(pool);
        };

        clock.destroy_for_testing();
        ts.end();
    }
}
