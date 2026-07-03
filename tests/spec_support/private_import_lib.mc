fn private_import_secret(x: u32) -> u32 {
    return x * 2;
}

pub fn private_import_public(x: u32) -> u32 {
    return private_import_secret(x) + 1;
}
