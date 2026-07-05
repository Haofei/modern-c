# Production readiness: the MC compiler (`mcc`)

Status: **assessment + roadmap**, written 2026-07-02 at `311fdd18`.
Current ledger: **updated 2026-07-05, based on implementation through this ledger update**.
Ledger count: **58 finished and pushed, 0 in progress, 4 pending**.

> This file started as a point-in-time audit. The sections below the ledger preserve
> that original review context, including findings that have since been fixed. Treat
> this ledger as the current source of truth for goal progress; treat older ranked
> tables as historical evidence unless the item is repeated under "Pending".

## 0. Current Progress Ledger

### Finished And Pushed

| Item | Why it matters | Evidence |
|---|---|---|
| Parser nesting is bounded | Deep input now produces a diagnostic instead of a compiler crash. | `E_NESTING_TOO_DEEP`; direct deep-paren probe rejects cleanly. |
| Parser recovery reports multiple parse errors across scoped bodies | Top-level declarations, block statements, module/impl/trait members, and aggregate fields now resync inside the enclosing syntax body; parse-failed modules still abort before sema, avoiding misleading semantic follow-on errors. | `7d705b12 Improve parser declaration recovery`; `tests/spec/parser_statement_recovery.mc`; `tests/spec/parser_declaration_recovery.mc`; direct `mcc check` emits multiple parse diagnostics without orphan-brace noise. |
| Missing imports and cross-file diagnostics are actionable | Users see the failing import path or imported file/line instead of root-file noise or raw Zig traces. | `E_IMPORT_NOT_FOUND` probe; imported `lib.mc` diagnostic points at `lib.mc`. |
| Expected diagnostic failures no longer print Zig error-return traces | Normal user errors no longer look like compiler ICEs. | Unknown identifier probe prints only the MC diagnostic. |
| Monomorphization has limits and generic body prechecks | Polymorphic recursion and invalid instantiated operators fail loudly instead of hanging or reaching backend emission. | `E_MONOMORPHIZATION_LIMIT`; `38eff033 Validate generic instantiation operators in sema`. |
| Closure typing and closure escape checks are enforced | Closure calls cannot silently use the wrong signature or dangling environment. | `tests/spec/closure_typing.mc`; pushed closure soundness fixes. |
| Linear move checks cover loop conditions and short-circuit RHS | Move-only resources cannot be conditionally consumed in a way that leaks or double-frees. | `tests/spec/move_linear.mc`; `E_MOVE_BRANCH_MISMATCH` probes. |
| Aggregate `uninit` reads are tracked | Struct/array `var x: T = uninit` reads no longer compile before definite initialization. | `tests/spec/initialization.mc`; `tests/c_emit/bad/use_before_init_aggregate.mc`. |
| Extern/export struct-by-value ABI hazards fail closed | Unsupported C ABI aggregate passing is rejected instead of mislowered by LLVM. | `tests/c_emit/bad/extern_struct_return_by_value.mc`; `tests/c_emit/bad/export_struct_return_by_value.mc`. |
| 128-bit comptime/reflection overflow is guarded | Huge layout/reflection expressions return diagnostics instead of panicking the compiler. | `tests/spec/reflection.mc`; `src/eval_tests.zig` array-size helper tests. |
| `cstr` is implemented and documented | The normative FFI string type now exists across sema, MIR, C, and LLVM lowering. | `1f5c0274 Implement cstr FFI type`; `7278d844 docs: sync cstr FFI status`. |
| Async control-flow spec matches implementation | The spec no longer claims completed E3a/E3b/E3c async forms are reserved. | `b4650dab docs: sync async control-flow spec`; `zig build test`. |
| KASAN/KMSAN store-side sanitizer gaps are closed | Sanitizer modes catch freed/uninitialized heap state on stores as well as loads. | `5b25e328`, `ba8b8de9`. |
| LLVM direct global race lowering is no longer UB-bearing | Direct global scalar, struct-field, and array-element accesses now lower to unordered LLVM atomics instead of plain `load`/`store`. | `9ca762fc Lower racing globals to unordered LLVM atomics`; `llvm-as` on `data_race_semantics` IR. |
| LLVM bounded pointer-mediated global race lowering is no longer UB-bearing | Direct `(&global).*` and local pointer slots initialized from direct global storage, including simple pointer-local copies, lower scalar deref loads/stores to unordered LLVM atomics; broader escaped/computed provenance remains pending. | `cf8b2fdd Lower global pointer derefs to LLVM atomics`; `tests/spec/data_race_semantics.mc`; `src/lower_llvm_tests.zig`; `llvm-as` on `data_race_semantics` IR. |
| LLVM raw-many zero-offset pointer provenance is bounded and conservative | Raw-many pointer locals initialized from already-proven global-backed storage now preserve provenance through constant `.offset(0)` and lower the final scalar deref as unordered atomic; nonzero, dynamic, and unknown call-produced offsets remain plain. | `961956b0 Preserve zero raw-many offset provenance`; `tests/spec/data_race_semantics.mc` `possibly_racing_raw_many_offset_zero_pointer_load` / `raw_many_offset_one_pointer_stays_plain` / `raw_many_offset_dynamic_pointer_stays_plain` / `raw_many_offset_unknown_pointer_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM returned global-pointer race lowering is no longer UB-bearing | Internal helpers proven to return visible global-backed pointer expressions now preserve that provenance at call sites, so scalar derefs of the returned pointer lower to unordered atomics. | `0fb49f96 Lower returned global pointers atomically in LLVM`; `tests/spec/data_race_semantics.mc` `returned_global_pointer`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM global-backed pointer parameter race lowering is no longer UB-bearing for bounded direct calls | Internal, non-exported functions whose pointer-like parameter is passed visible global storage at every direct call site now seed that parameter as global-backed during LLVM emission; mixed global/local and local-only call paths remain plain. | `d679659b Lower global-backed pointer parameters atomically`; `tests/spec/data_race_semantics.mc` `consume_global_param` / `consume_mixed_param` / `consume_local_only_param`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM scalar pointer params are proven through bounded local function-pointer aliases | Same-function local function-pointer aliases initialized directly from internal functions now count as scalar pointer-param call sites when called with visible global-backed arguments; reassigned/escaped aliases and mixed targets remain plain. | `4ae4f93a Prove scalar pointer params through local fn aliases`; `b0c3bb72 Keep reassigned fn alias targets plain`; `tests/spec/data_race_semantics.mc` `consume_indirect_global_param` / `consume_indirect_reassigned_param` / `consume_indirect_reassigned_other_param`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM copied local function-pointer aliases preserve bounded pointer-param provenance | Same-function local function-pointer aliases initialized from another still-live local alias now inherit the same internal target for scalar and aggregate pointer-param summaries; copied aliases that are reassigned or escape as values remain plain. | `a7b6e91c Track copied local fn aliases`; `bd265e22 Prove copied local fn aliases in LLVM`; `tests/spec/data_race_semantics.mc` `consume_alias_copy_param` / `consume_alias_copy_reassigned_param` / `consume_alias_copy_escape_param` / `consume_aggregate_alias_copy_param` / `consume_aggregate_alias_copy_escape_param`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM aggregate-contained pointer field race lowering is no longer UB-bearing for bounded local fields | Direct local aggregate pointer fields initialized or assigned from visible global storage now seed local pointer copies as global-backed during LLVM emission; stack-backed, reassigned stack-backed, whole-aggregate copy, and exported-return ambiguity cases remain plain. | `49f02b3f Track aggregate pointer field provenance`; `tests/spec/data_race_semantics.mc` `aggregate_global_pointer_field_load` / `aggregate_stack_pointer_field_stays_plain` / `aggregate_reassigned_stack_pointer_field_stays_plain` / `aggregate_whole_copy_pointer_field_stays_plain` / `aggregate_exported_return_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM aggregate whole-copy pointer field provenance is bounded and conservative | Direct same-struct local-to-local aggregate assignment/init copies now propagate already-proven pointer-field facts, so copied global-backed fields continue to lower derefs as unordered atomics while stack-backed and computed aggregate sources remain plain. | `352be47f Propagate aggregate copy pointer provenance`; `tests/spec/data_race_semantics.mc` `aggregate_whole_copy_pointer_field_load` / `aggregate_init_copy_pointer_field_load` / `aggregate_whole_copy_stack_pointer_field_stays_plain` / `aggregate_computed_copy_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM nested aggregate pointer field provenance is bounded and conservative | Direct local named member paths such as `outer.inner.ptr` now carry proven global-backed pointer-field facts through struct-literal init and direct nested field assignment; stack-backed and reassigned-stack nested paths remain plain. | `fd48f50a Track nested aggregate pointer provenance`; `tests/spec/data_race_semantics.mc` `nested_aggregate_global_pointer_field_load` / `nested_aggregate_assigned_global_pointer_field_load` / `nested_aggregate_stack_pointer_field_stays_plain` / `nested_aggregate_reassigned_stack_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM local pointer-array provenance is bounded and conservative | Direct local fixed arrays of pointer-like elements now carry proven global-backed facts for constant-index literal elements and constant-index assignments; stack-backed elements and dynamic-index reads/writes remain plain. | `9f24297e Track LLVM local array pointer provenance`; `tests/spec/data_race_semantics.mc` `array_global_pointer_element_load` / `array_assigned_global_pointer_element_load` / `array_stack_pointer_element_stays_plain` / `array_dynamic_index_pointer_element_stays_plain` / `array_dynamic_assignment_clears_pointer_element_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM local aggregate-pointer aliases are bounded and conservative | Local pointer variables declared directly from `&local_aggregate` now resolve member-path pointer facts through the original aggregate, including nested paths; stack-backed fields, returned/external aggregate pointers, aggregate pointer params, and reassigned unknown aliases remain plain. | `f4f13294 Track local aggregate pointer aliases in LLVM`; `tests/spec/data_race_semantics.mc` `aggregate_pointer_alias_global_pointer_field_load` / `nested_aggregate_pointer_alias_global_pointer_field_load` / `aggregate_pointer_alias_stack_pointer_field_stays_plain` / `aggregate_pointer_alias_returned_unknown_stays_plain` / `aggregate_pointer_param_field_stays_plain` / `aggregate_pointer_alias_reassigned_unknown_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM aggregate array pointer provenance is bounded and conservative | Direct local aggregate fields whose type is a fixed array of pointer-like elements now carry proven global-backed facts for constant-index literal elements and constant-index assignments; stack-backed elements, dynamic-index reads, and dynamic-index writes remain plain. | `5f493f09 Track aggregate array pointer provenance`; `tests/spec/data_race_semantics.mc` `aggregate_array_global_pointer_element_load` / `aggregate_array_assigned_global_pointer_element_load` / `aggregate_array_stack_pointer_element_stays_plain` / `aggregate_array_dynamic_index_pointer_element_stays_plain` / `aggregate_array_dynamic_assignment_clears_pointer_element_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM all-global dynamic-index pointer array reads are bounded and conservative | Direct local fixed pointer arrays and direct local aggregate pointer-array fields now lower dynamic-index derefs as unordered atomics only when every possible element is proven global-backed; partial arrays and arrays invalidated by dynamic writes remain plain, and the proof fails fast for large/incomplete arrays. | `0e1ae09d Lower dynamic global-backed pointer array reads`; `tests/spec/data_race_semantics.mc` `array_dynamic_index_all_global_pointer_elements_load` / `array_dynamic_index_assigned_all_global_pointer_elements_load` / `array_dynamic_index_partial_pointer_elements_stays_plain` / `array_dynamic_assignment_clears_pointer_element_fact` / `aggregate_array_dynamic_index_all_global_pointer_elements_load` / `aggregate_array_dynamic_index_assigned_all_global_pointer_elements_load` / `aggregate_array_dynamic_index_partial_pointer_elements_stays_plain` / `aggregate_array_dynamic_assignment_clears_pointer_element_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM aggregate pointer aliases compose with pointer-array fields | Local aggregate pointer aliases from direct `&local_aggregate` now resolve fixed pointer-array field element facts through the original aggregate for constant-index reads and all-global dynamic-index reads, while stack-backed, partial dynamic, returned/external, and reassigned aliases remain plain. | `f5223b8e Handle alias aggregate pointer arrays`; `tests/spec/data_race_semantics.mc` `aggregate_pointer_alias_array_global_pointer_element_load` / `aggregate_pointer_alias_array_dynamic_index_all_global_pointer_elements_load` / `aggregate_pointer_alias_array_stack_pointer_element_stays_plain` / `aggregate_pointer_alias_array_dynamic_index_partial_pointer_elements_stays_plain` / `aggregate_pointer_alias_array_returned_unknown_stays_plain` / `aggregate_pointer_alias_array_reassigned_unknown_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM aggregate pointer alias writes no longer leave stale provenance | Writes through local aggregate pointer aliases now update or clear the original aggregate's pointer-field and pointer-array facts, including dynamic-index array writes; reassigned/unknown aliases still do not mutate old local facts. | `b6f7365d Fix aggregate alias pointer write provenance`; `tests/spec/data_race_semantics.mc` `aggregate_pointer_alias_field_assignment_clears_direct_field_fact` / `aggregate_pointer_alias_field_assignment_clears_alias_field_fact` / `aggregate_pointer_alias_field_assignment_establishes_global_fact` / `aggregate_pointer_alias_reassigned_unknown_write_does_not_clear_old_field_fact` / `aggregate_pointer_alias_array_assignment_clears_element_fact` / `aggregate_pointer_alias_array_dynamic_assignment_clears_all_element_facts` / `aggregate_pointer_alias_array_assignment_establishes_element_fact` / `aggregate_pointer_alias_array_dynamic_index_assigned_all_global_pointer_elements_load` / `aggregate_pointer_alias_array_dynamic_index_partially_assigned_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM local slice pointer provenance is bounded and conservative | Local slice variables initialized from direct full-range slices of direct local fixed pointer arrays now preserve all-global pointer provenance for indexed reads; stack-backed, partial, backing-array writes, whole backing-array assignment, slice writes, slice reassignment, and calls clear or avoid the fact. | `7637af95 Track LLVM slice pointer provenance`; `tests/spec/data_race_semantics.mc` `slice_global_pointer_element_load` / `slice_assigned_global_pointer_element_load` / `slice_stack_pointer_element_stays_plain` / `slice_partial_pointer_elements_stays_plain` / `slice_backing_array_assignment_clears_fact` / `slice_backing_array_dynamic_assignment_clears_fact` / `slice_backing_array_whole_assignment_clears_fact` / `slice_element_assignment_clears_fact` / `slice_reassignment_clears_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM aggregate pointer-array slice provenance is bounded and conservative | Full-range local slices of direct local aggregate pointer-array fields, including fields reached through local aggregate pointer aliases, now preserve all-global pointer provenance for indexed reads; stack-backed, partial-range, backing aggregate writes, alias writes, and slice writes remain plain or conservatively clear facts. | `77b24fcd Preserve aggregate pointer slice provenance`; `tests/spec/data_race_semantics.mc` `aggregate_slice_global_pointer_element_load` / `aggregate_pointer_alias_slice_global_pointer_element_load` / `aggregate_slice_stack_pointer_element_stays_plain` / `aggregate_slice_partial_range_stays_plain` / `aggregate_slice_backing_array_assignment_clears_fact` / `aggregate_pointer_alias_slice_backing_assignment_clears_fact` / `aggregate_slice_element_assignment_clears_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`. |
| LLVM local pointer-to-array provenance is bounded and conservative | Direct local pointers initialized from `&local_fixed_pointer_array` now preserve all-global pointer provenance for dynamic indexed reads through `pa.*[index]`; stack-backed, partial, reassigned, call-crossing, and backing-write cases remain plain or conservatively clear facts. | `80d7b214 Prove local pointer array aliases in LLVM lowering`; `tests/spec/data_race_semantics.mc` `pointer_to_array_dynamic_index_all_global_pointer_elements_load` / `pointer_to_array_stack_pointer_elements_stays_plain` / `pointer_to_array_partial_pointer_elements_stays_plain` / `pointer_to_array_reassigned_pointer_stays_plain` / `pointer_to_array_backing_array_write_clears_fact`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM partial dynamic pointer-array reads are conservatively atomic | Dynamic-index reads from tracked pointer arrays, pointer-array fields, aggregate pointer aliases, full-range slices, and pointer-to-array aliases now lower the final scalar deref as unordered atomic when any possible backing element is proven global-backed; constant-index reads remain exact and all-local tracked sets remain plain. | `adc3ac8f Conservatively lower partial dynamic pointer arrays`; `tests/spec/data_race_semantics.mc` `array_dynamic_index_partial_pointer_elements_load` / `array_dynamic_index_all_local_pointer_elements_stays_plain` / `aggregate_array_dynamic_index_partial_pointer_elements_load` / `aggregate_pointer_alias_array_dynamic_index_partial_pointer_elements_load` / `aggregate_slice_partial_pointer_elements_load` / `aggregate_pointer_alias_slice_partial_pointer_elements_load` / `slice_partial_pointer_elements_load` / `pointer_to_array_partial_pointer_elements_load`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM constant partial-range pointer slices preserve provenance | Constant, in-bounds partial-range slices of direct local fixed pointer arrays and direct/alias aggregate pointer-array fields now retain backing range metadata; dynamic reads are conservatively atomic when any included backing element is global-backed, while constant reads map through the slice offset to exact backing element provenance and all-local ranges remain plain. | `8a412ab1 Track partial pointer slice provenance`; `tests/spec/data_race_semantics.mc` `slice_partial_range_pointer_elements_load` / `slice_partial_range_constant_global_element_load` / `slice_partial_range_constant_stack_element_stays_plain` / `slice_partial_range_all_local_stays_plain` / `aggregate_slice_partial_range_pointer_elements_load` / `aggregate_pointer_alias_slice_partial_range_pointer_elements_load` / `aggregate_slice_partial_range_constant_global_element_load` / `aggregate_slice_partial_range_constant_stack_element_stays_plain` / `aggregate_slice_partial_range_all_local_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM aggregate pointer params are proven for bounded direct calls | Internal, non-exported functions whose aggregate pointer params are passed direct local aggregate addresses at every direct call now seed intersected pointer-field facts in the callee, so `hp.ptr` and `hp.ptrs[index]` lower final derefs atomically when the field is proven global-backed; mixed, local-only, unknown, exported, indirect, escaped, and write-through cases remain plain or clear facts. | `c61c3da2 Prove aggregate pointer param provenance`; `tests/spec/data_race_semantics.mc` `consume_aggregate_global_param` / `consume_aggregate_array_global_param` / `consume_aggregate_mixed_param` / `consume_aggregate_unknown_address_param` / `consume_aggregate_indirect_escape_param` / `consume_aggregate_param_write_clears` / `exported_aggregate_global_param_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM aggregate pointer params are proven through bounded local function-pointer aliases | Same-function local function-pointer aliases initialized directly from internal functions now count as aggregate pointer-param call sites when passed direct local aggregate addresses with intersected global-backed field facts; reassigned and escaped aliases stay plain. | `ae176f59 Prove aggregate params through local fn aliases`; `tests/spec/data_race_semantics.mc` `consume_indirect_aggregate_alias_param` / `consume_indirect_aggregate_reassigned_param` / `consume_indirect_aggregate_reassigned_other_param` / `consume_aggregate_indirect_escape_param`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM constant-start dynamic-end pointer slices preserve conservative provenance | Local pointer-array slices with a constant start and dynamic end now retain conservative backing range metadata for direct local fixed pointer arrays and direct/alias aggregate pointer-array fields; dynamic reads are atomic when any possible backing element is global-backed, constant reads remain exact by `start + index`, and all-local possible ranges remain plain. | `de8e9c46 Preserve dynamic-end slice provenance`; `tests/spec/data_race_semantics.mc` `slice_dynamic_end_partial_pointer_elements_load` / `slice_dynamic_end_constant_global_element_load` / `slice_dynamic_end_constant_stack_element_stays_plain` / `slice_dynamic_end_all_local_stays_plain` / `aggregate_slice_dynamic_end_pointer_elements_load` / `aggregate_pointer_alias_slice_dynamic_end_pointer_elements_load`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM dynamic-start pointer slices preserve conservative provenance | Local pointer-array slices with dynamic starts or fully dynamic ranges now retain conservative possible backing ranges for direct local fixed pointer arrays and direct/alias aggregate pointer-array fields; dynamic reads are atomic when any possible backing element is global-backed, constant-index reads from non-exact-start slices are conservative rather than falsely exact, and all-local ranges remain plain. | `721e6502 Preserve provenance for dynamic-start slices`; `tests/spec/data_race_semantics.mc` `slice_dynamic_start_pointer_elements_load` / `slice_dynamic_start_constant_index_is_conservative` / `slice_dynamic_start_all_local_stays_plain` / `slice_fully_dynamic_pointer_elements_load` / `aggregate_slice_dynamic_start_pointer_elements_load` / `aggregate_pointer_alias_slice_fully_dynamic_pointer_elements_load`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM internal aggregate-return pointer provenance is bounded and conservative | Internal, non-exported helpers with a single struct-literal return now summarize returned pointer-field and pointer-array element facts, so local aggregate init/assignment from those calls preserves global-backed provenance while exported/external aggregate-return ambiguity remains plain. | `e9d5d98e Propagate aggregate return pointer provenance`; `tests/spec/data_race_semantics.mc` `aggregate_computed_copy_pointer_field_load` / `aggregate_return_init_pointer_field_load` / `aggregate_return_array_dynamic_index_pointer_element_load` / `aggregate_exported_return_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM local aggregate-return pointer provenance is bounded and conservative | Internal, non-exported helpers with straight-line local aggregate declarations or whole-local assignments followed by `return local` now summarize the returned local's pointer-field and pointer-array element facts; branchy/control-flow helpers still fail closed. | `6ccdb716 Summarize local aggregate return provenance`; `tests/spec/data_race_semantics.mc` `aggregate_return_local_init_pointer_field_load` / `aggregate_return_local_assignment_pointer_field_load` / `aggregate_return_array_local_dynamic_index_pointer_element_load`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`. |
| LLVM simple branch aggregate-return pointer provenance is bounded and conservative | Internal, non-exported helpers whose simple boolean `if` return paths all return direct struct literals with the same proven global-backed pointer fields now summarize those fields by intersection; mixed global/local branches stay plain and broader control flow still fails closed. | `4aecd95c Summarize branch aggregate returns`; `tests/spec/data_race_semantics.mc` `aggregate_return_if_pointer_field_load` / `aggregate_return_mixed_if_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM branch-local aggregate-return pointer provenance is bounded and conservative | Simple boolean aggregate-return branches can now return branch-local aggregate values proven within each isolated path, including one returning `if` arm plus a straight-line trailing local return; facts are still intersected across paths, so mixed stack/global paths remain plain. | `00151b3e Summarize branch-local aggregate returns`; `tests/spec/data_race_semantics.mc` `aggregate_return_branch_local_if_pointer_field_load` / `aggregate_return_mixed_branch_local_if_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM simple switch aggregate-return pointer provenance is bounded and conservative | Internal aggregate-return helpers can now summarize simple switch return paths when the switch is bool-exhaustive or has an explicit wildcard arm; each arm must use an already-supported simple return path, and facts are intersected so mixed stack/global arms remain plain. | `1dc3938c Track aggregate returns through simple switches`; `tests/spec/data_race_semantics.mc` `aggregate_return_switch_pointer_field_load` / `aggregate_return_mixed_switch_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM aggregate-return summaries tolerate simple pre-return provenance code | Internal aggregate-return helpers can now summarize final struct-literal returns and returned locals after simple local declarations or direct local assignments that the provenance tracker can model; unknown calls, unsupported statements, field/deref writes, and stack-backed overwrites remain plain. | `d27042f4 Summarize pre-return aggregate provenance`; `tests/spec/data_race_semantics.mc` `aggregate_return_prereturn_literal_pointer_field_load` / `aggregate_return_prereturn_local_pointer_field_load` / `aggregate_return_prereturn_reassigned_stack_pointer_field_stays_plain` / `aggregate_return_prereturn_unknown_call_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| LLVM prefixed branch/switch aggregate-return summaries are bounded and conservative | Internal aggregate-return helpers can now summarize simple bool-if and exhaustive/wildcard switch return paths after a straight-line prefix of provenance-trackable local declarations or direct local assignments; unknown prefix calls and mixed stack/global branches remain plain. | `165b9230 Support prefixed aggregate return branch summaries`; `tests/spec/data_race_semantics.mc` `aggregate_return_prefix_bool_switch_pointer_field_load` / `aggregate_return_prefix_wildcard_switch_pointer_field_load` / `aggregate_return_prefix_unknown_call_switch_pointer_field_stays_plain` / `aggregate_return_prefix_mixed_switch_pointer_field_stays_plain`; `src/lower_llvm_tests.zig`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| Arrays of `move` resources fail closed as an accepted limitation | Element-place tracking is still deferred, but arrays that embed linear `move` resources are now rejected through aliases, nested arrays, globals, parameters, return types, struct fields, and explicit locals instead of relying on the move pass to notice only some value bindings. | `440e7ad9 Fail closed on move arrays in sema`; `tests/spec/move_cfg.mc` `BadArrayAlias` / `BadNestedArrayAlias` / `reject_move_array_return` / `reject_move_array_param` / `bad_move_array_global` / `reject_move_array_local`; `zig build test`; direct `mcc check tests/spec/move_cfg.mc` emits expected `E_MOVE_ARRAY_UNSUPPORTED` diagnostics. |
| Spec C/LLVM sweep gates are green for in-scope fixtures | Mixed accept/reject fixtures no longer leave dangling references after reject stripping, so backend sweeps catch real regressions instead of fixture-shape noise. | `4990226c Split mixed spec sweep fixtures`; `JOBS=8 tools/toolchain/spec-emit-sweep.py zig-out/bin/mcc tests/spec`; `JOBS=8 tools/toolchain/spec-llvm-sweep.py zig-out/bin/mcc tests/spec`. |
| Rich diagnostic output is implemented and gated | Text diagnostics include source snippets/carets and notes; `mcc check --json` emits structured severity, code, message, mapped path/file, span, source/caret, notes, and counts; LSP consumes the JSON path and turns compiler notes into `relatedInformation`. Terminal color remains a polish gap, not a blocker for structured diagnostics. | `d947f211 docs: retire rich diagnostics readiness item`; `3e74d7b4 Refresh diagnostics ownership gates`; `src/diagnostics.zig` `Diagnostic.notes`, `Reporter.render`, `Reporter.appendJson`, and reporter JSON/notes tests; `src/main.zig` `check --json`; `tools/toolchain/diagnostics-test.sh`; `tools/toolchain/diagnostics-reference.py`; `tools/toolchain/diagnostic-code-inventory.py`; `tools/lsp/mc-lsp.py` JSON diagnostics parser; `tools/lsp/lsp-test.py` monomorphization notes-to-related-information assertion. |
| Labeled async loop jumps are implemented | `break :label` and `continue :label` inside await-bearing async loops now resolve to the named source loop's state-machine exit/head rather than being rejected or accidentally targeting an inner copied loop. | `1f4e67e9 Support labeled async loop jumps`; `src/async_lower.zig` async loop target stack and labeled poll-loop edge; `tests/c_emit/fuzz_async_loop_breakcont.mc` labeled break/continue fixture; focused C/LLVM fixture probe returns `1` on both backends. |
| Async reserved forms fail closed with check-mode diagnostics | The remaining reserved async forms named by the roadmap are now gated under `mcc check`: dyn-future await / unresolved future expressions, await-bearing `for` loops, constructor-formed borrow-across-await, and first-await self-reference/pinning all reject with stable explicit diagnostic codes instead of relying only on backend rejection. | `6f636d56 Gate async reserved forms under check`; `tests/c_emit/bad/async_await_unresolved_dyn.mc`; `tests/c_emit/bad/async_for_await_nested.mc`; `tests/c_emit/bad/async_borrow_across_await.mc`; `tests/c_emit/bad/async_borrow_pinning.mc`; `tests/diagnostics/bad-golden.tsv`; `python3 tools/toolchain/bad-diagnostics-test.py --check`. |
| Release artifact packaging and local qualification gates are implemented | Repo-local gates now prove pinned release metadata, ReleaseSafe installability, deterministic tarballs, SHA256SUMS, release inventory, CycloneDX SBOM, required payload docs/files, tag-version rejection, GitHub/Sigstore attestation wiring, and release workflow upload staging. | `7e0d4592 docs: narrow release qualification ledger item`; `.github/workflows/release.yml`; `tools/ci/package-release.py`; `tools/toolchain/release-metadata-test.py`; `tools/toolchain/package-release-test.py`; `tools/toolchain/release-safe-install-test.sh`; `build/qemu.zig`; `build/tiers.zig`; `docs/release-process.md`; `SECURITY.md`; `STABILITY.md`; `CHANGELOG.md`; `zig build release-metadata-test package-release-test release-safe-install-test`. |
| Release publication-control evidence is reproducible | The external GitHub publication-control checks are now captured in a read-only audit script instead of ad hoc terminal history, so branch protection, release workflow run evidence, and GitHub Release publication state can be rerun and archived for a release candidate. | `d32d9cae Add release publication audit`; `tools/toolchain/release-publication-audit.sh`; `docs/release-process.md`; `bash -n tools/toolchain/release-publication-audit.sh`; current `bash tools/toolchain/release-publication-audit.sh` exits nonzero as expected with missing branch protection, no recent `release.yml` runs, and no GitHub Releases; `zig build test`; `git diff --check`. |
| Typed semantic fact table design is concrete and phased | The architecture bucket now has explicit invariants, data-shape options, migration phases, first fact-family candidates, backend consumption rules, fail-closed behavior, and acceptance criteria instead of remaining a vague rewrite note. | `5f115920 docs: design typed semantic facts`; `docs/typed-semantic-facts.md`; `rg -n "typed-semantic|semantic fact|typed fact" docs src`; `git diff --check`; `zig build test`. |
| Typed semantic facts Phase 1 inventory/stabilization is complete | The current fact-like producers, representations, invalidation points, artifact printers, and backend consumers are now inventoried with code anchors, and a read-only checker fails closed if important anchors drift. This closes only Phase 1; no typed fact family has been migrated yet. | `docs/typed-semantic-facts.md` Phase 1 inventory; `tools/toolchain/semantic-facts-inventory.py`; `python3 tools/toolchain/semantic-facts-inventory.py`; `rg -n "typed-semantic|semantic fact|typed fact" docs src`; `git diff --check`; `zig build test`. |
| Typed semantic facts Phase 2 pointer-provenance table is in MIR | MIR now owns a narrow typed `PointerProvenanceFact` slice for direct pointer-like locals and direct fixed local pointer-array elements initialized or assigned from visible address expressions, with explicit `global_storage`/`local_storage`/`unknown`, source points, optional element indexes, and fail-closed invalidation rows for reassignment, dynamic-index writes, calls, indirect calls, and address escape. This closes only the Phase 2 table/artifact/test slice; backend migration remains pending. | `src/mir_model.zig` `PointerProvenanceFact`; `src/mir.zig` `recordPointerProvenanceForLocalInitializer`, `recordPointerProvenanceForAssignment`, `recordPointerProvenanceCallInvalidation`, and `mir pointer_provenance_fact`; `src/mir_tests.zig` pointer provenance tests; `docs/typed-semantic-facts.md` Phase 2 status; `python3 tools/toolchain/semantic-facts-inventory.py`; `zig test src/mir_tests.zig`; `zig build test`; `git diff --check`. |
| Typed semantic facts Phase 3 LLVM narrow pointer-provenance consumption is complete | LLVM lowering now consumes MIR `PointerProvenanceFact` rows for direct pointer-like locals and direct fixed local pointer-array elements, seeding unordered atomic pointer-mediated global loads only for live `global_storage` rows and clearing/avoiding facts for `local_storage`, `unknown`, dynamic-index invalidation, and call invalidation. This closes only the LLVM narrow subset; broader LLVM provenance cleanup remains pending. | `src/lower_llvm.zig` `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, `applyMirPointerProvenanceForIndexAssignment`, and `applyMirPointerProvenanceInvalidationsAtCall`; `src/lower_llvm_tests.zig`; `tests/spec/data_race_semantics.mc` `pointer_global_invalidated_by_call_stays_plain`; `docs/typed-semantic-facts.md` Phase 3 status; `python3 tools/toolchain/semantic-facts-inventory.py`; `zig test src/lower_llvm_tests.zig`; `zig build test`; `git diff --check`. |
| Typed semantic facts Phase 4 C narrow pointer-provenance consumption is complete | C lowering now consumes MIR `PointerProvenanceFact` rows for direct pointer-like locals and direct fixed local pointer-array elements at initializer, assignment, index-assignment, and call-invalidation source points. Live `global_storage` facts route scalar pointer deref loads/stores through `mc_race_load_*` / `mc_race_store_*` using the pointer expression; `local_storage`, `unknown`, dynamic-index writes, invalidated facts, absent facts, and non-constant indexes keep the existing plain deref behavior. This closes only the narrow C slice; broader LLVM cleanup remains pending. | `src/lower_c_emitter.zig` `applyMirPointerProvenanceForLocalInitializer`, `applyMirPointerProvenanceForAssignment`, `applyMirPointerProvenanceForIndexAssignment`, `applyMirPointerProvenanceInvalidationsAtCall`, and `mirPointerProvenanceDerefRaceInfo`; `src/lower_c_tests.zig` `lower-c consumes MIR pointer provenance facts for direct scalar pointer derefs` / `lower-c consumes MIR pointer provenance facts for fixed pointer-array elements`; `docs/typed-semantic-facts.md` Phase 4 status; `python3 tools/toolchain/semantic-facts-inventory.py`; `zig test src/lower_c_tests.zig`; `zig build test`; `git diff --check`. |

### In Progress

| Item | Current state | Next evidence needed |
|---|---|---|
| None currently assigned | The last assigned implementation slice was merged into `master`. | Pick the next pending item, create a detached worktree, and delegate a bounded slice. |

### Pending

| Item | Why it remains | First next step |
|---|---|---|
| Broader pointer-provenance race lowering | The LLVM backend now handles direct address-of global derefs, simple local pointer copies, raw-many constant zero offsets from already-proven global-backed pointer locals, internal helpers proven to return global-backed pointers, bounded internal direct-call pointer parameters, bounded scalar pointer parameters through same-function local function-pointer aliases and copied local aliases, bounded internal aggregate pointer parameters including same-function local function-pointer aliases and copied local aliases, bounded internal aggregate returns with single struct-literal bodies, straight-line returned locals, simple pre-return local declarations/assignments, simple boolean branch return paths whose direct struct-literal return facts intersect, simple boolean branch paths that return branch-local aggregate values proven within each path, simple exhaustive-or-wildcard switch return paths whose facts intersect, and those same simple branch/switch shapes after a provenance-trackable straight-line prefix, bounded direct and nested local aggregate pointer fields, direct same-struct local aggregate copies, constant-index local pointer arrays, constant-index aggregate array pointer fields, all-global and partially-global dynamic-index fixed pointer arrays, all-global and partially-global dynamic-index aggregate pointer-array fields, local full-range, constant partial-range, constant-start dynamic-end, dynamic-start constant-end, and fully dynamic slices of tracked fixed pointer arrays, full-range, constant partial-range, constant-start dynamic-end, dynamic-start constant-end, and fully dynamic slices of tracked aggregate pointer-array fields, local pointer-to-array aliases from direct `&local_fixed_pointer_array`, and local aggregate-pointer aliases from direct `&local_aggregate` including fixed pointer-array fields and range-preserving field slices, but nonzero/dynamic pointer arithmetic, escaped pointers, broader non-local or higher-order indirect-call flows, exported/external ambiguity, aggregate returns through unknown side effects or arbitrary CFG, and non-local/reassigned aggregate storage are not yet proven as global-backed. | Decide whether to add sema/MIR provenance facts or conservatively unordered-atomic all scalar derefs whose storage cannot be proven local/raw/MMIO. |
| Typed semantic fact table / typed MIR | The design slice, Phase 1 inventory/stabilization, Phase 2 narrow MIR pointer-provenance table, Phase 3 LLVM narrow subset consumption, and Phase 4 C narrow subset consumption are complete in `docs/typed-semantic-facts.md`, but LLVM still carries broader duplicated provenance inference for unsupported shapes. | Do the remaining Phase 5 cleanup that retires duplicated LLVM AST inference only where typed facts cover equivalent behavior. |
| CFG/place-based move checker | Current move checker is much stronger, and arrays of `move` resources are now an explicit fail-closed limitation via `E_MOVE_ARRAY_UNSUPPORTED`; deeper path sensitivity remains deferred until the planned CFG/place model. | Design the CFG/place rewrite around remaining non-array path-sensitivity limits, or explicitly document those limits as accepted until the rewrite. |
| Release publication controls | Local release packaging, checksums, SBOM/inventory, and GitHub/Sigstore attestation wiring are now audited and gated. External GitHub publication-control evidence is now reproducible with `tools/toolchain/release-publication-audit.sh`, but the current public repo evidence still fails/pends: branch protection is absent, no recent `release.yml` run exists, and no GitHub Release exists. Detached minisign signatures also remain undecided separate from GitHub artifact attestations. | Enable/prove branch protection, run and record a successful release workflow dry run or tag release, publish the first GitHub Release when appropriate, then rerun `bash tools/toolchain/release-publication-audit.sh`; decide whether detached minisign signatures are required or explicitly accept GitHub/Sigstore attestations as the release signing story. |

### Current Working Rules

- Use detached worktrees and subagents for implementation slices.
- Do not create PRs or long-lived integration branches.
- Cherry-pick reviewed commits directly to `master`, verify on `master`, then push.
- Do not mark the goal complete until every pending item is either fixed, explicitly
  documented as an accepted limitation, or has stronger current evidence proving it is
  already done.

This is the compiler-side companion to
[`production-readiness-plan.md`](production-readiness-plan.md), which qualifies the
*kernel/appliance* product. Scope here is the toolchain an external team would adopt:

- the compiler implementation in `src/` (~67k LoC Zig, 110 files),
- its toolchain surface (`tools/lsp/`, `tools/fuzz/`, `src/fmt.zig`, `editors/`),
- the test/CI system as it qualifies the compiler,
- distribution, versioning, and supply chain.

Method: seven parallel, code-grounded reviews (front-end robustness; semantics and
soundness; MIR and backends; Zig implementation quality; toolchain UX and
distribution; testing and CI; security and supply chain), each citing `file:line`
evidence, plus targeted empirical probes against a locally built `mcc`. Findings are
tagged:

- **[confirmed]** — demonstrated at review time (a probe was run and the behavior
  observed).
- **[inspected]** — established by code reading; the cited lines were verified to say
  what is claimed, but no runtime repro was executed. **Write a probe before fixing**
  — this repo has been burned before by acting on unverified review claims
  (the retired `review.md`'s soundness claims were empirically disproven).

Severity: **P0** = crash/hang on user input, silent miscompile, silent-unsound
acceptance of a spec'd feature, or an absolute day-one adoption blocker. **P1** = must
fix before any production claim. **P2** = polish/hygiene.

---

## 1. The bar

"Production grade" for `mcc` means a competent external team could adopt it:

1. **Install** a versioned release on macOS/Linux without building this repo.
2. **Compile real programs** and never see a compiler crash or hang on *any* input —
   malformed, adversarial, or enormous. Only diagnostics.
3. **Trust the output**: no silent miscompiles; anything unsupported fails loudly at
   compile time; ABI-correct against clang-compiled objects.
4. **Get IDE-quality errors**: right file, right line, many per run, source context,
   machine-readable; editor integration that works out of the box.
5. **Rely on process**: docs that match the implementation, a stability policy, a
   changelog, a security-report channel, and bugs triageable against a version.

`README.md` already says, honestly: "MC is still a prototype … it is not a production
C replacement." This document quantifies the distance and lays out the path.

## 2. Verdict

**mcc is an unusually disciplined prototype — roughly C+ overall against the bar
above — with the gap concentrated in four enumerable classes, not diffuse decay:**

1. **Crash/hang classes reachable from ordinary input** (unbounded parser recursion,
   uncapped monomorphization, unguarded 128-bit comptime arithmetic).
2. **A small number of silent-acceptance soundness holes in spec'd features**
   (closures essentially unchecked; a `while`-condition gap in the move checker;
   uninstantiated generics never checked).
3. **Codegen trust that rests on enumerated fixtures rather than construction** —
   both backends independently re-derive semantics from the raw AST, and the
   project's own fix history shows that drift class is live (plus one confirmed
   parity asymmetry and one latent extern-ABI hazard).
4. **Zero distribution surface** — no tags, no versions, no releases, no install
   layout, no `mcc build`, no stability policy.

The counterweight is real: verification culture here is far beyond prototype norm
(hosted CI running the full ~570-gate `m0` suite with anti-vacuity checks,
two-backend differential testing, an 820+-marker negative-diagnostic corpus, a UB
matrix that is actually
implemented, refusal-over-guessing in the backends, unconditional soundness checks
with no unsound compiler mode). Most Phase 0/1 items below are days-scale; the
expensive items are the architectural ones (typed semantic facts, parser recovery,
extern ABI, incremental compilation).

### Scorecard

| Dimension | Grade | One-line summary |
|---|---|---|
| Front-end robustness & diagnostics | **C-** | Total lexer, cycle-safe loader, 194+ error codes — but the parser segfaults on ~600-deep nesting, bails at the first error, and misattributes cross-file diagnostics. |
| Semantics & soundness | **C+** | No unsound mode, fail-closed culture, coherent traits — but closures are unchecked, the move checker misses `while`-condition consumption, and unused generics are never checked. |
| MIR & backends | **C+** | Implemented UB matrix, `-Werror`+sanitizer gates, loud refusal — but parity is empirical (AST re-lowered twice), one elision asymmetry is live, and extern struct-by-value on LLVM is an ABI hazard. |
| Zig implementation quality | **C+** | Clean panic discipline, fueled comptime, exceptional comments — but unbounded recursion/instantiation, fail-open OOM paths, whole-program single-threaded architecture, Debug default. |
| Toolchain UX & distribution | **D+** | CI-gated LSP/formatter/spec — but no releases, no version, no install story, no build driver, repo-coupled everything. |
| Testing & CI | **B-** | Hosted CI, ~570 gates, systematic negative tests, differential fuzzing — but independent oracles ungated, fixed-seed fuzzing, coverage unmeasured, no release qualification. |
| Security & supply chain | **C+** | No shell-outs, injection closed, exemplary BearSSL vendoring — but no CVE process for 3 of 4 vendored engines, no SECURITY.md, unverified toolchain downloads. |

## 3. What is already strong (protect it)

These are production-grade properties today; regressions here would be expensive.

- **No unsound compiler mode exists.** Every static soundness check runs
  unconditionally; the only check-related flags are `--checks=all|elide-proven|ksan|msan|csan`
  (`src/cli.zig:93-112`), and `elide-proven` removes only optimizer-proven-dead traps
  (parity-gated). "Opt-in hardening" means annotation-driven types, not disable-able
  checks.
- **Fail-closed bias in sema.** Non-slice→slice casts, deref move-outs,
  pointer-to-int borrow laundering, `#[no_lang_trap]` violations: rejected, not
  trusted (`src/sema.zig:2502-2510`, `src/sema_move.zig:707-738,992-1034`).
  `#[no_lang_trap]` is enforced twice — sema and independently the MIR verifier.
