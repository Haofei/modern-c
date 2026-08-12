import "./inspection_modules_imported.mc";

fn root_checked(a: u32, b: u32) -> u32 {
    return imported_checked(a, b);
}
