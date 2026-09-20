extern "C" fn dma_submit(cpu: [*]mut u8, dma: DmaAddr, len: usize) -> i32;
extern fn inspect(bytes: []const u8, optional: ?*const u8) -> void;
