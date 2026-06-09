# kernel/bus — device model + driver binding

The pluggable structure is **service and driver registration over stable interfaces**, with
static (fixed-capacity) registration now and dynamic loading later. The contract:

> drivers plug into buses · services plug into device classes · apps plug into services

## The interfaces (`device.mc`)

- `DeviceId { vendor, device }` — what a device *is*.
- `ResourceSet { mmio_base, mmio_len, irq }` — what a device *has*.
- `Device { id, res, attached, class, endpoint }` — a device plus its binding state.
- `DeviceClass` — the abstract class a driver exposes: `Block | Net | Console | Framebuffer | Timer`.
- `Provider { probe, attach, class }` — a driver's plug:
  - `probe(DeviceId) -> bool` — does this driver match the device?
  - `attach(ResourceSet) -> u32` — bind the device, return a driver-instance **endpoint**.
  - both are **closures**, so a driver captures its private state (no untyped ctx word).
- `Bus` — a fixed table of providers; `bus_probe_attach` matches a device to the first
  provider whose `probe` succeeds, calls `attach`, and records `(class_code → endpoint)` in
  the registry. Returns `NoDriver` if nothing matched.

## The registry (`kernel/lib/registry.mc` + `registry_client.mc`)

Static-registration backbone: a `Registry` maps a numeric key (a device-class code or a
service-name hash) to an endpoint handle. `registry.mc` is the **write** side (drivers and
services register, detach removes); `registry_client.mc` is the **read** side (`lookup`,
`available`) so clients discover dependencies without touching registry internals.

## Boot flow (see `tests/qemu/plugin_demo.mc`)

1. **Platform describes resources** — `kernel/platform/qemu_virt/resources.mc` lists the
   board's devices (id + MMIO + IRQ). A different board supplies the same shape.
2. **Bus enumerates** the devices.
3. **Drivers attach** — the first matching `Provider.attach` binds each device.
4. **Drivers register** their device-class endpoint in the registry.
5. **Services bind** — a service (`kernel/lib/service.mc` loop) resolves its device class via
   `registry_client.lookup` (VFS → Block, net server → Net, TTY → Console).
6. **Userland discovers** services through the registry by name.

## Adding a real driver

An existing driver (e.g. `kernel/drivers/virtio/virtio_net.mc`, `console` UART) adopts the
model by exposing two closures over its own state and registering a provider at boot:

```
bus_register_provider(&bus,
    bind(&my_drv, my_probe),   // DeviceId -> bool
    bind(&my_drv, my_attach),  // ResourceSet -> endpoint (init MMIO, set up rings, …)
    .Net);
```

No change to the bus, registry, or services — that is the point of the stable interface.

## MINIX-style split (direction, not yet fully realized)

Keep the core small: trap, scheduler, IPC, address spaces, grants, IRQ routing in-kernel;
bus manager, drivers, VFS, net, TTY, process manager as user-mode services where possible.
The kernel only grants resources and routes messages/interrupts. The registry + service loop
+ probe/attach table are the substrate for moving drivers/services out of the core over time.
