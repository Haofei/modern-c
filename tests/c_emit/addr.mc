// std/addr: typed checked physical-address arithmetic over the opaque PAddr class.
import "std/addr.mc";

// offset + alignment + range, all without raw usize pointer math.
fn frame_base(region_start: usize, index: usize) -> PAddr {
    let start: PAddr = pa(region_start);
    return pa_offset(start, index * 4096);
}

fn round_up_to_page(addr: usize) -> usize {
    let aligned: PAddr = pa_align_up(pa(addr), 4096);
    return pa_value(aligned);
}

fn region_holds(base: usize, len: usize, probe: usize) -> bool {
    var r: PhysRange = phys_range(pa(base), len);
    return pr_contains(&r, pa(probe));
}
