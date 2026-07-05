extern "C" fn strlen(s: cstr) -> usize;
extern "C" fn identity(s: cstr) -> cstr;

export fn use_cstr() -> usize {
    let s: cstr = "abc";
    return strlen(s);
}

export fn return_cstr() -> cstr {
    return identity("xyz");
}
