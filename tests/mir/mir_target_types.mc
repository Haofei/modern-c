enum E { bad }
struct Slot { cb: closure(u32) -> u32, result: Result<u32, E> }
struct TextSlot { ptr: *const u8, bytes: []const u8 }
struct FloatSlot { small: f32, wide: f64 }
packed bits Flags: u8 { ready: bool }
#[c_union]
struct CWord { word: u32, byte: u8 }
union Token { number: i64, eof, ok: u32 }
union Event { mode: E }
global default_error: E = .bad;
global default_text: *const u8 = "global";
global default_float: f32 = 1.25;
global default_char: u8 = 'a';
fn add(env: *mut u32, value: u32) -> u32 { return env.* + value; }
fn consume(value: Result<u32, E>) -> u32 { return 0; }
fn make_bind(env: *mut u32) -> closure(u32) -> u32 { return bind(env, add); }
fn make_ok(value: u32) -> Result<u32, E> { return ok(value); }
fn make_err() -> Result<u32, E> { return err(.bad); }
fn pass_ok(value: u32) -> u32 { return consume(ok(value)); }
fn make_slot(env: *mut u32, value: u32) -> Slot { return .{ .cb = bind(env, add), .result = ok(value) }; }
fn number(value: i64) -> Token { return Token.number(value); }
fn make_number(value: i64) -> Token { return number(value); }
fn make_eof() -> Token { return eof(); }
fn make_union_ok(value: u32) -> Token { return ok(value); }
fn make_enum() -> E { return .bad; }
fn compare_enum(value: E) -> bool { return .bad == value; }
fn cast_enum() -> E { return .bad as E; }
fn make_event() -> Event { return mode(.bad); }
fn make_text() -> *const u8 { return "text"; }
fn make_text_result() -> Result<*const u8, E> { return ok("ok"); }
fn make_text_slot() -> TextSlot { return .{ .ptr = "ptr", .bytes = "bytes" }; }
fn make_array() -> [2]u32 { return .{ 1, 2 }; }
fn make_flags() -> Flags { return .{ .ready = true }; }
fn make_c_word() -> CWord { return .{ .word = 7, .byte = uninit }; }
fn make_float() -> f32 { return 1.5; }
fn make_float_expr() -> f32 { return 1.7 * 2.3; }
fn make_float_slot() -> FloatSlot { return .{ .small = 1.0, .wide = 2.0 }; }
fn make_char() -> u16 { return 'A'; }
fn maybe_value(value: u32) -> ?u32 { return value; }
fn no_value() -> ?u32 { return null; }
fn maybe_text_slot() -> ?TextSlot { return .{ .ptr = "ptr", .bytes = "bytes" }; }
