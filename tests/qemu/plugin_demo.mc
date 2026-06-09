// The pluggable boot flow end to end: platform describes devices, the bus matches them to
// driver providers (probe), the first match attaches and registers a device-class endpoint,
// and a "service" discovers its dependency through the registry. Static registration only.
import "kernel/bus/device.mc";
import "kernel/lib/registry.mc";
import "kernel/lib/registry_client.mc";
import "kernel/platform/qemu_virt/resources.mc";

// Per-driver private state; `attach` captures it and returns an endpoint handle.
struct NetDrv { attaches: u32 }
struct BlkDrv { attaches: u32 }
struct ConDrv { attaches: u32 }
global g_net: NetDrv;
global g_blk: BlkDrv;
global g_con: ConDrv;

fn probe_net(d: *mut NetDrv, id: DeviceId) -> bool { return id.vendor == 0x1AF4 && id.device == 1; }
fn attach_net(d: *mut NetDrv, res: ResourceSet) -> u32 { d.attaches = d.attaches + 1; return 10; }
fn probe_blk(d: *mut BlkDrv, id: DeviceId) -> bool { return id.vendor == 0x1AF4 && id.device == 2; }
fn attach_blk(d: *mut BlkDrv, res: ResourceSet) -> u32 { d.attaches = d.attaches + 1; return 20; }
fn probe_con(d: *mut ConDrv, id: DeviceId) -> bool { return id.vendor == 0x16550; }
fn attach_con(d: *mut ConDrv, res: ResourceSet) -> u32 { d.attaches = d.attaches + 1; return 30; }

global g_bus: Bus;
global g_reg: Registry;
global g_devs: [3]Device;

export fn plugin_run() -> u32 {
    var pass: u32 = 1;
    bus_init(&g_bus);
    registry_init(&g_reg);
    g_net.attaches = 0; g_blk.attaches = 0; g_con.attaches = 0;

    // register driver providers (drivers plug into the bus)
    let pn: usize = bus_register_provider(&g_bus, bind(&g_net, probe_net), bind(&g_net, attach_net), .Net);
    let pb: usize = bus_register_provider(&g_bus, bind(&g_blk, probe_blk), bind(&g_blk, attach_blk), .Block);
    let pc: usize = bus_register_provider(&g_bus, bind(&g_con, probe_con), bind(&g_con, attach_con), .Console);
    if pn != 0 { pass = 0; }
    if pb != 1 { pass = 0; }
    if pc != 2 { pass = 0; }

    // platform describes its devices; the bus enumerates them and attaches a driver to each
    if platform_ndev() != 3 { pass = 0; }
    var i: usize = 0;
    while i < platform_ndev() {
        let d: *mut Device = &g_devs[i];
        if !platform_device(i, d) { pass = 0; }
        switch bus_probe_attach(&g_bus, d, &g_reg) {
            ok(p) => {}
            err(e) => { pass = 0; }
        }
        i = i + 1;
    }

    // every device attached + exposed a class endpoint
    let d0: *Device = &g_devs[0];
    if !d0.attached { pass = 0; }
    if d0.endpoint != 10 { pass = 0; } // the net driver's endpoint
    if g_net.attaches != 1 { pass = 0; }
    if g_blk.attaches != 1 { pass = 0; }
    if g_con.attaches != 1 { pass = 0; }
    if registry_count(&g_reg) != 3 { pass = 0; }

    // services discover their device-class endpoints by class (services plug into devices)
    switch lookup(&g_reg, class_code(.Net)) {
        ok(ep) => { if ep != 10 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch lookup(&g_reg, class_code(.Block)) {
        ok(ep) => { if ep != 20 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch lookup(&g_reg, class_code(.Console)) {
        ok(ep) => { if ep != 30 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // a class with no device is Unavailable (no framebuffer present)
    if available(&g_reg, class_code(.Framebuffer)) { pass = 0; }

    // a device with no matching driver does not attach (NoDriver)
    var orphan: Device = uninit;
    orphan.id.vendor = 0xDEAD; orphan.id.device = 9;
    orphan.res.mmio_base = 0; orphan.res.mmio_len = 0; orphan.res.irq = 0;
    orphan.attached = false; orphan.class = .None; orphan.endpoint = 0;
    switch bus_probe_attach(&g_bus, &orphan, &g_reg) {
        ok(p) => { pass = 0; }
        err(e) => {}
    }

    // a driver detach removes its endpoint: the console becomes Unavailable for new clients
    switch registry_remove(&g_reg, class_code(.Console)) {
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    if registry_count(&g_reg) != 2 { pass = 0; }
    if available(&g_reg, class_code(.Console)) { pass = 0; } // gone
    if !available(&g_reg, class_code(.Net)) { pass = 0; }    // others remain
    return pass;
}
