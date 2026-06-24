// EXPECT: E_NO_IMPLICIT_POINTER_CONVERSION — getting a CPU address of a device-owned buffer.
import "std/alloc/dma.mc";
fn bad() -> PAddr {
    let cpu: CpuBuffer = alloc(64);
    var dev: DeviceBuffer = clean_for_device(cpu);
    let a: PAddr = cpu_addr(&dev);
    free(invalidate_for_cpu(dev));
    return a;
}
