#[test_only]
module l1dex::liquidity_book_tests {
    use iota::test_scenario as ts;
    use iota::coin::{Self, Coin};
    use iota::test_utils;

    use l1dex::liquidity_book;
    use l1dex::ufp256::{Self};
    
    public struct TEST_LEFT has drop {}
    public struct TEST_RIGHT has drop {}

    #[test]
    fun pool_full_lifecycle() {
        let adm_adr = @0x11;
        let lp_adr = @0x12;
        let trd_adr = @0x13;

        let mut ts = ts::begin(adm_adr);

        let starting_price = ufp256::from_fraction(1, 2);

        // Create pool
        {
            ts.next_tx(adm_adr);
            liquidity_book::new<TEST_LEFT, TEST_RIGHT>(
                20, 
                starting_price.mantissa(),
                ts.ctx()
            );
        };

        // Add liquidity
        {
            ts.next_tx(lp_adr);

            // Create 10 billion of both TEST_LEFT and TEST_RIGHT to deposit
            let coin_amount = 10u64.pow(10);
            let coin_left = coin::mint_for_testing<TEST_LEFT>(coin_amount, ts.ctx());
            let coin_right = coin::mint_for_testing<TEST_RIGHT>(coin_amount, ts.ctx());

            let mut pool: liquidity_book::Pool<TEST_LEFT, TEST_RIGHT> = ts.take_shared();

            // Add liquidity with 5 bins holding TEST_LEFT, and 5 holding 
            // TEST_RIGHT. Creates 4 bins left of the active bin, and 4 bins to
            // the right.
            let bin_count = 9;
            pool.add_liquidity_linear(bin_count, coin_left, coin_right, ts.ctx());
            
            let active_bin = pool.get_active_bin();
            let distinct_bins = ((bin_count + 1) / 2);
            assert!(active_bin.balance_left() == coin_amount / distinct_bins);
            assert!(active_bin.balance_right() == coin_amount / distinct_bins);

            // std::debug::print(&pool);

            // std::debug::print(&prev_price);
            let bin_left_1 = pool.get_bin(&(pool.get_active_bin_id() - 1));
            assert!(bin_left_1.balance_left() == coin_amount / distinct_bins);
            assert!(bin_left_1.balance_right() == 0);

            ts::return_shared(pool);

            // Complete transaction to get receipt
            ts.next_tx(lp_adr);

            let receipt = ts.take_from_address<liquidity_book::LiquidityProviderReceipt>(lp_adr);
            // std::debug::print(&receipt);

            ts::return_to_address(lp_adr, receipt);
        };

        // Make swap (left to right)
        {
            ts.next_tx(trd_adr);
            
            // Trade 5 LEFT for RIGHT
            let coin_amount = 5 * 10u64.pow(9);
            let coin_left = coin::mint_for_testing<TEST_LEFT>(coin_amount, ts.ctx());

            // test_utils::print(b"Trading LEFT amount:");
            // std::debug::print(&coin_left.value());

            let mut pool: liquidity_book::Pool<TEST_LEFT, TEST_RIGHT> = ts.take_shared();
            pool.swap_ltr(coin_left, ts.ctx());

            // Complete transaction to see swap effects
            ts.next_tx(trd_adr);
            let coin_right = ts.take_from_address<Coin<TEST_RIGHT>>(trd_adr);

            // test_utils::print(b"Got RIGHT amount:");
            // std::debug::print(&coin_right.value());

            ts::return_to_address(trd_adr, coin_right);
            ts::return_shared(pool);
        };

        // Make swap (right to left)
        {
            ts.next_tx(trd_adr);
            
            // Trade 7 RIGHT for LEFT
            let coin_amount = 7 * 10u64.pow(9);
            let coin_right = coin::mint_for_testing<TEST_RIGHT>(coin_amount, ts.ctx());

            // test_utils::print(b"Trading RIGHT amount:");
            // std::debug::print(&coin_right.value());

            let mut pool: liquidity_book::Pool<TEST_LEFT, TEST_RIGHT> = ts.take_shared();
            pool.swap_rtl(coin_right, ts.ctx());

            // Complete transaction to see swap effects
            ts.next_tx(trd_adr);
            let coin_left = ts.take_from_address<Coin<TEST_LEFT>>(trd_adr);

            // test_utils::print(b"Got LEFT amount:");
            // std::debug::print(&coin_left.value());

            ts::return_to_address(trd_adr, coin_left);
            ts::return_shared(pool);
        };

        ts.end();
    }


}
