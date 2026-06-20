import "std/sort.mc";

#[test]
export fn sorts_u32_ascending() -> u32 {
    var a: [6]u32 = .{ 5, 3, 8, 1, 9, 2 };
    sort_u32(a[0..6]);
    assert(a[0] == 1);
    assert(a[3] == 5);
    assert(a[5] == 9);
    assert(is_sorted_u32(a[0..6]));
    return 1;
}

#[test]
export fn binary_search_finds_and_misses() -> u32 {
    var a: [6]u32 = .{ 1, 2, 3, 5, 8, 9 };
    assert(binary_search_u32(a[0..6], 8) == 4);
    assert(binary_search_u32(a[0..6], 1) == 0);
    assert(binary_search_u32(a[0..6], 7) == 6);
    return 1;
}

// Generic sort with a custom ordering via a comparator closure. The closure CAPTURES the
// sort direction in its env, so one comparator function serves both orders.
struct SortDir {
    descending: u32,
}

global g_sort_dir: SortDir;

fn ordered(dir: *mut SortDir, a: u32, b: u32) -> bool {
    if dir.descending != 0 {
        return a > b; // "a before b" iff a > b => descending
    }
    return a < b; // ascending
}

#[test]
export fn generic_sort_descending() -> u32 {
    g_sort_dir.descending = 1;
    var a: [5]u32 = .{ 1, 4, 2, 5, 3 };
    let cmp: closure(u32, u32) -> bool = bind(&g_sort_dir, ordered);
    sort(u32, a[0..5], cmp);
    assert(a[0] == 5);
    assert(a[1] == 4);
    assert(a[4] == 1);
    return 1;
}
