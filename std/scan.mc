// MC standard library — `scan`: bounded array search with a predicate closure, so the
// ubiquitous `var i=0; while i<N { if pred { return i } i+=1 } return N` loop is written
// once. The predicate is a `closure` (bind a captured target/state), making the search
// intent explicit. (Scans with side effects or multi-array checks keep their own loops.)

// First index i in arr[0..N] where pred(arr[i]) holds, or N if none match.
export fn find_index(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -> bool) -> usize {
    var i: usize = 0;
    while i < N {
        if pred(arr[i]) {
            return i;
        }
        i = i + 1;
    }
    return N;
}

// True if any element satisfies the predicate.
export fn any(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -> bool) -> bool {
    return find_index(T, N, arr, pred) < N;
}
