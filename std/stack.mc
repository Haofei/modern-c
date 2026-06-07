// MC standard library — `stack`: a generic fixed-capacity stack, the first
// container built on user-defined generics (section 22). `Stack<T>` and its
// operations are generic over the element type; each `import`ing module
// monomorphizes the instantiations it uses. Capacity is a fixed 8 for this v0
// (a `comptime CAP` capacity is a natural follow-on).

struct Stack<T> {
    items: [8]T,
    len: usize,
}

// Push `x`, returning the updated stack (value semantics). Overflows the fixed
// capacity are a bounds trap.
fn push(comptime T: type, s: Stack<T>, x: T) -> Stack<T> {
    var result: Stack<T> = s;
    result.items[result.len] = x;
    result.len = result.len + 1;
    return result;
}

// Element at index `i` (bounds-checked).
fn get(comptime T: type, s: Stack<T>, i: usize) -> T {
    return s.items[i];
}

fn len(comptime T: type, s: Stack<T>) -> usize {
    return s.len;
}

fn is_empty(comptime T: type, s: Stack<T>) -> bool {
    return s.len == 0;
}
