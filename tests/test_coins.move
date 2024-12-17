#[test_only]
module iota_rebased_l1dex::test_coins {
    const ENotImplemented: u64 = 0;

    use iota::coin::{Self, Coin};

    public struct TEST_LEFT has drop {}
    public struct TEST_RIGHT has drop {}

    fun create_l(ctx: &mut TxContext, amount: u64): Coin<TEST_LEFT> {
        let (mut cap, metadata) = coin::create_currency(TEST_LEFT {}, 6, b"MY_COIN", b"", b"", option::none(), ctx);
        let coin_left = coin::mint(&mut cap, amount, ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(cap, ctx.sender());
        coin_left
    }

    fun create_r(ctx: &mut TxContext, amount: u64): Coin<TEST_RIGHT> {
        let (mut cap, metadata) = coin::create_currency(TEST_RIGHT {}, 6, b"MY_COIN", b"", b"", option::none(), ctx);
        let coin_right = coin::mint(&mut cap, amount, ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(cap, ctx.sender());
        coin_right
    }
}
