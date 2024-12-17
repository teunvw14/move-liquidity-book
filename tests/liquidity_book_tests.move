#[test_only]
module iota_rebased_l1dex::liquidity_book_tests {
    use iota::test_scenario as ts;
    use iota::coin::{Self, Coin};

    use iota_rebased_l1dex::liquidity_book;
    use iota_rebased_l1dex::fixed_point_128::{Self, UFP128};
    

    const ENotImplemented: u64 = 0;

    public struct TEST_LEFT has drop {}
    public struct TEST_RIGHT has drop {}

    #[test]
    fun setup_pool() {
        let adm_adr = @0x11;
        let lp_adr = @0x12;

        let mut ts = ts::begin(adm_adr);

        let starting_price = fixed_point_128::from_fraction(1, 2);

        // Create pool
        {
            ts.next_tx(adm_adr);
            // Create 10 billion of each coin
            let coin_left = coin::mint_for_testing<TEST_LEFT>(0, ts.ctx());
            let coin_right = coin::mint_for_testing<TEST_RIGHT>(0, ts.ctx());
            liquidity_book::new(
                coin_left, 
                coin_right, 
                20, 
                starting_price.units(),
                starting_price.decimals(), 
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
            // Add liquidity with 5 bins holding TEST_LEFT, and 5 holding TEST_RIGHT
            pool.add_liquidity_linear(9, coin_left, coin_right, ts.ctx());
            
            let active_bin = pool.get_active_bin();
            assert!(active_bin.balance_left() == coin_amount / 5);
            assert!(active_bin.balance_right() == coin_amount / 5);

            // std::debug::print(&pool);

            let prev_price = pool.bin_prev_price(active_bin);
            // std::debug::print(&prev_price);
            let bin_left_1 = pool.get_bin(&prev_price);
            assert!(bin_left_1.balance_left() == coin_amount / 5);
            assert!(bin_left_1.balance_right() == 0);


            ts::return_shared(pool);
        };

        ts.end();
    }


}
