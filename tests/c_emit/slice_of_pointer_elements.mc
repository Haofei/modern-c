// A slice whose elements are pointers. `supportsType` always admitted the
// type; the read is what the C backend declined, because the race-tolerant
// slice load had no scalar helper for a pointer element. A thin pointer is a
// `usize`-wide scalar, so it loads through `mc_race_load_usize` and is cast
// back to the element's own pointer type.

fn read_slice_of_pointers(items: []*mut u32, index: usize) -> *mut u32 {
    return items[index];
}

fn read_through_slice_of_pointers(items: []*mut u32, index: usize) -> u32 {
    let p: *mut u32 = items[index];
    unsafe { return p.*; }
}

fn read_slice_of_const_pointers(items: []const *const u32, index: usize) -> *const u32 {
    return items[index];
}

fn pass_slice_of_pointers(items: []*mut u32) -> usize {
    return items.len;
}

// Constructing a slice whose elements are pointers. The body renderer used to
// spell the constructed slice's type inline, which is a C identifier only for
// a primitive element; it names the same mangled typedef the declaration
// collector frames now.
fn range_slice_of_pointers(items: []*mut u32, start: usize, end: usize) -> []*mut u32 {
    return items[start..end];
}
