// SPDX-License-Identifier: GPL-2.0-or-later

#[no_lang_trap]
#[irq_context]
fn mutated_completion(index: u32) -> u32 {
    // Deliberate mutation: checked addition introduces an overflow trap edge.
    return index + 1;
}
