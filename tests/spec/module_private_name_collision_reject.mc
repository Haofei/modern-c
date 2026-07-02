// SPEC: section=30
// SPEC: milestone=file-private-name-uniquification
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_DUPLICATE_DECLARATION

// G22 negative twin of the file-private-name relaxation (§30). The relaxation is narrow:
// only file-private (non-`pub`) top-level values in DIFFERENT files may reuse a name. It must
// NOT weaken the two collisions that still share one namespace:
//   1. two `pub` decls of the same name — public names are globally visible, so they collide;
//   2. two file-private decls of the same name in the SAME file — a file resolves its own
//      privates locally, so a same-file duplicate is still ambiguous.
// This file is "strict" (it has `pub` decls), so its non-`pub` items ARE file-private — and
// the same-file duplicate is rejected exactly as before the relaxation.

pub fn keep_public_surface() -> u32 { return 0; }

pub fn dup_public() -> u32 { return 1; }
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
pub fn dup_public() -> u32 { return 2; }

fn dup_private() -> u32 { return 3; }
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
fn dup_private() -> u32 { return 4; }
