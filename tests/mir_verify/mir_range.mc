fn accumulate(a: u32, b: u32) -> u32 {
    var sum: u32 = a;
    #[unsafe_contract(no_overflow)]
    {
        sum = unchecked.add(sum, b);
    }
    return sum;
}
