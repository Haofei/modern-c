// MC standard library — `sort`: in-place, allocation-free sorting and ordered search over a
// slice. Insertion sort (stable, in-place, no recursion, no scratch buffer) suits the small
// bounded arrays kernel code sorts; there is no heap dependency, so it is usable anywhere.
//
// Two layers:
//   - concrete `*_u32` helpers for the common ascending-unsigned case (built-in `<`, no
//     comparator to construct);
//   - generic `sort`/`is_sorted`/`lower_bound` taking a `closure(T, T) -> bool` "less-than"
//     for any element type and ordering (mirrors std/scan's predicate-closure style).
// Slice params are `[]mut` so a mutable working buffer (the common kernel case) passes
// directly to sort and to the read-only queries without an explicit mut->const view cast.
//
// Sorting copies elements, so the element type must be copyable (not a linear `move` type).

// ----- concrete: ascending u32 -----

// Ascending in-place insertion sort of a u32 slice.
export fn sort_u32(xs: []mut u32) -> void {
    let n: usize = xs.len;
    var i: usize = 1;
    while i < n {
        let key: u32 = xs[i];
        var j: usize = i;
        while j > 0 {
            if xs[j - 1] <= key {
                break;
            }
            xs[j] = xs[j - 1];
            j = j - 1;
        }
        xs[j] = key;
        i = i + 1;
    }
}

// True if `xs` is in non-decreasing order.
export fn is_sorted_u32(xs: []mut u32) -> bool {
    let n: usize = xs.len;
    var i: usize = 1;
    while i < n {
        if xs[i] < xs[i - 1] {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// Binary search a sorted (ascending) u32 slice. Returns the index of `key`, or `xs.len`
// if absent. Half-open [lo, hi) bisection, overflow-safe midpoint.
export fn binary_search_u32(xs: []mut u32, key: u32) -> usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while lo < hi {
        let mid: usize = lo + (hi - lo) / 2;
        let v: u32 = xs[mid];
        if v == key {
            return mid;
        }
        if v < key {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return xs.len;
}

// ----- generic: any element + ordering via a `less` comparator -----

// Ascending in-place insertion sort of `xs` under the strict-weak ordering `less`
// (`less(a, b)` == "a comes before b"). Stable: equal elements keep their input order.
export fn sort(comptime T: type, xs: []mut T, less: closure(T, T) -> bool) -> void {
    let n: usize = xs.len;
    var i: usize = 1;
    while i < n {
        let key: T = xs[i];
        var j: usize = i;
        while j > 0 {
            if !less(key, xs[j - 1]) {
                break;
            }
            xs[j] = xs[j - 1];
            j = j - 1;
        }
        xs[j] = key;
        i = i + 1;
    }
}

// True if `xs` is ordered under `less` (no element comes before its predecessor).
export fn is_sorted(comptime T: type, xs: []mut T, less: closure(T, T) -> bool) -> bool {
    let n: usize = xs.len;
    var i: usize = 1;
    while i < n {
        if less(xs[i], xs[i - 1]) {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// First index `i` in a `less`-sorted `xs` where `!less(xs[i], key)` — the insertion point
// for `key` (the standard lower bound). Returns `xs.len` if every element precedes `key`.
export fn lower_bound(comptime T: type, xs: []mut T, key: T, less: closure(T, T) -> bool) -> usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while lo < hi {
        let mid: usize = lo + (hi - lo) / 2;
        if less(xs[mid], key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}