- **Refusal over guessing in the backends.** 165 `UnsupportedCEmission` + 311
  `UnsupportedLlvmEmission` sites fail loudly rather than emit a guess; MIR-verifier
  failures are diagnostics that abort emit, never panics.
- **The UB matrix is implemented, not aspirational.** u8/u16 wrap arithmetic computes
  in `unsigned int` to defeat C promotion (`src/lower_c_arith.zig:206-209,403-415`);
  MMIO goes through `volatile` helpers and `volatile` struct fields
  (`src/lower_c_runtime.zig:419-447`, `src/lower_c_mmio.zig:273`); compound
  expressions decompose into sequenced temporaries; the ambiguous multi-MMIO-read
  case is *rejected*. Emitted C compiles `-std=c11 -Wall -Wextra -Werror` with
  documented defense-in-depth flags (`tools/toolchain/mcc-cc.sh:89`).
- **Layout is single-sourced and cross-checked against clang.**
  `comptimeStructLayout` is shared by both backends (`src/layout.zig`);
  `abi-test.sh` `_Static_assert`s MC's sizes/offsets against clang's real
  `offsetof`/`_Alignof`; `emit-layout`/`emit-c-struct` make MC↔C mirror drift a
  compile error.
- **Hosted CI with anti-vacuity engineering.** `.github/workflows/ci.yml` runs
  `MC_REQUIRE_TOOLS=1 zig build m0`, fails on any `SKIP:` line, and positively
  asserts 26 async gate names printed `PASS:`; a second job builds the Docker image
  and runs `fast` + `preflight` + the full `riscv-qemu-validation` tier inside it.
