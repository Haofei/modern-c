import "kernel/drivers/e1000.mc";
export fn e1000_run() -> u32 {
    return e1000_probe();
}
