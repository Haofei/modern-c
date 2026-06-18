// Runtime proof for nullable trait objects (`?*dyn Trait`, docs/spec §32.7), executed as
// a native binary on BOTH backends by tools/exec/nullable-dyn-run.sh (`zig build nulldyn-run-test`).
//
// `run()` returns a checksum that is correct ONLY if the niche round-trips at runtime:
//   - slot0 = &a0 (some), slot1 = null (none), slot2 = &a2 (some), slot3 = null (none),
//     all written into array MEMORY and read back;
//   - some-slots dispatch through the vtable (100 + 300), none-slots take the else (1 + 1),
//     so the null `data == null` representation must survive store -> load.
// sum = 100 + 1 + 300 + 1 = 402 ; present = 2 ; result = 402*10 + 2 = 4022.

trait Dev {
    fn id(self: *Self) -> u32;
}

struct A {
    v: u32,
}

impl Dev for A {
    fn id(self: *A) -> u32 {
        return self.v;
    }
}

struct Reg {
    slots: [4]?*dyn Dev,
}

export fn run() -> u32 {
    var a0: A = .{ .v = 100 };
    var a2: A = .{ .v = 300 };
    var r: Reg = uninit;
    var i: usize = 0;
    while i < 4 {
        r.slots[i] = null; // all none, written to memory
        i = i + 1;
    }
    r.slots[0] = &a0; // some, written to memory
    r.slots[2] = &a2;

    var sum: u32 = 0;
    var present: u32 = 0;
    var j: usize = 0;
    while j < 4 {
        if let d = r.slots[j] { // read back from memory + narrow
            sum = sum + d.id(); // dispatch through the vtable
            present = present + 1;
        } else {
            sum = sum + 1; // none path taken
        }
        j = j + 1;
    }
    return sum * 10 + present;
}
