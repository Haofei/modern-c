import "./qualified_forward_module.mc";

fn call_module() -> u32 { return Util.answer(); }
fn read_module_const() -> u32 { return Util.LIMIT; }
fn call_impl() -> u32 { return Widget.make(); }
