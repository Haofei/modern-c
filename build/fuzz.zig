const std = @import("std");
const h = @import("helpers.zig");

// The mcfuzz oracle family (generation, trap consistency, robustness, fail-closed,
// determinism, full-pipeline, round-trip/idempotence, and the
// metamorphic/optlevel/floatbits/reference/corpus oracles).
pub fn register(ctx: *h.Ctx) void {
    _ = h.addScriptTest(ctx, "fuzz", "mcfuzz: type-directed differential fuzzer over the full scalar type system (C vs LLVM)", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "differential", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-sanitize", "mcfuzz: run generated full-type-system programs' emitted C under UBSan", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "sanitize", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-trap", "mcfuzz: trap-consistency — generated programs that may trap must trap on both backends together", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "differential", "--trapping", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-robust", "mcfuzz: robustness — mcc check must never crash/hang on mutated input", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "robust", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-failclosed", "mcfuzz: fail-closed soundness — mcc check must reject ill-typed programs", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "failclosed", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-determinism", "mcfuzz: emit-c/emit-llvm must be byte-deterministic", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "determinism", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-pipeline", "mcfuzz: every lowering/verify stage must succeed on a check-accepted program", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "pipeline", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-roundtrip", "mcfuzz: generated source must format/check idempotently while preserving tokens and lowering", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "roundtrip", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-metamorphic", "mcfuzz: a semantics-preserving source transform must not change the result", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "metamorphic", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-optlevel", "mcfuzz: emitted C must give the same result at -O0 and -O2 (no optimization-sensitive UB)", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "optlevel", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-floatbits", "mcfuzz: f32/f64 results must match bit-for-bit across backends (finite-only)", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "floatbits", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-reference", "mcfuzz: compiled output must match the independent Python reference interpreter (shared-frontend bugs)", &.{ "python3", "tools/fuzz/mcfuzz.py", "run", "--oracle", "reference", "--mcc", "zig-out/bin/mcc" });

    _ = h.addScriptTest(ctx, "fuzz-corpus", "mcfuzz: replay the persisted regression corpus — each fixed-bug repro must stay clean", &.{ "python3", "tools/fuzz/mcfuzz.py", "corpus", "--mcc", "zig-out/bin/mcc" });
}
