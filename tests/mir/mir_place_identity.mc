struct Pair { left: u32, right: u32 }
struct Box { pair: Pair }
global box: Box = .{ .pair = .{ .left = 1, .right = 2 } };
fn update(value: u32) -> u32 {
    box.pair.left = value;
    return box.pair.left;
}
