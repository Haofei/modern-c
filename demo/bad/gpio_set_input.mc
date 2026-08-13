// EXPECT: E_NO_IMPLICIT_CONVERSION — driving a pin configured as input.
import "demo/gpio/gpio.mc";
fn bad(regs: MmioPtr<GpioRegs>) -> void {
    let inp: InputPin = config_input(regs, 3);
    gpio_set(regs, move inp, true);
}
