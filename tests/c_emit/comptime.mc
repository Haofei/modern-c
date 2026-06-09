fn pure_comptime_block() -> u32 {
    comptime {
        let x: u32 = 1;
        assert(true);
    }
    return 1;
}

fn pure_comptime_nested_block() -> u32 {
    comptime {
        {
            let x: u32 = 2;
            assert(x == 2);
        }
    }
    return 2;
}