- **Negative diagnostics are systematic and bidirectional.** 821 `EXPECT_ERROR`
  markers across `tests/spec/` (counted at the review snapshot), checked in both
  directions — every marker must fire
  on its exact line AND every emitted spec diagnostic must have a marker
  (`src/spec_tests.zig:375-443,502-506`); `bad/` corpora must fail with the *named
  code*, not just any error.
- **The fuzzer has caught real miscompiles and locks them down.** 7 mcfuzz oracles
  (differential, UBSan, trap-consistency, robust, fail-closed, determinism, pipeline)
  are required in `m0` (`build/tiers.zig:60-68`); three found-and-fixed C-backend
  bugs are distilled into required fixtures.
- **Trait system coherence.** Duplicate `impl (Trait, Type)` is a whole-program
  error; method ambiguity is a hard error, never iteration-order; dyn-safety and
  linearity-through-dispatch are checked (`src/sema.zig:5281-5305,2977-2982,2613-2615`).
- **Comptime evaluation is fueled.** Recursion capped at 256, comptime loops at 1M
  iterations, layout recursion at depth 32 (`src/eval.zig:341-343,1065-1067`,
  `src/layout.zig:49`); imports dedup by canonical path so cycles terminate
  **[confirmed]**; input files capped at 64 MiB.
