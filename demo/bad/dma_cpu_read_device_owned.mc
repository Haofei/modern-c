// EXPECT: E_NO_IMPLICIT_POINTER_CONVERSION — getting a CPU address of a device-owned buffer.
import "std/dma.mc";
fn bad() -> usize {
    let cpu: CpuBuffer = alloc(64);
    var dev: DeviceBuffer = clean_for_device(cpu);
    let a: usize = cpu_addr(&dev);
    free(invalidate_for_cpu(dev));
    return a;
}
