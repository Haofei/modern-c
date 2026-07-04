// Generated container typedefs (slices, arrays, Result) reference user structs,
// and structs embed those containers, so the emitter must order all of them by
// dependency. Forward declarations cover pointer references (slices); by-value
// embedding (array-of-struct, struct-in-struct) is emitted after its members.

struct Inner { x: u32 }

// slice-of-struct: the slice's `Inner *` field resolves via the forward decl.
fn slice_of_struct(xs: []const Inner) -> u32 {
    return xs.len;
}

extern fn make_inner_slice() -> []const Inner;

fn consume_inner(inner: Inner) -> u32 {
    return inner.x;
}

fn inferred_call_slice_element() -> u32 {
    let inner = make_inner_slice()[0];
    return consume_inner(inner);
}

// array-of-struct: the array typedef embeds `Inner` by value, so `Inner` must
// be fully defined first.
fn array_of_struct(xs: [4]Inner) -> u32 {
    return xs[0].x;
}

// Struct embedding an array-of-struct by value and a slice-of-struct: requires
// Inner -> array-of-Inner -> Mid ordering, with the slice available too.
struct Mid { items: [3]Inner, count: u32 }
struct Outer { mid: Mid, tags: []const Inner }

fn nested(o: Outer) -> u32 {
    return o.mid.count;
}

// Struct with a plain scalar array field (regression guard for the common case).
struct Buffer { data: [8]u32, len: u32 }

fn scalar_array_field(b: Buffer) -> u32 {
    return b.len;
}

// Slice of an array: the slice's element pointer is `mc_array_..._N *`, which
// the array forward declaration must cover.
fn slice_of_array(rows: [][4]u32) -> u32 {
    return rows.len;
}

// Nested (multidimensional) array indexing: each dimension indexes `.elems`
// with its own bounds check.
fn nested_index(m: [2][3]u32) -> u32 {
    return m[0][0];
}