- **The compiler is a hard target in itself.** No `std.process.Child` anywhere in
  `src/` (it never shells out); emitted-C string/identifier injection is closed by
  lexer constraints + mangling **[inspected]**; `#line` paths are escaped; no secrets
  in the repo; licenses are compatible (MIT root; MIT/BSD/Apache-2 deps).
- **Toolchain hygiene where it was deliberately built:** Zig pinned to 0.16.0 in CI
  and Docker; byte-determinism gate (`reproducible-build-test`); token-preserving
  idempotent formatter with a `--check` mode, gated; LSP shells out to `mcc` so it
  cannot drift semantically, and is CI-gated end-to-end; a 5.5k-line spec with an
  enforced spec-section coverage gate; `docs/README.md` maps which documents to
  trust. Zero `TODO`/`FIXME` in 67k lines; invariant comments are exceptional.

## 4. Top blockers, ranked

The shortest path to "production grade" runs through these. Details in §5.

| # | Sev | Item | Dimension | Effort |
|---|---|---|---|---|
| 1 | P0 | Parser recursion segfaults at ~600-deep nesting **[confirmed]** | Front-end | S |
| 2 | P0 | Closures accepted with no type checking (miscast indirect calls, dangling env) **[inspected]** | Sema | M |
| 3 | P0 | Move checker misses `while`-condition consumption → accepts double-free **[inspected]** | Sema | S |
| 4 | P0 | LLVM emits first-class aggregates at `extern` boundaries — no C ABI classification **[inspected]** | Backends | S (forbid) / L (implement) |
| 5 | P0 | No releases, no version, no install path, no `mcc build` driver | Distribution | M |
| 6 | P1 | Monomorphization has no instantiation/depth cap → hang/OOM on polymorphic recursion **[inspected]** | Sema | S |
| 7 | P1 | Cross-file diagnostics report the wrong file + flattened line numbers **[confirmed]** | Front-end | S-M |
| 8 | P1 | Release-mode check elision matches span-only on LLVM (C filters by function) — parity divergence **[inspected]** | Backends | S |
| 9 | P1 | Both backends re-derive semantics from the AST — the standing drift class | Architecture | L |
| 10 | P1 | Lowering-coverage instrument rotted after the file split; independent fuzz oracles not gated | Testing | S-M |
| 11 | P1 | Error-UX floor: Zig traces after every failed compile, first-error parser bail, no snippets **[confirmed]** | Front-end | S-L |
| 12 | P1 | LLVM major unpinned in CI/Docker; no toolchain support matrix | Testing/Backends | M |

