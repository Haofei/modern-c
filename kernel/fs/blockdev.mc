// kernel/fs/blockdev — a block-device abstraction + a block-backed file store.
//
// A BlockDevice is fixed-size (512 B) blocks addressed by index, behind read/write
// function pointers, so any backend (a RAM disk for tests, or the virtio-blk driver)
// can serve it. The file store places each file in a contiguous run of blocks and
// does all I/O through the device — file data lives on the block device, not in a
// RAM pool. Block indices are bounds-checked; errors are typed.

const BLOCK_SIZE: usize = 512;

struct BlockDevice {
    read: fn(u64, u64, usize) -> bool,  // (ctx, block_index, dst_addr) -> ok
    write: fn(u64, u64, usize) -> bool, // (ctx, block_index, src_addr) -> ok
    ctx: u64,                           // backend context (e.g. the RAM-disk base)
    blocks: u64,                        // device size, in blocks
}

enum BlockError {
    OutOfRange, // block index past the device
    IoError,    // the backend reported failure
    NoSpace,    // file table full / not enough blocks
    BadFile,    // unused/invalid file index
}

// Read one block into `dst` (must hold BLOCK_SIZE bytes), through the device vtable.
export fn bd_read_block(dev: *BlockDevice, blk: u64, dst: usize) -> Result<bool, BlockError> {
    if blk >= dev.blocks {
        return err(.OutOfRange);
    }
    let f: fn(u64, u64, usize) -> bool = dev.read;
    let ok_io: bool = f(dev.ctx, blk, dst); // bind: a fn-pointer-call condition isn't bool-typed inline
    if ok_io {
        return ok(true);
    }
    return err(.IoError);
}

// Write one block from `src` (BLOCK_SIZE bytes) through the device vtable.
export fn bd_write_block(dev: *BlockDevice, blk: u64, src: usize) -> Result<bool, BlockError> {
    if blk >= dev.blocks {
        return err(.OutOfRange);
    }
    let f: fn(u64, u64, usize) -> bool = dev.write;
    let ok_io: bool = f(dev.ctx, blk, src);
    if ok_io {
        return ok(true);
    }
    return err(.IoError);
}

const MAX_FILES: usize = 4;

struct BlockFile {
    start_block: u64,
    nblocks: u64,
    size: usize, // valid bytes (<= nblocks * BLOCK_SIZE)
    used: bool,
}

struct BlockFs {
    files: [MAX_FILES]BlockFile,
    next_block: u64, // bump allocator over the device's blocks
}

export fn bfs_init(fs: *mut BlockFs) -> void {
    var i: usize = 0;
    while i < MAX_FILES {
        fs.files[i].used = false;
        i = i + 1;
    }
    fs.next_block = 0;
}

// Create a file reserving `nblocks` contiguous blocks on `dev`.
export fn bfs_create(fs: *mut BlockFs, dev: *BlockDevice, nblocks: u64) -> Result<usize, BlockError> {
    var slot: usize = MAX_FILES;
    var i: usize = 0;
    while i < MAX_FILES {
        if !fs.files[i].used {
            slot = i;
            break;
        }
        i = i + 1;
    }
    if slot == MAX_FILES {
        return err(.NoSpace);
    }
    if (fs.next_block + nblocks) > dev.blocks {
        return err(.NoSpace);
    }
    fs.files[slot].start_block = fs.next_block;
    fs.files[slot].nblocks = nblocks;
    fs.files[slot].size = 0;
    fs.files[slot].used = true;
    fs.next_block = fs.next_block + nblocks;
    return ok(slot);
}

// Write `len` bytes from `src` to file `idx`, block by block, through the device.
// `src` must span whole blocks (ceil(len / BLOCK_SIZE) blocks).
export fn bfs_write(fs: *mut BlockFs, dev: *BlockDevice, idx: usize, src: usize, len: usize) -> Result<usize, BlockError> {
    if !fs.files[idx].used {
        return err(.BadFile);
    }
    let cap: usize = (fs.files[idx].nblocks as usize) * BLOCK_SIZE;
    if len > cap {
        return err(.NoSpace);
    }
    let start: u64 = fs.files[idx].start_block;
    var written: usize = 0;
    var b: u64 = 0;
    while written < len {
        switch bd_write_block(dev, start + b, src + (b as usize) * BLOCK_SIZE) {
            ok(x) => {}
            err(e) => {
                return err(e);
            }
        }
        written = written + BLOCK_SIZE;
        b = b + 1;
    }
    fs.files[idx].size = len;
    return ok(len);
}

// Read up to `len` bytes of file `idx` into `dst` (whole blocks), through the device.
export fn bfs_read(fs: *mut BlockFs, dev: *BlockDevice, idx: usize, dst: usize, len: usize) -> Result<usize, BlockError> {
    if !fs.files[idx].used {
        return err(.BadFile);
    }
    let size: usize = fs.files[idx].size;
    var n: usize = len;
    if size < n {
        n = size;
    }
    let start: u64 = fs.files[idx].start_block;
    var done: usize = 0;
    var b: u64 = 0;
    while done < n {
        switch bd_read_block(dev, start + b, dst + (b as usize) * BLOCK_SIZE) {
            ok(x) => {}
            err(e) => {
                return err(e);
            }
        }
        done = done + BLOCK_SIZE;
        b = b + 1;
    }
    return ok(n);
}

export fn bfs_size(fs: *mut BlockFs, idx: usize) -> usize {
    return fs.files[idx].size;
}
