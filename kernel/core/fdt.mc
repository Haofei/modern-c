// kernel/core/fdt — flattened device-tree (FDT/DTB) header parsing: validate the magic
// and read the totalsize/version. The kernel reads the DTB the bootloader/QEMU passes to
// discover memory + devices instead of hardcoding addresses (start of device discovery).

import "std/bytes.mc";
import "std/addr.mc";

const FDT_MAGIC: u32 = 0xD00D_FEED;

export fn fdt_valid(blob: PAddr, len: usize) -> bool {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 0) == FDT_MAGIC;
}
export fn fdt_totalsize(blob: PAddr, len: usize) -> u32 {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 4);
}
export fn fdt_version(blob: PAddr, len: usize) -> u32 {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 20);
}