## 5. Findings by dimension

Format: severity, title, evidence, impact, fix (effort), confidence.

### 5.1 Front-end robustness & diagnostics — C-

Strengths: the lexer is total (EOF-guarded peeks, zero `unreachable` in
lexer/parser/loader/ast; NUL, invalid UTF-8, and empty files produce clean
diagnostics **[confirmed]**); unterminated tokens get specific diagnostics with
resync; the loader dedups imports by canonical path so cycles and diamonds terminate
**[confirmed]**; sema accumulates many diagnostics per run with ~194 distinct
greppable `E_*` codes across 410 call sites.

- **[P0] Unbounded recursive descent → segfault on deep nesting.** No depth counter
  anywhere in `src/parser.zig` (`parseExpr`→`parsePrefix`→`parsePrimary`→`parseExpr`
  via `(`, :1370/:1416/:1471; also `parseType` :1226, `parseBlock` :786). Empirical:
  ~600 nested parens OK, ~700 segfaults (Debug binary); also unary chains, nested
  blocks, pointer types. Every downstream pass (sema `checkExpr`, hir/ir/mir walks,
  both emitters) recurses the same tree shape. The `fuzz-robust` oracle cannot find
  this: it byte-mutates valid seeds and never synthesizes deep balanced nesting.
  Fix: one nesting-depth counter in the Parser (error past ~256 with a clean
  "nesting too deep" diagnostic) bounds every downstream pass. Effort S.
  **[confirmed]**
- **[P1] Every failed compile prints a Zig error-return trace after the diagnostic.**
  `run*` functions return `error.CheckFailed` etc. to `main` (`src/main.zig:262,370`),
  so a one-character typo prints the correct diagnostic *followed by*
  `error: CheckFailed` + a hex-address trace into mcc's own source — indistinguishable
  from an ICE. Users will file every diagnostic as a compiler bug. Fix: catch the
  expected error set in `main`, exit(1) silently (diagnostics already rendered);
  reserve traces for unexpected errors. Effort S. **[confirmed]**
- **[P1] Cross-file diagnostics: wrong file, flattened line numbers.** The Reporter
  is constructed once with the root path + import-flattened source
  (`src/main.zig:138`); `render()` prints `self.path:span.line`
  (`src/diagnostics.zig:65-78`). The `FileBoundary` table exists but is consumed only
  by the orphan rule and private-name mangling, never by rendering. An error in
  `sub/lib.mc:2` reports as `root.mc:5` **[confirmed]** — at kernel scale,
  `root.mc:48213`-style nonsense. The LSP inherits this. Fix: map `span.offset`
  through `combined_boundaries` in `render()` (last boundary with `start <= offset`,
  subtract its starting line). Effort S-M. **[confirmed]**
- **[P1] Missing import ⇒ raw `error.ImportNotFound` + Zig trace, no path, no
  location.** `src/loader.zig:140-142` swallows the failing path;
  `scanImports` has the span in hand and discards it. One of the most common user
  errors yields zero actionable information. Fix: thread the Reporter into
  `expand`/`scanImports`; report `cannot find import "X"` at the import's span.
  Effort S. **[confirmed]**
- **[P1] Parser reports one error per run.** `fail()` (`src/parser.zig:1818-1821`)
  unwinds the whole parse via `try`; there is no statement/decl-level resync
  **[confirmed]** (two broken decls → only the first reported). Sema accumulates;
  the gap is parser-only. Fix: synchronize to `;`/`}`/top-level keywords and
  continue. Effort L.
- **[P1] No source snippets, carets, notes, colors, JSON, or structured codes.**
  `src/diagnostics.zig` is 80 lines; `Diagnostic` = severity/span/message (codes are
  string-prefixed into messages by sema; lexer/parser messages have no codes). The
  LSP scrapes text lines. Fix: add notes/related-spans/code fields, a caret renderer,
  and `--json`. Effort M-L.
- **[P2] Integer literals larger than u128 are silently accepted and emitted
  verbatim.** `parseIntegerLiteral` returns null on u128 overflow and
  `checkIntegerLiteralInitializer` treats null as "not checkable"
  (`src/sema.zig:4131`, `src/numeric.zig:55-64`); `let x: u32 = 2^128` passes
  `check` and emits garbage C **[confirmed]**. Fix: null-on-integer-syntax ⇒
  `E_INTEGER_LITERAL_OUT_OF_RANGE`. Effort S.
- **[P2] UTF-8 BOM rejected as `unexpected byte`** **[confirmed]** (no BOM skip in
  `Lexer.init`; `src/lexer.zig:344,61-64`). Windows-editor files fail cryptically.
  Effort S.
- **[P2] OOM fail-open: diagnostics can vanish.** `Reporter.add` does
  `allocPrint(...) catch return` / `append(...) catch return` *without setting
  `has_errors`* (`src/diagnostics.zig:52-61`) — under allocation failure an error
  disappears and compilation proceeds as clean. Same pattern in comptime folding:
  `widths.put(...) catch {}` (`src/eval.zig:432-441`) silently degrades fold widths.
  A compiler must fail closed under OOM. Effort S. **[inspected]**

### 5.2 Semantics & soundness — C+

Strengths: see §3 (no unsound mode; fail-closed; coherent dyn-safe traits;
check/verify reconciliation; rich domain typing; language-wide shadowing ban that
keeps the name-keyed analyses sound).

- **[P0] Closures are spec'd but semantically unchecked.** Spec §9.1 defines
  `closure(...)->Ret` + `bind(env, f)` (`docs/spec/MC_0.7_Final_Design.md:1136-1166`).
  In sema, `bind(...)` falls through the return-class resolver to `.unknown`
  (`src/sema.zig:2754`), and `canInitialize` accepts `.unknown` against anything
  (`src/sema.zig:6112`) — no check that the env matches the callee's first param or
  that the signature matches the annotation. Calls *through* closures get no
  arg-count/type validation: `calleeFnPointerType` matches only `.fn_pointer`, not
  closure types (`src/sema.zig:6731-6738`). No `E_CLOSURE*`/`E_BIND*` code exists.
  The C backend then lowers `bind` with deliberate type-erasing `void*` casts
  (`src/lower_c_emitter.zig:3588-3596`) — a mismatched bind becomes a miscast
  indirect call. The spec's env-outlives-closure rule is also unenforced
  (closures aren't pointer-classed, so `checkLocalAddressReturn` never fires on
  returning `bind(&local, f)`). Fix: type `bind` (env vs first param; result is a
  concrete closure type), extend callee checking to closure types, include closures
  in local-escape checks. Effort M. **[inspected — accept-side verified at the cited
  lines; write a runtime miscompile PoC before/while fixing]**
- **[P0] Move checker misses by-value consumption in `while` conditions.** Loop
  conditions/iterables get `moveBorrow` only (`src/sema_move.zig:342`), while `if`
  conditions and `switch` subjects are properly consumed (`:380`, `:413`). So
  `while (eat(t)) {} free(t);` — with `eat` consuming a linear `t` by value —
  records no consumption: the per-iteration re-consumption that
  `E_MOVE_LOOP_RESOURCE` catches in loop *bodies* is invisible in the *condition*,
  and the trailing `free(t)` is accepted. Exactly the double-free class `move`
  exists to prevent; no spec test covers a consuming while-condition. Fix: analyze
  the condition like a body region (clone state, consume, diff against entry ⇒
  `E_MOVE_LOOP_RESOURCE`); keep borrow-only for `for` iterables. Add spec tests.
  Effort S. **[inspected]**
- **[P1] Generic bodies are checked only per-instantiation; uninstantiated generics
  are never checked.** Monomorphization runs *before* sema and drops generic decls
  outright (`continue; // dropped; replaced by instances`,
  `src/monomorphize.zig:226,230,234`). A generic with no call sites ships with an
  entirely unchecked body (name resolution, types, unsafe-gating — nothing). Note:
  the G32 fix in the project ledger closed this in the mcc2 *subset* compiler, not
  in `src/`. Fix: minimum — name-resolution/arity/unsafe-gating over generic bodies
  pre-drop; better — a check-only instantiation with opaque placeholders honoring
  `where` bounds. Effort M-L. **[inspected]**
- **[P1] No monomorphization limits.** The specialization worklists loop to fixpoint
  with no depth counter, instance cap, or cycle detection
  (`src/monomorphize.zig:249-298`); dedup is by mangled name, and comptime args fold
  at rewrite time, so `fn f(comptime N: usize){ f(N+1); }` (or `f<Wrap<T>>`) mints
  new names forever — hang/OOM on 3 lines of source, and a DoS on shared CI. Fix:
  instantiation-depth + total-instance ceilings with a diagnostic naming the chain.
  Effort S. **[inspected]**
- **[P1] Definite-init tracks only scalar `uninit` vars.** Aggregates are excluded
  (`diIsScalarType`, `src/sema.zig:5844-5851`; design comment :1300-1317), and any
  address-of clears pending (`:1596-1605`) — `var s: Header = uninit;` + field reads
  compiles clean and reads garbage in the C backend. The docs present definite
  initialization as a check; today it is best-effort. Fix: track aggregate `uninit`
  whole-object; document the `&x` out-param accept explicitly in the spec. Effort M.
  **[inspected]**
- **[P1] Unguarded 128-bit arithmetic in comptime folding.** (a)
  `foldComptimeBitcast` `@intCast`s a masked u128 into the i128 `ComptimeValue.int`
  — a negative operand bitcast to a 128-bit target yields a value ≥ 2^127 → safety
  panic in Debug, UB in ReleaseFast (`src/eval.zig:919-923,262`). (b) Array sizing
  `@as(i128,@intCast(len)) * elem` is unchecked and copy-pasted in four files
  (`src/sema_reflect.zig:91`, `src/mir_reflect.zig:90`, `src/lower_c_reflect.zig:173`,
  `src/lower_llvm_reflect.zig:169`) — nested max-usize arrays overflow i128 → panic.
  Neighboring code uses `std.math.mul ... catch null`, so these are misses, not
  policy. Fix: early-return `.unknown` / one shared checked helper. Effort S.
  **[inspected]**
