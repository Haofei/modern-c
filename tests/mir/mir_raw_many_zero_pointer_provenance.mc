global shared_counter: u32 = 0;
const ZERO_OFFSET: usize = 0;
struct ZeroField { value: u8 }
const REFLECT_ZERO_OFFSET: usize = field_offset<ZeroField>(.value);

extern fn external_raw_many_pointer() -> [*]mut u32;

fn touch() {}

fn raw_many_zero_fact() {
    unsafe {
        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        let copy: [*]mut u32 = p;
        let q: [*]mut u32 = p.offset(0);
        let r: [*]mut u32 = p.offset(REFLECT_ZERO_OFFSET);
        let s: [*]mut u32 = p.offset(field_offset<ZeroField>(.value));
        let grouped: [*]mut u32 = (p.offset(0));
        let casted: [*]mut u32 = p.offset(0) as [*]mut u32;
        #[unsafe_contract(noalias)]
        {
            let t: [*]mut u32 = compiler.assume_noalias_unchecked(p.offset(0), 4);
        }
    }
}

fn raw_many_zero_assignment_fact() {
    unsafe {
        var local: u32 = 1;
        let p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        var q: [*]mut u32 = (&local) as [*]mut u32;
        q = p;
        q = p.offset(ZERO_OFFSET);
        q = (p.offset(0));
        q = p.offset(0) as [*]mut u32;
    }
}

fn raw_many_zero_fail_closed(i: usize) {
    unsafe {
        var local: u32 = 1;
        let global_p: [*]mut u32 = (&shared_counter) as [*]mut u32;
        let local_p: [*]mut u32 = (&local) as [*]mut u32;
        var q: [*]mut u32 = (&shared_counter) as [*]mut u32;
        q = global_p.offset(1);
        q = global_p.offset(i);
        q = local_p.offset(0);
        q = external_raw_many_pointer().offset(0);
        touch();
        q = global_p.offset(0);
    }
}
