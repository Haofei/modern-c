// An array global whose type is spelled through an alias, with an element type
// that is itself an alias. The aggregate renderer sees a bare name and must ask
// the module's type-alias table what it denotes; recovering that from the
// declaration's syntax would be the backend inferring a type again.
type Count = u32;
type Counts = [3]Count;

enum Mode { idle, busy }
type Modes = [2]Mode;

global counts: Counts = .{ 1, 2, 3 };
global modes: Modes = .{ .idle, .busy };

export fn first_count() -> u32 {
    return counts[0];
}

export fn first_mode_is_idle() -> bool {
    return modes[0] == Mode.idle;
}