- **[P2] Move checker is lexical and name-keyed, by its own admission** ("Phase 3
  will rewrite this pass over a proper CFG", `src/sema_move.zig:6`). Short-circuit
  RHS is consumed unconditionally (leak on the untaken path is invisible); arrays of
  move types are rejected wholesale (`E_MOVE_ARRAY_UNSUPPORTED`). The while-condition
  P0 is a symptom. Fix: proceed with the planned CFG/place-based rewrite; patch
  short-circuit modeling meanwhile. Effort L / S.
- **[P2] Spec drift: the orphan rule is stated unqualified but enforced only for
  opaque owners** (spec §32.2 vs `if (!sd.is_opaque) continue;`,
  `src/sema.zig:5215`). Qualify the spec or extend the check. Effort S.
- **[P2] No "required from here" instantiation backtrace.** Specialized clones keep
  generic-source spans (`src/monomorphize.zig:257-264`); post-substitution errors
  point at code that is correct for other instantiations. Fix: thread an
  instantiation-origin note. Effort M.

### 5.3 MIR & backends — C+

Strengths: see §3 (UB matrix implemented; `-Werror` + ASan/UBSan + differential +
QEMU gates all required in `m0`; single-sourced layout cross-checked against clang;
loud refusal; line-level DWARF on the LLVM path gated by `llvm-debug-test`
asserting file/function/line rows survive `llc`; opaque `ptr` + no
`nuw`/`nsw`/`noalias` emitted, matching the README's defensive-emission claim,
with one known `getelementptr inbounds` exception on the va_list path,
`src/lower_llvm.zig:1215`).

- **[P0] LLVM backend passes/returns structs as first-class IR aggregates at
  `extern`/`export` boundaries — no per-target C ABI classification.** Params are
  emitted as `%struct_ty %param` directly (`src/lower_llvm.zig:1008-1012`), and
  extern declarations use the same `llvmType` path; sema has no rejection of
  struct-by-value on `extern "C"`/`export` (none found; `docs/c-abi-interop.md`
  implies it is allowed). `llc` does not implement C struct-passing ABI (SysV
  eightbyte classification, RISC-V LP64 float/pair rules, AAPCS HFAs) — clang does
  that in its *frontend*. The team clearly knows per-arch ABI matters (hand-built
  `%mc.va_list.x86_64/aarch64`, `src/lower_llvm_prelude.zig:96-101`) but only
  va_list is handled. Passing/returning an `extern struct` by value between an
  `emit-llvm` object and a clang object puts arguments in the wrong
  registers/memory — a silent ABI miscompile no current gate covers (abi-test checks
  *layout*, not calls; diff-backend drivers exchange scalars). Fix now: sema-reject
  by-value struct params/returns on `extern`/`export` (S) + a diff-backend driver
  passing {u8,u8}/{f32,f32}/>16-byte structs across a clang boundary; implement
  classification later if the feature is wanted (L). **[inspected — run the
  10-minute probe: `extern "C" fn f(t: Timespec)`, diff `emit-llvm` IR against
  clang's IR for the same C signature]**
- **[P1] Release-mode check elision: span-only matching on LLVM, function-filtered
  on C — a live parity divergence.** C: `mirCheckElided` filters by
  `current_function` then span (`src/lower_c_emitter.zig:4389-4392`). LLVM: iterates
  *all* functions' `elided_bounds` and matches line/column alone
  (`src/lower_llvm.zig:3039-3044`); its comment claims "source points are unique per
  location," which is exactly false for monomorphized generic instances that share
  the generic body's spans with different function names. Under
  `--checks=elide-proven`, a check proven dead in one instance can elide the
  same-position check in a *different* function on LLVM only — a removed safety trap
  nothing proved. Fix: add the function-name filter to the LLVM side + a parity
  fixture with two same-span functions where only one elision is proven. Effort S.
  **[inspected — both sites verified]**
- **[P1] Parity is empirical: both backends independently re-derive semantics from
  the AST.** The `Backend.lowerFn` seam consumes `ast.Module`
  (`src/backend.zig:106-112`); the C backend carries its own 577-line type-inference
  module (`src/lower_c_infer.zig`, e.g. int-literal→`u32` default re-implemented at
  :524), the LLVM backend its own query/type maps; MIR contributes only span-keyed
  elision/range facts. The emitted-IR header "semantic source: verified MC MIR"
  (`src/lower_llvm.zig:219`) overstates reality. The commit trail shows the drift
  class recurring at review time (dd48ab35 "mirroring sema", c8d756ec "via a sema
  flag, not syntactic guessing", June's G13/G23/G7 codegen fixes); a concrete sharp
  edge: `emitUncheckedAddInferredLocalInit` hardcodes inferred locals to `u32`
  (`src/lower_c_arith.zig:303-309`). Every feature is implemented semantically 2-3×
  (sema, C, LLVM, plus the eval interpreter), and any divergence is a silent
  miscompile unless a fixture covers it. Fix: make backends consume sema's resolved
  facts (the mcc2 self-host's "parse-once → typed fact table → emit consumes facts"
  refactor is the proven in-repo template); short term, audit backend inference
  fallbacks against sema. Effort L. **[inspected]**
- **[P1] The lowering-coverage instrument silently rotted.**
  `tools/toolchain/lowering-coverage.sh:34-35` still instruments `src/lower_c.zig` +
  `src/lower_llvm.zig` only — but `lower_c.zig` has been a 108-line facade since the
  module split (149090ea); the real emitter is `lower_c_emitter.zig` (4,747 lines) +
  ~40 modules. The doc's headline (615 fns, 72.5% covered) describes a file that no
  longer exists, and the gate is report-only, absent from every tier. The mechanism
  that caught the overlay-read miscompile currently measures ~nothing of the C
  backend. Fix: point it at all `lower_c_*`/`lower_llvm_*` files, regenerate
  `docs/lowering-coverage.md`, add a ratchet (uncovered count must not grow) in CI.
  Effort S-M. **[inspected]**
- **[P1] Differential gates have no skip budget.** `diff-backend.sh` converts "LLVM
  cannot lower this fixture" into a non-fatal per-fixture SKIP (fails only on FAILs)
  — a regression that turns a previously-compared fixture into
  `UnsupportedLlvmEmission` shrinks parity coverage with green CI. The async family
  already solved this pattern (non-skippable assertions). Fix: pin an expected-skip
  list / assert `compared >= N`. Effort S. **[inspected]**
- **[P1] LLVM support matrix undefined; textual-IR emission is upgrade-fragile.**
  Dockerfile installs unversioned distro LLVM and symlinks the newest
  (`Dockerfile:25,30-36`); CI apt-installs unpinned `llvm`. The backend hardcodes
  version-sensitive datalayout strings per arch (`src/lower_llvm_prelude.zig:88-94`)
  and feeds textual IR to external `llc`. An image rebuild that bumps LLVM can
  change/break lowering with no gate distinguishing whose bug it is; users get raw
  `llc` stderr. Fix: pin the LLVM major, print-and-assert versions, document the
  supported range, add a canary leg on the next major. Effort M.
- **[P1] Debuggability is partial.** Emitted C has no `#line` by default (`#line`
  lives only in the separate `emit-map` artifact, `src/lower_c_map.zig:46`) — a
  crash in generated C shows generated-C coordinates. LLVM DWARF is line-level only:
  no `dbg.declare`/variable/type info anywhere, so no debugger variable inspection
  on either backend. Fix: opt-in `--line-directives` for `emit-c` (S; span plumbing
  exists); variable-level DWARF (M/L).
- **[P2] The "MIR verifier" is a policy checker, not an IR verifier.** MIR
  instructions carry string details and name-string types
  (`src/mir_model.zig:112-158`); verification = CFG structural sanity + semantic
  policy checks (`src/mir.zig:3508-3551,554-737`) — no operand types, no
  def-before-use, no dominance. It verifies the *program*, not the *lowering*;
  naming it "verified MIR" over-promises. Fix: re-document honestly now (S); a
  typed MIR is the same work as the fact-table item (L).
- **[P2] Backend bailouts carry no source location.** The 476 `Unsupported*Emission`
  sites propagate as raw Zig errors out of `main` (`src/main.zig:558-562,634-638`) —
  loud but undebuggable in a 476-file std/kernel codebase. Fix: thread the Reporter
  into backends; attach spans at bailout sites. Effort M (mechanical).
- **[P2] C identifier collision surface.** `isCReservedWord` covers C11 + a few
  extras (`src/lower_c_type.zig:294-314`) but the prelude includes
  `<stdint.h>/<limits.h>/<stddef.h>`, and user identifiers like `uint32_t`,
  `offsetof`, GNU/C23 keywords, or `mc_`-prefixed names share the emitted namespace
  — mostly loud `-Werror` failures with confusing errors; a nested shadowing of an
  `mc_tmpN` name is the quiet corner. Fix: extend the reserved list; have sema
  reserve `mc_`/`MC_` prefixes. Effort S.
- **[P2] Targets are hardcoded 64-bit little-endian** (`usize`/addr types fixed at 8
  bytes, `src/layout.zig:101-114`; `TargetArch` = riscv64/x86_64/aarch64,
  `src/backend.zig:44-48`; endianness implicit). Fine as a scoped v0 decision;
  document as normative and parameterize before any 32-bit/BE port. Effort S (docs).

### 5.4 Zig implementation quality — C+

Strengths: panic discipline is real (~73 true `unreachable` statements in non-test
src — a raw grep says 151 but half are string literals in emitted IR text; of ~35
sampled, all were tag-guarded or cross-pass invariants, none directly reachable from
input); the five `.await_expr => unreachable` sites are guarded by async_lower
rejecting stray `await` with a proper diagnostic on every entry path
(`src/main.zig:749-776` funnels all commands through one `parseModuleOrReport`);
lexer/formatter are total and allocation-free; comptime is fueled; comment quality
on tricky invariants is exceptional; ~11.2k lines of in-repo Zig tests.

- **[P1] Crash classes: parser recursion, mono explosion, 128-bit folding.** Covered
  in §5.1/§5.2 (blockers #1, #6, and the eval guards) — listed here because the fix
  surface is the Zig implementation.
- **[P1] Performance architecture: whole-program, single-threaded, Debug by
  default.** Every invocation flattens the full import graph into one buffer and
  re-lexes/parses/checks everything (`src/main.zig:138`, `src/loader.zig:6-27`); no
  caching or incremental machinery; no `std.Thread` in `src/`; `emit-llvm` builds
  MIR twice (verify in `main` + `mir.buildOpt` inside the backend,
  `src/lower_llvm.zig:210`); the LSP spawns a synchronous full `mcc check` on every
  `didChange` with no debounce (`tools/lsp/mc-lsp.py:732-737`), blocking
  hover/completion behind it; the default and CI-installed build is Debug
  (`standardOptimizeOption`, `build/compiler.zig:10`; `tools/m0-parallel.sh:20`).
  Editor latency at kernel scale (203 files, ~1.1 MB) pays whole-program Debug sema
  per keystroke. Staged fix: LSP debounce+cancel (S); ship/pin ReleaseSafe (S);
  reuse the verify-phase MIR (S); per-file parse cache + fact table (L).
  **[inspected]**
- **[P2] Sema's results are discarded; no typed AST/IR.** `ast.Expr` has no type
  slot (`src/ast.zig:495-497`); type identity is syntax comparison
  (`sameTypeSyntax`). Same root cause as blocker #9; also the main perf ceiling
  (repeated subtree walks per type query) and the barrier to parallel lowering.
- **[P2] Global mutable state blocks library embedding.** `combined_boundaries` and
  `stdout_io` are file-scope vars (`src/main.zig:42,91`); diagnostics print straight
  to stderr with no writer injection. Harmless for one-process-per-compile; fatal
  for an in-process LSP or parallel compiles. Fix: a `Compilation` context threaded
  through `parseModuleOrReport`; Reporter takes a writer. Effort S-M.
- **[P2] Pervasive `anyerror` erases error sets** (49 uses in parser.zig, 212 in
  lower_c_emitter.zig) — forfeits compile-time exhaustiveness over failure modes.
  Tighten where recursion doesn't force it. Effort M, mechanical.
- **[P2] No `build.zig.zon` / `minimum_zig_version`.** Pinning exists only in
  Dockerfile/CI; a host user with mismatched Zig gets arbitrary compile errors
  instead of a version message. Note: the correct release optimize mode is
  **ReleaseSafe** — ReleaseFast would convert the 128-bit-folding panics into silent
  UB. Effort S.
- **[P2] `src/hir.zig` (635 LoC) + `src/ir.zig` (1,447 LoC) may be
  retirement candidates.** Only `main.zig` imports them; only the `lower-hir` /
  `verify-hir` / `facts` / `lower-ir` dump commands and their spec fixtures exercise
  them. If no external tooling reads those formats, ~2k LoC + tests are carryable
  dead weight. Verify consumers first. Effort S (audit).

### 5.5 Toolchain UX & distribution — D+

Strengths: LSP is feature-rich (diagnostics with compiler codes, hover, goto-def,
references, rename, semantic tokens, completion, signature help, call hierarchy,
formatting, UTF-16-correct) and cannot drift because it shells out to `mcc`; it and
the formatter, symbol indexer, and editor client are CI-gated (`build/tiers.zig:363-366`).
The spec is 5.5k lines, updated same-day as HEAD, with an enforced coverage gate. A
gated 447-line self-verifying `examples/feature_showcase.mc` exists. Dev-environment
reproducibility (Docker + preflight + no-skip CI) is excellent.

- **[P0] No releases, no versioning, no install path.** Zero git tags; CI has no
  release job or artifact upload; no prebuilt binaries; no `build.zig.zon`. A
  stranger cannot install `mcc` without cloning and building with exactly Zig
  0.16.0, and there is no version identity to file bugs against. Fix: tag v0.7.0; a
  release workflow cross-compiling `mcc` for {linux,macos}×{x86_64,aarch64} with
  tarballs (mcc + `std/` + driver scripts) + checksums. Effort M.
- **[P0] No one-shot build driver.** `mcc` only writes generated text to stdout
  (`src/main.zig:89-98`); compiling and linking live in repo scripts
  (`tools/toolchain/mcc-cc.sh:94`, `mcc-llvm-cc.sh:88-89`) and per-test glue
  (`tools/lib/host-harness.sh:57-59` generates a one-line C `main` for entry-mode
  fixtures whose MC entry is not named `main`). Note the language itself does not
  force a shim: `export fn main() -> i32` is supported
  (`examples/apps/hello.mc`) and `emit-c` lowers it to a real `int32_t main(void)`
  — the gap is purely that "hello world → executable" is several manual
  emit/compile/link steps across two toolchains, with the knowledge scattered
  across scripts and demo READMEs. Fix: `mcc build <file.mc> [-o exe]` that emits,
  invokes cc/llc+linker, and synthesizes an entry shim only when the program
  exports no `main`; fold the script logic into the driver. Effort M-L.
- **[P1] No `--version`, no `--help`, undocumented subcommands.** No version string
  exists anywhere in src/build; the usage block prints only via `failUsage()` (i.e.,
  `mcc --help` *errors*); `list-tests` is dispatched but absent from usage
  (`src/main.zig:171` vs :44-87); README's command list omits five subcommands.
  Effort S.
- **[P1] Repo-coupled everything.** Rooted imports resolve by walking the importing
  file's ancestors (`src/loader.zig:18-21,212-223`) — no install prefix, no
  `MC_PATH`; driver scripts self-locate by walking up to `build.zig`; the VS Code
  extension defaults to `${workspaceFolder}` paths (`editors/vscode/package.json:49,54`).
  An external project cannot use std/ or the drivers without vendoring the repo
  layout; the IDE integration only works when the workspace *is* this repo. Fix: an
  installed layout (`<prefix>/bin/mcc`, `<prefix>/lib/mc/std/`) + `MC_PATH`/
  `--std-dir` loader fallback + install-relative scripts + PATH-based extension
  defaults. Effort M.
- **[P1] IDE support isn't out-of-the-box.** Extension install = symlink into
  `~/.vscode/extensions/` + `npm install`; no `.vsix`, no marketplace, Python 3
  required at runtime; VS Code is the only editor with any config. Fix: package/
  publish the `.vsix` in CI; document generic LSP-client setup for other editors.
  Effort M.
- **[P1] No stability policy, changelog, or deprecation process.** The only
  deprecation artifact in the project is the `--optimize` alias
  (`src/cli.zig:57-58`). Consumers of master track a moving head with no notice of
  breaking changes. Fix: STABILITY.md (what's frozen at 0.7 vs experimental — async
  v0, traits Tier 2), CHANGELOG, tagged snapshots. Effort S.
- **[P1] Diagnostics have no user-facing reference.** ~200 distinct `E_*` codes in
  src (measured 194-224 depending on scope); only ~41 appear anywhere in the spec;
  no docs/diagnostics.md, no `mcc explain`. The LSP surfaces codes users cannot look
  up. Fix: generate a reference from source (code + one-line description), gate it
  like spec coverage. Effort M.
- **[P1] Host platform support is documented but unverified beyond Linux.** CI runs
  `ubuntu-latest` only; README claims native macOS + container Linux/macOS/WSL; the
  project's own practice is Docker-only on macOS. Fix: a macOS CI job (build mcc,
  `zig build fast`, fmt/lsp gates); state the real support tiers in README. Effort
  S-M.
- **[P2] CLI ergonomics:** stdout-only artifacts, no `-o`, no stdin mode, flag
  errors dump the whole usage block without naming the bad flag, exit codes
  undocumented. Effort S.
- **[P2] Package story is an offline exact-version slice** (`mcpkg.txt` + path@version,
  `tools/toolchain/mcc-pkg.sh:44-93`) — honest and gated, but no external
  consumption path; a git-URL source would be the smallest real step. Effort L,
  reasonable to defer.
- **[P2] Formatter is a reindenter, not a pretty-printer** (`src/fmt.zig:3-13`,
  disclosed in README) — cannot converge intra-line style. Effort L, deferred is
  fine.
- **[P2] No stdlib API docs** — std/ headers are good prose but there's no generated
  index of the ~30-module surface. A small extractor over `export fn` signatures,
  gated. Effort M.

### 5.6 Testing & CI — B-

Strengths: see §3 (hosted CI + anti-vacuity; 569 unique gate commands in `m0`
at `311fdd18` — 582 `ctx.cmd` references, a handful of gates are wired into more
than one sub-group — counted with `tools/m0-parallel.sh`'s own `tiers.zig`
extraction, spanning unit/spec/fixture/toolchain/QEMU layers with `llvm-*` twins;
`ctx.cmd()` panics on unregistered steps; `tools/m0-parallel.sh` derives its list
from `tiers.zig` — no drift; 821 bidirectional `EXPECT_ERROR` markers; 7 required
fuzz oracles; explicit
flaky policy — internet-dependent gate excluded, parallel failures re-verified
serially; honest self-documentation of limits).

- **[P1] The independent oracles and corpus replay gate nothing.**
  `fuzz-reference` (independent Python interpreter — the only oracle that can catch
  both-backends-wrong-identically frontend/MIR bugs), `fuzz-metamorphic`,
  `fuzz-optlevel`, `fuzz-floatbits`, `fuzz-corpus` are all registered in
  `build/fuzz.zig` but absent from `m0`/`fast`/CI;
  `docs/mcfuzz-coverage-todo.md:9-16` itself says "either the gate or this note
  should change." The three persisted repros replay only via the ungated
  `fuzz-corpus`. Fix: gate them (the doc says the policy just needs deciding).
  Effort S.
- **[P1] Fuzzing is a fixed-seed replay, not a campaign.** `--count` defaults to
  300, `--start` to 1, and `build/fuzz.zig` passes neither — every CI run re-tests
  the identical seeds; no `schedule:` trigger exists. The fuzz gates are regression
  tests in disguise; new shapes are explored only when a human runs more seeds.
  Fix: nightly workflow with rotating `--start` (date-derived) + large `--count`,
  shrunk findings appended to `tools/fuzz/corpus/`. Effort S-M.
- **[P1] Compiler code coverage is never measured.** No kcov/source-coverage
  anywhere; the one instrument covers 2 of ~110 files at function granularity, is
  ungated, and rotted (§5.3). For ~65k LoC (sema, monomorphize, async_lower, MIR)
  coverage is argued by fixture enumeration. Fix: run the (re-pointed) instrument in
  the Docker CI job with a ratcheted uncovered-count baseline; extend to sema/
  async_lower. Effort M.
- **[P1] No release qualification bar.** The entire documented bar is "run
  `zig build m0` before release claims" (`docs/qemu-validation-checklist.md:13`).
  Define: CI green (both jobs) + Docker `m0` + `riscv-qemu-validation` + N-hour
  rotating-seed fuzz + coverage no-regress + reproducible-build — as *the* release
  checklist. Effort S (checklist), M (automation).
- **[P1] Single unpinned toolchain leg.** Bare `apt-get install clang lld llvm
  qemu-system-*` on `ubuntu-latest` and in the Dockerfile — an image/LLVM bump
  silently changes what green means; the version-print step asserts nothing. Fix:
  pin the LLVM major, assert printed versions, add one matrix leg on the next major.
  Effort M.
- **[P1] Merge discipline is convention, not enforcement.** No git hooks, no branch
  protection evident, single author committing to master at ~44 commits/day; CI
  validates after the fact; host-side runs silently skip all LLVM/QEMU gates. Fix:
  branch protection requiring both jobs + a pre-push hook running `zig build fast`.
  Effort S.
- **[P2] Diagnostic wording is not locked** — spec tests assert code+line only;
  `bad/` corpora grep the code token. A message can regress to misleading/empty text
  invisibly. Fix: golden stderr transcripts over `bad/` + a spec sample with an
  update flag. Effort S-M.
- **[P2] 16 diagnostic codes have no negative fixture** (incl.
  `E_TRAIT_EFFECT_MISMATCH`, `E_DYN_MUT_BORROW`, `E_PRIVATE_IMPORT`) and no
  inventory gate enforces closure. Fix: an inventory test extracting the code
  universe from source, with a documented allowlist. Effort S.
- **[P2] CI's "gate actually ran" assertion covers only the async family** (26 of
  ~570). Reuse m0-parallel's awk extraction to derive the expected list from
  `tiers.zig` + assert a count floor. Effort S.
- **[P2] Benchmarks exist but gate nothing** (`heap/ipc/mem/sched/uaccess-bench` +
  llvm twins registered, in no tier) — compile-speed and codegen perf regress
  silently despite an active perf workstream. Fix: nightly bench job + committed
  TSV + tolerance check. Effort M.
- **[P2] `src/async_lower.zig` (2.9k LoC) has zero in-file unit tests** —
  fixture-only coverage; async is also absent from the mcfuzz generator. Fold async
  shapes into the generator rather than writing unit tests. Effort M.

### 5.7 Security & supply chain — C+

Strengths: see §3 (no shell-outs; injection closed; `#line` escaping tested;
BearSSL vendoring exemplary — upstream URL, exact commit, license, drop list, the
one added file marked; trust-anchor provenance reproducible with commands; clean
secrets hygiene; compatible licenses).

- **[P1] No dependency provenance or CVE process for 3 of 4 vendored engines.**
  `third_party/quickjs/` (QuickJS-ng 0.15.1 per header) and `third_party/wamr/`
  (2.4.3 per `core/version.h`) have no vendoring README; openlibm records no version
  at all; no UPDATING/process doc; zero dep-bump commits in history. A published
  CVE would go unnoticed with no recorded commit to diff against. Fix:
  `README.vendored.md` per dep on BearSSL's template + `docs/vendoring.md` with a
  re-vendor/CVE-watch checklist. Effort M.
- **[P1] No SECURITY.md / vulnerability-report channel.** Finders default to public
  issues. Effort S.
- **[P1] The threat model explicitly excludes the compiler and supply chain.**
  `docs/threat-model.md:43-45` lists "supply-chain compromise of the vendored
  engines or the toolchain" as out of scope; the compiler appears only as trusted
  TCB. The scenario this document targets — external users trusting the toolchain,
  possibly compiling untrusted source — is unmodeled. Fix: add a
  compiler-as-attack-surface section + a supply-chain sub-model. Effort M.
- **[P1] Dev image fetches Zig with no integrity check; base image floats.**
  `FROM ubuntu:24.04` by tag; `wget` + untar with no SHA/minisign verification; apt
  unpinned. Fix: digest-pin the base; verify the Zig tarball against a committed
  hash or Zig's minisign key. Effort S-M.
- **[P1] Imports have no project-root jail.** Absolute (`import "/etc/passwd";`) or
  `../` paths resolve and read with no containment (`src/loader.zig:201-234`, read
  at :140). Building a hostile package lets `mcc` read any file the process can —
  bounded (content must lex/parse to go further), but diagnostics that echo source
  make it an information oracle. Fix: default-jail imports to the root file's tree;
  reject absolute imports unless whitelisted. Effort M. **[inspected]**
- **[P2] CI actions pinned by moving tag** (`actions/checkout@v4`,
  `mlugg/setup-zig@v2`) — pin to commit SHAs; Dependabot for actions. Effort S.
- **[P2] Local WAMR modifications are commingled with upstream** (the MC platform
  port lives inside `third_party/wamr/core/shared/platform/mc/`) — cannot cleanly
  diff against pristine upstream. Keep ports outside `third_party/` or carry a
  patch series. Effort M.
- **[P2] No NOTICE / aggregated third-party license manifest** — WAMR is Apache-2.0
  (NOTICE-preservation duty on redistribution); nothing aggregates the four deps for
  a binary release. Generate `THIRD-PARTY-LICENSES.md`. Effort S.
- **[P2] `#line` embeds the raw CLI path** — absolute paths/usernames leak into
  emitted artifacts; add normalization or `--remap-prefix`. Effort S.
- **[P2] String-literal passthrough is safe today but fragile** — MC lexemes are
  appended verbatim into C (`src/lower_c_emitter.zig:3866,3872`); safe under the
  current lexer + clang, but trigraph/escape divergence bites under other C
  compilers. Decode and re-emit with an explicit C escaper. Effort S.
- **[P2] A committed (documented, throwaway) RSA test key**
  (`third_party/trust-anchors/host_test.key`) — generate at test time instead.
  Effort S.
- **[P2] No release-integrity story** — nothing for signing/checksums/SBOM if
  binaries shipped tomorrow. Minimal bar: recorded dep versions+hashes, SHA-256 +
  minisign/cosign signature, generated SBOM. Effort M.

## 6. Cross-cutting root causes

Four structural facts generate most of the findings above; fixing findings without
acknowledging these treats symptoms.

1. **Sema's knowledge is discarded instead of consumed.** The AST carries no types;
   sema, the C backend, the LLVM backend, and the comptime evaluator each re-derive
   semantics independently, and "parity" is whatever the fixture corpus pins. This
   is the standing tax behind the G-series fixes, the parity-gate volume, the
   `u32`-default sharp edges, and the elision asymmetry — and it is also the perf
   ceiling and the parallelism blocker. The mcc2 self-host already prototyped the
   remedy (parse-once → typed fact table → emit consumes facts,
   `docs/self-host.md`); porting that architecture to `src/` is the single
   highest-leverage investment in this document.
2. **Whole-program textual flattening.** One combined buffer per invocation buys
   simplicity and costs: misattributed diagnostics (blocker #7), private-name
   mangling workarounds (G22), no separate/incremental compilation, whole-world
   recompiles per keystroke in the LSP, and memory scaling with total program size.
3. **The fuzzer only generates well-typed programs.** Every value oracle compares
   the two backends against each other, so (a) shared-frontend bugs are invisible to
   all of them (the ungated `fuzz-reference` interpreter is the only independent
   oracle), and (b) nothing ever feeds the parser structurally hostile input — which
   is why a by-inspection afternoon found crash classes the gates never will.
4. **Single-maintainer conventions, no product process.** Direct-to-master at high
   velocity with excellent personal discipline — but no tags, versions, branch
   protection, stability statement, security channel, or dependency process. All
   cheap to add; none exist.

## 7. Roadmap

Phased so that each phase is independently shippable and every item lands with a
gate, in repo idiom. Efforts: S = hours-to-a-day, M = days, L = week(s)+.

### Phase 0 — Stop the bleeding (correctness, all S/M — days total)

| Item | Fix | Gate | Effort |
|---|---|---|---|
| Parser depth guard | Depth counter in Parser; `E_NESTING_TOO_DEEP` past ~256 | `bad/` fixtures at depth 10k; nesting amplifier in `fuzz-robust` | S |
| Monomorphization limits | Depth + total-instance caps; `E_MONO_DEPTH` naming the chain | `bad/` polymorphic-recursion fixture must reject fast | S |
| `while`-condition move consumption | Consume the condition like a body region | Spec tests: consuming while-cond rejected; borrow-cond accepted | S |
| Closure typing | Type `bind`; closure-call arg checks; env-escape checks | New `E_CLOSURE_*` codes + spec accept/reject fixtures both backends | M |
| Extern struct-by-value (LLVM) | Sema-reject on `extern`/`export` until ABI work | `bad/` fixture + a diff-backend struct-ABI driver vs clang | S |
| LLVM elision function filter | Match function name + span like the C side | Parity fixture: two same-span fns, one proven elision | S |
| 128-bit fold guards | `.unknown` on overflow; one shared checked array-size helper | Unit tests + `bad/` giant-array fixture | S |
| Oversized int literals | Null-fold on integer syntax ⇒ `E_INTEGER_LITERAL_OUT_OF_RANGE` | Reject fixture | S |
| OOM fail-closed | `has_errors = true` in Reporter catch arms; poison eval folds | Unit test with failing allocator | S |

Every Phase 0 item first gets a probe (`.mc` PoC) confirming the inspected behavior,
per §Method.

### Phase 1 — Diagnostics a user can live with

| Item | Gate | Effort |
|---|---|---|
| Boundary-aware rendering (right file, right line) | Golden multi-file diagnostic transcript | S-M |
| Import-not-found as a spanned diagnostic | Golden transcript | S |
| Suppress error-return traces; documented exit codes | Transcript asserts no `error:` trace line | S |
| Source-line + caret renderer; notes; `--json` | Golden transcripts; LSP consumes JSON | M-L |
| Backend bailouts carry spans | Transcript for one unsupported construct | M |
| BOM skip | Accept fixture | S |
| Diagnostics reference doc (generated from `E_*` codes) | Coverage gate like spec-sections | M |
| Golden diagnostic wording for `bad/` corpora | New gate in `m0` | S-M |
| Fixture for each of the 16 unfixtured codes + inventory gate | New unit test | S |

### Phase 2 — Make green mean more (qualification)

| Item | Gate | Effort |
|---|---|---|
| Gate `fuzz-reference`/`metamorphic`/`optlevel`/`floatbits`/`corpus` in `m0` | tiers.zig | S |
| Nightly rotating-seed fuzz workflow, corpus growth | scheduled CI job | S-M |
| Malformed-input/grammar-hostile fuzzer for the front-end (crash-only oracle) | new `m0` gate | M |
| Re-point lowering-coverage at the split files; ratchet in CI | Docker CI job + baseline file | S-M |
| Skip budgets in `diff-backend` (assert compared ≥ N) | script assert | S |
| Derive CI PASS-assertions from `tiers.zig` (count floor) | ci.yml | S |
| Pin LLVM major in Dockerfile + CI; assert versions; canary leg on next major | ci.yml/Dockerfile | M |
| Branch protection (both jobs required) + pre-push `zig build fast` hook | repo settings | S |
| Nightly benches with committed TSV + tolerance | scheduled job | M |
| Release-qualification checklist doc | this file §7 + qemu-validation-checklist | S |

### Phase 3 — Become installable (distribution)

| Item | Gate | Effort |
|---|---|---|
| `build.zig.zon` + `minimum_zig_version`; ReleaseSafe release profile | build | S |
| `mcc --version`/`help`; document all subcommands; README sync | transcript test | S |
| Tag v0.7.0; release workflow: cross-compiled tarballs (mcc + std/ + drivers) + SHA-256 + minisign/cosign + SBOM + THIRD-PARTY-LICENSES | release CI job | M |
| Installed layout + `MC_PATH`/`--std-dir` loader fallback; install-relative scripts | install smoke test in CI | M |
| `mcc build <file> -o exe` one-shot driver (cc/llc+link; entry shim only when no exported `main`) | hello-world e2e gate | M-L |
| SECURITY.md; vendoring READMEs (quickjs/wamr/openlibm) + docs/vendoring.md; digest-pinned base image + verified Zig download; SHA-pinned actions | repo files | S-M |
| STABILITY.md + CHANGELOG | repo files | S |
| Package + publish `.vsix`; generic LSP setup docs; LSP debounce/cancel | lsp-test extension leg | M |
| macOS CI leg (build + `fast` + fmt/lsp) | ci.yml | S-M |
| Import jail (`--sandbox-root`, default root-tree); `#line` path remapping | reject fixture; reproducible-build assert | M |

### Phase 4 — Architecture (the compiler a team can build on)

| Item | Why | Effort |
|---|---|---|
| Typed fact table: sema resolves once, backends consume (mcc2's proven pattern) | Design slice, Phase 1 inventory, Phase 2 narrow pointer-provenance MIR table, Phase 3 LLVM narrow consumption, and Phase 4 C narrow consumption are complete in [`typed-semantic-facts.md`](typed-semantic-facts.md); next work is remaining cleanup for that fact family. Kills the drift class (root cause #1); prerequisite for parallel + incremental; retires per-backend inference | L |
| Generic-body pre-instantiation checking (placeholder instantiation honoring bounds) | Library-grade generics | M-L |
| CFG/place-based move checker (planned in-code) | Closes the lexical-analysis corner cases for good | L |
| Parser error recovery (statement/decl resync) | Multi-error UX | L |
| Per-file parse cache; incremental check; parallel lowering | Editor-scale latency; needs #1 + de-globaled state | L |
| In-process or debounced LSP server | Retires per-keystroke process spawns | M |
| `--line-directives` in emit-c; variable-level DWARF | Debuggability bar | M/L |
| C ABI classification for extern struct-by-value (if the feature is kept) | Re-enable the Phase 0 rejection | L |
| Honest MIR naming or a typed MIR | Stop over-promising "verified MIR" (S for docs; L folds into fact table) | S/L |

## 8. Explicit non-goals / accepted limitations (for now)

Reasonable to defer, but say so in user-facing docs:

- **64-bit little-endian targets only** (riscv64/x86_64/aarch64). Document as
  normative; loud static-assert defenses exist if violated.
- **Formatter = reindenter** (disclosed in README); pretty-printing is Phase-4+.
- **Package registry is offline/local**; a networked signed registry is future work
  (README already says so).
- **Windows-native host** untested; WSL/Docker is the supported path.
- **Full C-ABI struct passing on the LLVM backend** — rejected (Phase 0) rather than
  implemented until there is a consumer.
- **The `lower-hir`/`lower-ir`/`facts` dump surfaces** — audit consumers; retire or
  document (§5.4).

## 9. Open probes (run before fixing the [inspected] P0/P1s)

1. Closure miscompile PoC: mismatched `bind` signature → run both backends, observe
   miscast call (§5.2).
2. `while`-condition double-free PoC on both backends (§5.2).
3. `extern "C" fn f(t: Timespec)` → diff `emit-llvm` IR vs clang's IR for the same C
   signature (§5.3).
4. Elision-divergence reachability: monomorphized instances sharing spans under
   `--checks=elide-proven` (§5.3).
5. `eval.zig` 128-bit panics: comptime bitcast of a negative to a 128-bit target;
   nested max-usize arrays (§5.2/§5.4).
6. Monomorphization hang: 3-line polymorphic recursion with a timeout (§5.2).
7. Whether checked-in MC sources pass `mcc fmt --check` (§5.5, open question from
   review).

## 10. Related documents

| Document | Relation |
|---|---|
| [`production-readiness-plan.md`](production-readiness-plan.md) | The kernel/appliance production plan; this doc is its compiler-side complement. |
| [`todo.md`](todo.md) | Repo-wide roadmap; its P2 "tooling polish" row is expanded and superseded for the compiler by this doc. |
| [`test-architecture.md`](test-architecture.md) | Fixture contracts and gate layers this doc's roadmap extends. |
| [`lowering-coverage.md`](lowering-coverage.md) | The coverage instrument §5.3 says must be re-pointed; its headline numbers are stale. |
| [`typed-semantic-facts.md`](typed-semantic-facts.md) | Phase 4 design artifact for the typed fact table / typed MIR bucket; defines invariants, implementation phases, first migration candidates, and acceptance gates. |
| [`c-ub-matrix.md`](c-ub-matrix.md), [`unsafe-boundary.md`](unsafe-boundary.md) | Verified-in-code UB handling cited under strengths. |
| [`mcfuzz-coverage-todo.md`](mcfuzz-coverage-todo.md) | Fuzzer backlog; §5.6 promotes its own "gate or note must change" item. |
| [`threat-model.md`](threat-model.md), [`security-review.md`](security-review.md) | Kernel-scoped today; §5.7 asks for compiler + supply-chain coverage. |
| [`self-host.md`](self-host.md) | The mcc2 subset self-host; its fact-table architecture is the Phase-4 template. |
| [`spec/MC_0.7_Final_Design.md`](spec/MC_0.7_Final_Design.md) | Normative spec; drift items in §5.2 (orphan rule, closures, definite-init wording). |
