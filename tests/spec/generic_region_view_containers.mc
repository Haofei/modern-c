// SPEC: section=18.2,22
// SPEC: milestone=scoped-affine-ownership
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_REGION_RESOURCE_CONFLICT,E_BORROW_ESCAPES_SCOPE

// Generic containers that store `T` by value inherit region/view restrictions
// after substitution. Keep region and view containers separate so each template
// field line has one stable diagnostic.

#[experimental_ownership]
region struct Node { id: u32 }
struct Cell { value: u32 }
#[experimental_ownership]
view struct CellView { ptr: *Cell }

struct RegionBox<T> {
    value: T, // EXPECT_ERROR: E_REGION_RESOURCE_CONFLICT
}

struct ViewBox<T> {
    value: T, // EXPECT_ERROR: E_BORROW_ESCAPES_SCOPE
}

struct RegionPhantom<T> { id: usize }
struct ViewPhantom<T> { id: usize }

fn instantiate_region_box(b: *mut RegionBox<Node>) -> void {}
fn instantiate_view_box(b: *mut ViewBox<CellView>) -> void {}

fn accept_region_phantom(p: *mut RegionPhantom<Node>) -> usize {
    return p.id;
}

fn accept_view_phantom(p: *mut ViewPhantom<CellView>) -> usize {
    return p.id;
}
