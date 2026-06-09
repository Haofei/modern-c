// A struct/MMIO field named after a C reserved word must mangle consistently:
// the field declaration, member reads/writes, and struct-literal fields all go
// through the same identifier mangling (`register` -> `register_`), so the
// emitted C compiles. Previously declarations mangled but member access and
// struct literals emitted the raw name, producing a field-name mismatch.

struct Frame {
    default: u32,
    register: u32,
    volatile: u32,
}

fn make_frame(a: u32, b: u32, c: u32) -> Frame {
    return .{ .default = a, .register = b, .volatile = c };
}

fn bump_register(f: Frame) -> Frame {
    var r: Frame = f;
    r.register = r.register + 1;
    return r;
}

fn frame_sum(f: Frame) -> u32 {
    return f.default + f.register + f.volatile;
}

// MMIO register whose field is a C keyword: declaration and `->` access must
// agree after mangling.
extern mmio struct Device {
    default: Reg<u32, .read_write>,
}

fn read_default(dev: MmioPtr<Device>) -> u32 {
    return dev.default.read(.acquire);
}

fn write_default(dev: MmioPtr<Device>, value: u32) -> void {
    dev.default.write(value, .release);
}
