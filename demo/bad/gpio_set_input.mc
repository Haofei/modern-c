// EXPECT: E_NO_IMPLICIT_POINTER_CONVERSION — driving a pin configured as input.
import "demo/gpio/gpio.mc";
fn bad(regs: MmioPtr<GpioRegs>) -> void {
    var inp: InputPin = config_input(regs, 3);
    gpio_set(regs, &inp, true);
    release_input(inp);
}
