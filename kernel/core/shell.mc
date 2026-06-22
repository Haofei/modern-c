// kernel/core/shell — a minimal command interpreter. `sh_exec` is the one-word skeleton;
// `Shell`/`sh_run` is the fuller version: it tokenizes a whole command line into an argv
// vector and dispatches builtins (`echo`, `true`, `false`), capturing echo's output and
// the exit code. A full hosted shell would fork/exec external programs (we have exec +
// args + fd tables for that); this runs builtins entirely in-process.

import "std/libc.mc";
import "std/addr.mc";
import "kernel/lib/args.mc";

const SH_NOTFOUND: u32 = 127; // POSIX "command not found" exit status
const SH_OUT: usize = 128;
const SPACE: u8 = 0x20;

// Loop control, kept distinct from the numeric exit status: a command either ran (its
// POSIX status is in `code`) or asked the interactive loop to stop. The old SH_EXIT=255
// overloaded the exit-status field with a control signal; this names the intent instead.
enum ShOutcome {
    Ran,
    Exit,
}

// --- one-word skeleton (kept for the original gate) ---
export fn sh_exec(line: PAddr, len: usize) -> u32 {
    var wlen: usize = 0;
    var scanning: bool = true;
    while scanning {
        if wlen >= len {
            scanning = false;
        } else {
            var c: u8 = 0;
            unsafe {
                c = raw.load<u8>(pa_offset(line, wlen));
            }
            if c == SPACE {
                scanning = false;
            } else {
                wlen = wlen + 1;
            }
        }
    }
    var tbuf: [4]u8 = .{ 0x74, 0x72, 0x75, 0x65 };
    var fbuf: [5]u8 = .{ 0x66, 0x61, 0x6C, 0x73, 0x65 };
    if wlen == 4 {
        if mc_memeq(line, pa((&tbuf[0]) as usize), 4) {
            return 0;
        }
    }
    if wlen == 5 {
        if mc_memeq(line, pa((&fbuf[0]) as usize), 5) {
            return 1;
        }
    }
    return SH_NOTFOUND;
}

// --- fuller shell: tokenize + dispatch with output capture ---
struct Shell {
    out: [SH_OUT]u8, // captured stdout of the last command
    out_len: usize,
    code: u32,           // POSIX-style exit status of the last command (0 ok, 1 false, 127 not found)
    outcome: ShOutcome,  // loop control: did the last command request exit?
}

// Scratch argv for the command being parsed (the address of a nested struct field can't
// be passed to a function as a *mut, so the tokenizer works on a module-level vector).
global g_cmd: Args;

export fn sh_init(sh: *mut Shell) -> void {
    sh.out_len = 0;
    sh.code = 0;
    sh.outcome = .Ran;
}

// Accessors (reading a global aggregate's array field directly is not supported; go
// through a pointer).
export fn sh_out_byte(sh: *mut Shell, i: usize) -> u8 {
    if i < SH_OUT {
        return sh.out[i];
    }
    return 0;
}
export fn sh_out_len(sh: *mut Shell) -> usize {
    return sh.out_len;
}
export fn sh_code(sh: *mut Shell) -> u32 {
    return sh.code;
}

// Split a command line into whitespace-delimited argv words.
fn sh_tokenize(line: PAddr, len: usize) -> void {
    args_init(&g_cmd);
    var i: usize = 0;
    while i < len {
        var c: u8 = 0;
        unsafe {
            c = raw.load<u8>(pa_offset(line, i));
        }
        if c == SPACE {
            i = i + 1; // skip run of spaces
        } else {
            args_begin(&g_cmd);
            var inword: bool = true;
            while inword {
                if i >= len {
                    inword = false;
                } else {
                    var d: u8 = 0;
                    unsafe {
                        d = raw.load<u8>(pa_offset(line, i));
                    }
                    if d == SPACE {
                        inword = false;
                    } else {
                        args_push_byte(&g_cmd, d);
                        i = i + 1;
                    }
                }
            }
            args_end(&g_cmd);
        }
    }
}

// Does argv[idx] of the most recently parsed command equal the literal at `lit`? Public
// so a higher shell layer can dispatch its own commands without `shell.mc` knowing them.
export fn sh_arg_eq(idx: usize, lit: PAddr, litlen: usize) -> bool {
    if args_len(&g_cmd, idx) != litlen {
        return false;
    }
    var j: usize = 0;
    while j < litlen {
        var l: u8 = 0;
        unsafe {
            l = raw.load<u8>(pa_offset(lit, j));
        }
        if args_byte(&g_cmd, idx, j) != l {
            return false;
        }
        j = j + 1;
    }
    return true;
}

// `echo`: write argv[1..] joined by single spaces into the capture buffer.
fn sh_echo(sh: *mut Shell) -> void {
    var w: usize = 0;
    var i: usize = 1;
    while i < args_count(&g_cmd) {
        if i > 1 {
            if w < SH_OUT {
                sh.out[w] = SPACE;
                w = w + 1;
            }
        }
        let al: usize = args_len(&g_cmd, i);
        var j: usize = 0;
        while j < al {
            if w < SH_OUT {
                sh.out[w] = args_byte(&g_cmd, i, j);
                w = w + 1;
            }
            j = j + 1;
        }
        i = i + 1;
    }
    sh.out_len = w;
}

// Parse + run one command line; fills sh.out/out_len/code.
export fn sh_run(sh: *mut Shell, line: PAddr, len: usize) -> void {
    sh_tokenize(line, len);
    sh.out_len = 0;
    sh.outcome = .Ran; // reset loop control each command
    if args_count(&g_cmd) == 0 {
        sh.code = 0; // empty line
        return;
    }
    var echo: [4]u8 = .{ 0x65, 0x63, 0x68, 0x6F };       // "echo"
    var tru: [4]u8 = .{ 0x74, 0x72, 0x75, 0x65 };        // "true"
    var fal: [5]u8 = .{ 0x66, 0x61, 0x6C, 0x73, 0x65 };  // "false"
    if sh_arg_eq(0, pa((&echo[0]) as usize), 4) {
        sh_echo(sh);
        sh.code = 0;
        return;
    }
    if sh_arg_eq(0, pa((&tru[0]) as usize), 4) {
        sh.code = 0;
        return;
    }
    if sh_arg_eq(0, pa((&fal[0]) as usize), 5) {
        sh.code = 1;
        return;
    }
    var ext: [4]u8 = .{ 0x65, 0x78, 0x69, 0x74 }; // "exit"
    if sh_arg_eq(0, pa((&ext[0]) as usize), 4) {
        sh.code = 0;          // exiting cleanly
        sh.outcome = .Exit;   // control: stop the interactive loop
        return;
    }
    sh.code = SH_NOTFOUND; // command not found
}

// True if the last command was `exit` (the interactive loop should stop).
export fn sh_is_exit(sh: *mut Shell) -> bool {
    let o: ShOutcome = sh.outcome;
    switch o {
        .Ran => { return false; }
        .Exit => { return true; }
    }
}

