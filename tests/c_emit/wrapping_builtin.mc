// The explicit `wrapping.add` builtin (modular addition, no trap edge) lowers
// to plain C `+`, the same as `a + b` on `wrap<T>` operands.

#[no_lang_trap]
fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return wrapping.add(a, b);
}
