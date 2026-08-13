# kernel/bus — device model + driver binding

The pluggable structure is **driver registration over stable interfaces**, with
static (fixed-capacity) registration for validation fixtures. The contract:

> drivers plug into buses · tests discover device-class endpoints

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

Static-registration backbone: a `Registry` maps a numeric device-class key to an endpoint
handle. `registry.mc` is the **write** side (drivers register, detach removes);
`registry_client.mc` is the **read** side (`lookup`, `available`) so validation code
discovers dependencies without touching registry internals.

## Boot flow (see `tests/qemu/plugin_demo.mc`)

1. **Platform describes resources** — `kernel/platform/qemu_virt/resources.mc` lists the
   board's devices (id + MMIO + IRQ). A different board supplies the same shape.
2. **Bus enumerates** the devices.
3. **Drivers attach** — the first matching `Provider.attach` binds each device.
4. **Drivers register** their device-class endpoint in the registry.
5. **Validation code discovers** the registered device endpoint via `registry_client.lookup`.

## Adding a real driver

An existing driver (e.g. `kernel/drivers/virtio/virtio_net.mc`, `console` UART) adopts the
model by exposing two closures over its own state and registering a provider at boot:

```
bus_register_provider(&bus,
    bind(&my_drv, my_probe),   // DeviceId -> bool
    bind(&my_drv, my_attach),  // ResourceSet -> endpoint (init MMIO, set up rings, …)
    .Net);
```

No change to the bus or registry is needed for the validation fixture.
