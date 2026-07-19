# MC compiler diagnostics

This file is generated from `E_*` diagnostic codes emitted by production Zig sources under `src/`.
Regenerate it with:

```sh
python3 tools/toolchain/diagnostics-reference.py --write
```

Total codes: **236**.

| Code | Message examples | Source references |
|---|---|---|
| `E_ADDRESS_CLASS_CAST` | bitcast may not mint, cross, or strip a built-in address class (PAddr/VAddr/DmaAddr/MmioPtr/...); use the typed constructor or \`unsafe\`<br>casting to a built-in address class forges it from a non-address value; use the typed constructor (pa/va/dma/mmio.map) or \`unsafe\` | `src/sema.zig:4111`<br>`src/sema.zig:5667` |
| `E_ADDRESS_CLASS_MISMATCH` | mmio.map requires a PAddr argument | `src/mir_verify_util.zig:180`<br>`src/sema.zig:4052`<br>`src/sema.zig:7433` |
| `E_ADDRESS_CLASS_OPERATION` | MIR verifier found illegal operation on opaque address class<br>opaque address classes do not support this operator | `src/mir.zig:849`<br>`src/sema.zig:2853`<br>`src/sema.zig:2891` |
| `E_AMBIGUOUS_ERROR_CONVERSION` | multiple #[error_from] conversions for the same source and target error types; keep exactly one | `src/sema.zig:2763` |
| `E_ARITH_DOMAIN_DIVISION` | division and remainder are defined only on checked integers, not arithmetic domains | `src/mir_verify_util.zig:143`<br>`src/sema.zig:2888` |
| `E_ARITH_DOMAIN_UNSIGNED` | MC-C0 arithmetic domains require an unsigned integer type argument | `src/sema.zig:3491` |
| `E_ARITH_POLICY_MIX` | arithmetic domains do not implicitly mix | `src/mir_verify_util.zig:142`<br>`src/mir_verify_util.zig:149`<br>`src/sema.zig:2876` |
| `E_ARRAY_LENGTH_TYPE` | array length must be a compile-time checked usize integer expression | `src/sema.zig:3467` |
| `E_ARRAY_LITERAL_LENGTH` | array literal element count must match the target array length<br>array literal target must have a known constant length | `src/mir_verify_util.zig:102`<br>`src/sema.zig:5027`<br>`src/sema.zig:5031` |
| `E_ARRAY_LITERAL_REQUIRES_TARGET` | array literal requires an explicit array target type | `src/sema.zig:2533` |
| `E_ARRAY_TO_POINTER_DECAY` | arrays do not implicitly decay to pointers | `src/mir_verify_util.zig:97`<br>`src/sema.zig:5003` |
| `E_ASM_ARCH_MIXED` | inline-asm block mixes registers from more than one architecture | `src/sema.zig:4701` |
| `E_ASM_CLOBBER_CONFLICT` | inline-asm clobbers a register it also binds to an operand | `src/sema.zig:4739` |
| `E_ASM_REGISTER_CONFLICT` | inline-asm binds the same register to more than one operand | `src/sema.zig:4717`<br>`src/sema.zig:4727` |
| `E_ASM_UNKNOWN_REGISTER` | inline-asm names a register that is not valid on any supported architecture | `src/sema.zig:4694` |
| `E_ASSIGN_THROUGH_CONST_VIEW` | cannot assign through a const pointer or view | `src/mir_verify_util.zig:137`<br>`src/sema.zig:2648`<br>`src/sema.zig:2653`<br>`src/sema.zig:2661` |
| `E_ASSIGN_TO_IMMUTABLE_LOCAL` | cannot assign to immutable local binding | `src/mir_verify_util.zig:136`<br>`src/sema.zig:2395`<br>`src/sema.zig:2642`<br>`src/sema.zig:2656`<br>`src/sema.zig:2664` |
| `E_ASYNC_AWAIT_UNRESOLVED` | \`await e\` requires \`e\`'s future type be resolvable without sema — a call \`g(args)\`/\`Owner.m(args)\`, a parenthesized such expr, a struct-FIELD future \`base.fut\`, or an array element \`arr[i]\` (base a param/field of a known struct/array-of-future type); \`*dyn Future\` await and other expression shapes are deferred (Phase E) | `src/async_lower.zig:2376` |
| `E_ASYNC_BORROW_ACROSS_AWAIT` | in async fn '{s}', a reference to a local or parameter (\`&amp;x\`) is captured across an \`await\` — the future is returned by value, so an interior pointer dangles after the move (self-referential futures need pinning, unsupported in async v0). Restructure so no borrow of a captured value crosses the await | `src/async_lower.zig:2622` |
| `E_ASYNC_BRANCH_UNSUPPORTED` | a pre-branch \`let\`/\`var\` live across an await-bearing if/else must have an initializer in async v0<br>a pre-branch \`let\`/\`var\` live across an await-bearing if/else needs an explicit type annotation in async v0<br>a pre-branch \`let\`/\`var\` must bind exactly one name in async v0<br>_+3 more_ | `src/async_lower.zig:577`<br>`src/async_lower.zig:586`<br>`src/async_lower.zig:588`<br>`src/async_lower.zig:640`<br>`src/async_lower.zig:641`<br>`src/async_lower.zig:2437`<br>_+1 more_ |
| `E_ASYNC_FORBIDDEN_CONTEXT` | \`async fn\` is forbidden in a #[{s}] context (it suspends and uses indirect dispatch) | `src/async_lower.zig:482` |
| `E_ASYNC_GENERAL_UNSUPPORTED` | \`{s}\` outside an await-bearing loop in async E3c<br>a \`let\`/\`var\` live across the await regions must bind exactly one name in async E3c<br>a \`let\`/\`var\` live across the await regions needs an explicit type annotation in async E3c<br>_+3 more_ | `src/async_lower.zig:1721`<br>`src/async_lower.zig:1802`<br>`src/async_lower.zig:1805`<br>`src/async_lower.zig:1911`<br>`src/async_lower.zig:2127`<br>`src/async_lower.zig:2165` |
| `E_ASYNC_LOOP_UNSUPPORTED` | a \`while\` loop must have a condition in async v0<br>a pre-loop \`let\`/\`var\` live across the loop needs an explicit type annotation in async v0<br>a pre-loop \`let\`/\`var\` must bind exactly one name in async v0<br>_+5 more_ | `src/async_lower.zig:967`<br>`src/async_lower.zig:969`<br>`src/async_lower.zig:970`<br>`src/async_lower.zig:973`<br>`src/async_lower.zig:978`<br>`src/async_lower.zig:1000`<br>_+2 more_ |
| `E_ATOMIC_OPERATION` | atomic fetch_add/fetch_sub requires an integer payload type<br>unknown atomic operation | `src/mir_verify_util.zig:189`<br>`src/sema.zig:3681`<br>`src/sema.zig:3708` |
| `E_ATOMIC_ORDERING` | atomic load ordering must be .relaxed, .acquire, or .seq_cst<br>atomic read-modify-write ordering must be a valid atomic memory order<br>atomic store ordering must be .relaxed, .release, or .seq_cst | `src/mir_verify_util.zig:191`<br>`src/sema.zig:3754`<br>`src/sema.zig:3758`<br>`src/sema.zig:3764`<br>`src/sema.zig:3768`<br>`src/sema.zig:3774`<br>_+1 more_ |
| `E_AWAIT_OUTSIDE_ASYNC` | \`await\` is only valid inside an \`async fn\` (in '{s}') | `src/async_lower.zig:255` |
| `E_BACKEND_UNSUPPORTED` | C backend does not yet support {s}<br>LLVM backend does not yet support {s}<br>{s} backend does not yet support this construct | `src/lower_c_emitter.zig:3410`<br>`src/lower_c_emitter.zig:3833`<br>`src/lower_llvm.zig:1293`<br>`src/lower_llvm.zig:1300`<br>`src/main.zig:872` |
| `E_BITCAST_TYPE` | bitcast pointer-reinterpret may not cross into or out of an opaque/secret/userptr class<br>bitcast source must have a fixed scalar, pointer, or address-class layout<br>bitcast source type must be known<br>_+1 more_ | `src/mir_verify_util.zig:194`<br>`src/sema.zig:4067`<br>`src/sema.zig:4077`<br>`src/sema.zig:4080`<br>`src/sema.zig:4095` |
| `E_BITWISE_ARITH_DOMAIN_OPERAND` | bitwise operations are not defined on this arithmetic domain | `src/mir_verify_util.zig:144`<br>`src/sema.zig:2856`<br>`src/sema.zig:2937` |
| `E_BITWISE_BOOL_OPERAND` | bitwise operations are not defined on bool operands | `src/mir_verify_util.zig:155`<br>`src/sema.zig:2847`<br>`src/sema.zig:2931` |
| `E_BITWISE_POINTER_OPERAND` | bitwise operations are not defined on pointer operands | `src/mir_verify_util.zig:156`<br>`src/sema.zig:2850`<br>`src/sema.zig:2934` |
| `E_BITWISE_SIGNED_OPERAND` | bitwise operations are not defined on signed checked integers | `src/mir_verify_util.zig:154`<br>`src/sema.zig:2844`<br>`src/sema.zig:2922` |
| `E_BOOL_OPERATOR_OPERAND` | boolean operators are defined only for bool operands | `src/mir_verify_util.zig:157`<br>`src/sema.zig:2863`<br>`src/sema.zig:2947` |
| `E_BORROW_ESCAPES_SCOPE` | cannot store the address of local storage where it outlives the local's scope (the borrow would dangle) | `src/sema.zig:2703`<br>`src/sema.zig:2706` |
| `E_BREAK_OUTSIDE_LOOP` | break is valid only inside a loop | `src/sema.zig:2443` |
| `E_BYTE_VIEW_ADDRESS` | mem.as_bytes requires an address expression<br>mem.as_bytes requires an addressable value with known storage type<br>mem.as_bytes requires byte-addressable storage | `src/sema.zig:3946`<br>`src/sema.zig:3951`<br>`src/sema.zig:3956`<br>`src/sema.zig:3961` |
| `E_BYTE_VIEW_SLICE` | mem.bytes_equal expects []const u8 byte slices | `src/sema.zig:3972` |
| `E_CALL_ARG_COUNT` | DmaBuf operation does not take arguments<br>MMIO read expects exactly one ordering argument<br>MMIO write expects a value and one ordering argument<br>_+32 more_ | `src/sema.zig:3049`<br>`src/sema.zig:3071`<br>`src/sema.zig:3101`<br>`src/sema.zig:3143`<br>`src/sema.zig:3202`<br>`src/sema.zig:3213`<br>_+34 more_ |
| `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION` | integer-to-closed-enum conversion must use a checked conversion path | `src/mir_verify_util.zig:193`<br>`src/sema.zig:5588` |
| `E_CLOSED_ENUM_SWITCH_EXHAUSTIVE` | switch over closed enum must cover every case or use '_' | `src/mir_verify_util.zig:128`<br>`src/sema.zig:6461` |
| `E_CLOSURE_SIGNATURE_MISMATCH` | bind target does not match the expected closure type<br>closure signature does not match the expected type | `src/sema.zig:5206`<br>`src/sema.zig:5213` |
| `E_COMPTIME_ARG_REQUIRED` | comptime parameter requires a compile-time constant argument | `src/sema.zig:3157` |
| `E_COMPTIME_ERROR` | _see source_ | `src/sema.zig:2150` |
| `E_COMPTIME_FORBIDS_RUNTIME_EFFECT` | comptime code cannot alter runtime control flow<br>comptime code cannot call runtime functions<br>comptime code cannot perform runtime hardware or I/O effects | `src/sema.zig:2382`<br>`src/sema.zig:2420`<br>`src/sema.zig:2440`<br>`src/sema.zig:2452`<br>`src/sema.zig:2494`<br>`src/sema.zig:3016`<br>_+3 more_ |
| `E_COMPTIME_TRAP` | trap during const eval is a compile error | `src/sema.zig:2130`<br>`src/sema.zig:2138`<br>`src/sema.zig:2141`<br>`src/sema.zig:2156`<br>`src/sema.zig:2163`<br>`src/sema.zig:2811`<br>_+1 more_ |
| `E_CONDITION_NOT_BOOL` | condition must be bool | `src/mir_verify_util.zig:91`<br>`src/sema.zig:2301`<br>`src/sema.zig:2483` |
| `E_CONST_GET_BASE` | const_get is defined only for fixed-length arrays | `src/sema.zig:4018`<br>`src/sema.zig:4022` |
| `E_CONST_GET_BOUNDS` | const_get index is out of bounds for the fixed-length array | `src/sema.zig:4027` |
| `E_CONST_GET_INDEX` | const_get requires exactly one compile-time usize index | `src/sema.zig:4014` |
| `E_CONTINUE_OUTSIDE_LOOP` | continue is valid only inside a loop | `src/sema.zig:2455` |
| `E_CONVERSION_OPERATION` | from_mod is defined only on wrap&lt;T&gt; targets<br>residue() is defined only on wrap&lt;T&gt; values<br>try_from/trap_from/wrap_from/sat_from are defined only on scalar integer targets<br>_+1 more_ | `src/mir_verify_util.zig:148`<br>`src/sema.zig:3835`<br>`src/sema.zig:3839`<br>`src/sema.zig:3874`<br>`src/sema.zig:3884` |
| `E_COUNTER_OPERATION` | _see source_ | `src/mir_verify_util.zig:147`<br>`src/sema.zig:3850` |
| `E_C_VOID_CONVERSION` | c_void pointer conversions require an explicit FFI boundary operation | `src/mir_verify_util.zig:87`<br>`src/mir_verify_util.zig:88`<br>`src/mir_verify_util.zig:89`<br>`src/mir_verify_util.zig:90`<br>`src/mir_verify_util.zig:112`<br>`src/sema.zig:2968`<br>_+1 more_ |
| `E_C_VOID_DEREF` | c_void pointer cannot be dereferenced | `src/mir_verify_util.zig:184`<br>`src/sema.zig:3299` |
| `E_C_VOID_NO_LAYOUT` | c_void has no fields in MC<br>c_void has no size or alignment in MC<br>c_void has no size or layout in MC; use pointers to c_void at FFI boundaries | `src/mir_verify_util.zig:185`<br>`src/sema.zig:3320`<br>`src/sema.zig:3431`<br>`src/sema.zig:4789` |
| `E_DECLASSIFY_NOT_SECRET` | declassify/reveal applies only to a Secret&lt;T&gt; value | `src/sema.zig:4137` |
| `E_DEFER_CONTROL_FLOW` | defer is lexical cleanup and must not alter control flow | `src/sema.zig:2468` |
| `E_DMA_ADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:170`<br>`src/sema.zig:7446` |
| `E_DMA_ADDR_NOT_PADDR` | _see source_ | `src/mir_verify_util.zig:178`<br>`src/sema.zig:7431` |
| `E_DMA_ADDR_NOT_VADDR` | _see source_ | `src/mir_verify_util.zig:179`<br>`src/sema.zig:7432` |
| `E_DMA_BUF_MODE` | DmaBuf mode must be .coherent or .noncoherent | `src/sema.zig:3614`<br>`src/sema.zig:3619` |
| `E_DMA_CACHE_MODE` | cache clean/invalidate are required only for noncoherent DmaBuf values | `src/mir_verify_util.zig:195`<br>`src/sema.zig:3797` |
| `E_DMA_OPERATION` | cache DMA operation requires a DmaBuf argument<br>dma_addr/as_slice are defined only on DmaBuf values<br>unknown DmaBuf operation | `src/mir_verify_util.zig:190`<br>`src/sema.zig:3792`<br>`src/sema.zig:3806`<br>`src/sema.zig:3822` |
| `E_DROP_LINEAR_RESOURCE` | a linear \`move\` value cannot be \`drop\`ped (it frees nothing); release it with its free function, \`forget_unchecked\` it in an unsafe block once its contents have been transferred, or mark the type \`#[trivial_drop]\` if completing it needs no release | `src/sema_move.zig:2733` |
| `E_DUPLICATE_BACKEND_NAME` | backend symbol "{s}" is assigned to both \`{s}\` and \`{s}\` | `src/sema.zig:4757` |
| `E_DUPLICATE_DECLARATION` | duplicate trait declaration<br>top-level declarations must have unique names | `src/sema.zig:946`<br>`src/sema.zig:6160` |
| `E_DUPLICATE_ENUM_CASE` | enum case names must be unique | `src/sema.zig:1037` |
| `E_DUPLICATE_ENUM_VALUE` | enum case representation values must be unique | `src/sema.zig:1060` |
| `E_DUPLICATE_LOCAL` | local bindings must have unique names in the current scope | `src/async_lower.zig:1392`<br>`src/sema.zig:2617`<br>`src/sema.zig:6678` |
| `E_DUPLICATE_OVERLAY_FIELD` | overlay union field names must be unique | `src/sema.zig:1275` |
| `E_DUPLICATE_PACKED_BITS_FIELD` | packed bits field names must be unique | `src/sema.zig:1260` |
| `E_DUPLICATE_PARAMETER` | function parameter names must be unique | `src/async_lower.zig:1411`<br>`src/sema.zig:1417` |
| `E_DUPLICATE_STRUCT_FIELD` | struct field names must be unique | `src/sema.zig:1102` |
| `E_DUPLICATE_STRUCT_LITERAL_FIELD` | struct literal field names must be unique | `src/mir_verify_util.zig:103`<br>`src/sema.zig:5092`<br>`src/sema.zig:5144` |
| `E_DUPLICATE_SWITCH_CASE` | switch case pattern is already covered | `src/mir_verify_util.zig:126`<br>`src/mir_verify_util.zig:132`<br>`src/sema.zig:6475`<br>`src/sema.zig:6493`<br>`src/sema.zig:6511`<br>`src/sema.zig:6525`<br>_+4 more_ |
| `E_DUPLICATE_UNION_CASE` | safe tagged union case names must be unique | `src/sema.zig:1237` |
| `E_DYN_FORGE` | a \`*dyn Trait\` cannot be hand-assembled in safe code; build it with \`&amp;x\` / \`&amp;mut x\` (the checked coercion). \`*dyn\` is a compiler-protected type — fabrication requires \`unsafe\` | `src/sema.zig:5341` |
| `E_DYN_MOVE_SELF` | a consuming (\`move self\`/by-value) method cannot be called through \`*dyn Trait\` (you cannot move out of a borrowed trait object) | `src/sema.zig:3096` |
| `E_DYN_MUT_BORROW` | a \`*mut dyn Trait\` requires \`&amp;mut\` of a mutable place<br>a \`*mut dyn Trait\` requires a \`*mut T\` (mutable) source pointer | `src/sema.zig:5299`<br>`src/sema.zig:5330` |
| `E_ENUM_CASE_VALUE_NOT_INTEGER` | enum representation values must be integer literals | `src/sema.zig:1050` |
| `E_ENUM_CASE_VALUE_OUT_OF_RANGE` | enum case value is outside the representation type range | `src/sema.zig:1056` |
| `E_ENUM_LITERAL_REQUIRES_TARGET` | enum literal requires an explicit enum target type | `src/sema.zig:5747` |
| `E_ENUM_REPR_NOT_INTEGER` | enum representation type must be an integer type | `src/sema.zig:1026` |
| `E_EXTERN_STRUCT_BY_VALUE` | extern/export functions cannot pass structs or tagged optional values by value until target ABI classification is implemented; pass a pointer instead<br>extern/export functions cannot return structs or tagged optional values by value until target ABI classification is implemented; return through an out pointer instead | `src/sema.zig:1506`<br>`src/sema.zig:1511` |
| `E_FN_POINTER_SIGNATURE_MISMATCH` | function signature does not match the expected function-pointer type<br>function-pointer signature does not match the expected type | `src/sema.zig:5189`<br>`src/sema.zig:5197`<br>`src/sema.zig:5436`<br>`src/sema.zig:5444` |
| `E_FOR_BASE_NOT_ARRAY_OR_SLICE` | for loops iterate over arrays and slices | `src/mir_verify_util.zig:84`<br>`src/sema.zig:2303` |
| `E_GENERIC_LOOKAHEAD_LIMIT` | generic-call lookahead exceeds {d} tokens | `src/parser.zig:1764` |
| `E_GENERIC_TYPE_ARG_COUNT` | generic type has the wrong number of type arguments | `src/sema.zig:3475`<br>`src/sema.zig:3484` |
| `E_GLOBAL_INITIALIZER_NOT_STATIC` | global initializer must be a compile-time static value for M0 C emission | `src/sema.zig:1324` |
| `E_GLOBAL_REQUIRES_TYPE` | global declarations require an explicit storage type | `src/sema.zig:1011` |
| `E_IF_LET_NARROW_PATTERN` | if let supports only optional bindings and Result ok(...) or err(...) bindings | `src/mir_verify_util.zig:118`<br>`src/sema.zig:6315`<br>`src/sema.zig:6322` |
| `E_IF_LET_OPTIONAL_REQUIRED` | plain if let binding requires a nullable value | `src/mir_verify_util.zig:115`<br>`src/sema.zig:6307` |
| `E_IF_LET_RESULT_REQUIRED` | if let ok(...) or err(...) requires a Result value | `src/mir_verify_util.zig:116`<br>`src/sema.zig:6318` |
| `E_IF_LET_RESULT_TAG` | if let result narrowing supports only ok(...) or err(...) | `src/mir_verify_util.zig:117`<br>`src/sema.zig:6313` |
| `E_ILLEGAL_SLICE_CAST` | cannot cast a non-slice value to a slice: a slice is a fat pointer (ptr+len) and the length has no source. Build one with a slicing expression \`a[i..j]\`, a byte view (\`mem.as_bytes\`), or a string literal | `src/sema.zig:2977` |
| `E_IMPORT_DEPTH_LIMIT` | import depth exceeds configured limit {d} | `src/loader.zig:418`<br>`src/loader.zig:508` |
| `E_IMPORT_EXPANDED_SOURCE_LIMIT` | expanded source exceeds configured limit {d} bytes | `src/loader.zig:520`<br>`src/loader.zig:523`<br>`src/loader.zig:526` |
| `E_IMPORT_FILE_LIMIT` | import graph exceeds configured file limit {d} | `src/loader.zig:422`<br>`src/loader.zig:511` |
| `E_IMPORT_NOT_FOUND` | cannot find import "{s}" (resolved candidate: {s}) | `src/loader.zig:433` |
| `E_IMPORT_OUTSIDE_SANDBOX` | import "{s}" resolves to {s}, outside the import sandbox rooted at {s} | `src/loader.zig:408` |
| `E_IMPORT_TOTAL_BYTES_LIMIT` | import graph exceeds configured cumulative input limit {d} bytes | `src/loader.zig:514`<br>`src/loader.zig:517` |
| `E_INDEX_BASE_NOT_ARRAY_OR_SLICE` | indexing is defined only for arrays and slices<br>slicing is defined only for arrays and slices | `src/mir_verify_util.zig:85`<br>`src/sema.zig:3255`<br>`src/sema.zig:3277` |
| `E_INDEX_NOT_USIZE` | array and slice indices must be checked usize<br>slice range bounds must be checked usize | `src/mir_verify_util.zig:86`<br>`src/sema.zig:3264`<br>`src/sema.zig:3281`<br>`src/sema.zig:3285`<br>`src/sema.zig:5725` |
| `E_INTEGER_LITERAL_OUT_OF_RANGE` | integer literal is not representable in the annotated type | `src/mir_verify_util.zig:83`<br>`src/sema.zig:4929`<br>`src/sema.zig:4937`<br>`src/sema.zig:4950`<br>`src/sema.zig:4953`<br>`src/sema.zig:4960`<br>_+5 more_ |
| `E_INTERNAL_GENERIC_LINKAGE_COLLISION` | unequal generic instance keys produced the same linkage name \`{s}\` | `src/monomorphize.zig:1191` |
| `E_INTERNAL_OOM` | compiler ran out of memory while building symbol tables; results are incomplete | `src/sema.zig:675` |
| `E_INVALID_ASSIGNMENT_TARGET` | assignment target must be assignable storage | `src/mir_verify_util.zig:138`<br>`src/sema.zig:2490` |
| `E_INVALID_ERROR_FROM` | #[error_from] fn must convert one named error type to another (fn(E1) -&gt; E2)<br>#[error_from] fn must take exactly one parameter (the source error type) | `src/sema.zig:2748`<br>`src/sema.zig:2754` |
| `E_INVALID_TRAP_KIND` | trap expects exactly one language TrapKind<br>trap kind must be a language TrapKind enum literal<br>unknown language TrapKind | `src/sema.zig:4768`<br>`src/sema.zig:4774`<br>`src/sema.zig:4779` |
| `E_IRQ_CONTEXT_BLOCKING` | _see source_ | `src/mir_verify_util.zig:47` |
| `E_IRQ_CONTEXT_CALL` | an #[irq_context] function may not dispatch through \`*dyn Trait\` (a virtual call is an indirect call whose target may sleep or block)<br>an #[irq_context] function may not make an indirect/closure call (the target may sleep or block)<br>an #[irq_context] function may not make an indirect/fn-pointer call (the target may sleep or block)<br>_+1 more_ | `src/mir_verify_util.zig:46`<br>`src/sema.zig:3059`<br>`src/sema.zig:3074`<br>`src/sema.zig:3104`<br>`src/sema.zig:3139` |
| `E_LEX_INVALID_CHAR_LITERAL` | invalid char literal | `src/lexer.zig:261` |
| `E_LEX_INVALID_ESCAPE_SEQUENCE` | invalid escape sequence | `src/lexer.zig:278` |
| `E_LEX_INVALID_FLOAT_LITERAL` | invalid float literal | `src/lexer.zig:211` |
| `E_LEX_INVALID_INTEGER_LITERAL` | invalid integer literal | `src/lexer.zig:213` |
| `E_LEX_UNEXPECTED_BYTE` | unexpected byte '{c}' | `src/lexer.zig:64` |
| `E_LEX_UNTERMINATED_BLOCK_COMMENT` | unterminated block comment | `src/lexer.zig:93` |
| `E_LEX_UNTERMINATED_CHAR_LITERAL` | unterminated char literal | `src/lexer.zig:244`<br>`src/lexer.zig:257` |
| `E_LEX_UNTERMINATED_ESCAPE_SEQUENCE` | unterminated escape sequence | `src/lexer.zig:267` |
| `E_LEX_UNTERMINATED_STRING_LITERAL` | unterminated string literal | `src/lexer.zig:222`<br>`src/lexer.zig:233` |
| `E_LITERAL_REQUIRES_TARGET` | literal requires an explicit target type | `src/sema.zig:5751` |
| `E_LOCAL_ADDRESS_ESCAPE` | cannot return a closure that captures local storage (the environment would dangle)<br>cannot return the address of local storage<br>cannot return the address of local storage inside an aggregate (the borrow would dangle)<br>_+2 more_ | `src/mir_verify_util.zig:196`<br>`src/sema.zig:2711`<br>`src/sema.zig:2715`<br>`src/sema.zig:5388`<br>`src/sema.zig:5393`<br>`src/sema.zig:5481`<br>_+1 more_ |
| `E_LOCAL_REQUIRES_INITIALIZER` | ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage | `src/sema.zig:2565` |
| `E_MC_VOID_POINTER_FFI` | use c_void for C opaque object pointers, not MC void | `src/sema.zig:3429` |
| `E_MIR_CFG` | MIR verifier found malformed control-flow graph | `src/mir.zig:9480` |
| `E_MMIO_ACCESS_FORBIDDEN` | MIR verifier found MMIO register access disallowed by Reg/RegBits mode<br>MMIO register access mode does not allow read<br>MMIO register access mode does not allow write | `src/mir.zig:877`<br>`src/sema.zig:3653`<br>`src/sema.zig:3663` |
| `E_MMIO_ACCESS_MODE` | MMIO register access mode must be .read, .write, or .read_write | `src/sema.zig:3633`<br>`src/sema.zig:3638` |
| `E_MMIO_DIRECT_ASSIGN` | MIR verifier found direct assignment to an MMIO register<br>MMIO registers must be accessed through typed read/write methods | `src/mir.zig:871`<br>`src/sema.zig:2496` |
| `E_MMIO_ORDERING` | MMIO read ordering must be .relaxed or .acquire<br>MMIO write ordering must be .relaxed or .release | `src/mir_verify_util.zig:192`<br>`src/sema.zig:4150`<br>`src/sema.zig:4154`<br>`src/sema.zig:4160`<br>`src/sema.zig:4164` |
| `E_MMIO_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:172`<br>`src/sema.zig:7448` |
| `E_MMIO_PTR_TARGET` | MmioPtr target must be an extern mmio struct type | `src/sema.zig:3586`<br>`src/sema.zig:3591` |
| `E_MMIO_REGBITS_TYPE` | RegBits value type must be a known packed bits type | `src/sema.zig:3558` |
| `E_MMIO_REGISTER_POSITION` | Reg and RegBits types are valid only as extern mmio struct fields | `src/sema.zig:3580` |
| `E_MMIO_REGISTER_WIDTH` | MMIO register width must be u8, u16, u32, or u64 | `src/sema.zig:3625` |
| `E_MONOMORPHIZATION_LIMIT` | _see source_ | `src/monomorphize.zig:941` |
| `E_MOVE_ARRAY_UNSUPPORTED` | a non-\`move\` struct cannot store an array of linear \`move\` values by value; make the struct \`move\`, or hold the resources behind pointers<br>cannot assign a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to update<br>cannot defer a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to reserve<br>_+4 more_ | `src/sema.zig:1008`<br>`src/sema.zig:1097`<br>`src/sema.zig:1410`<br>`src/sema.zig:1435`<br>`src/sema_move.zig:1036`<br>`src/sema_move.zig:2680`<br>_+2 more_ |
| `E_MOVE_BRANCH_MISMATCH` | linear \`move\` field has inconsistent ownership across control-flow branches<br>linear \`move\` value has inconsistent ownership across control-flow branches | `src/sema_move.zig:1524`<br>`src/sema_move.zig:1533`<br>`src/sema_move.zig:1552`<br>`src/sema_move.zig:2993`<br>`src/sema_move.zig:3009` |
| `E_MOVE_FIELD_IN_NONMOVE` | a linear \`move\` value cannot be stored by value in a non-\`move\` struct (it would be duplicated or leaked); make the struct \`move\`, or store the resource behind a pointer | `src/sema.zig:1099` |
| `E_MOVE_LOOP_RESOURCE` | cannot consume or reserve an outer linear \`move\` value inside a loop; the loop may run zero or multiple times<br>cannot move an outer linear \`move\` place inside a loop; the loop may run zero or multiple times | `src/sema_move.zig:740`<br>`src/sema_move.zig:755` |
| `E_NAKED_BODY` | a #[naked] function body must be exactly one \`asm\` block (optionally wrapped in one \`unsafe {}\`); there is no frame for locals, statements, or expressions | `src/sema.zig:1452` |
| `E_NAKED_RETURN` | a #[naked] function must return \`never\` or \`void\`; it cannot synthesize a value return (the asm body owns the calling convention) | `src/sema.zig:1447` |
| `E_NESTING_TOO_DEEP` | nesting too deep | `src/parser.zig:2190` |
| `E_NEVER_FALLTHROUGH` | function declared -&gt; never can fall off the end | `src/hir.zig:177`<br>`src/mir.zig:795`<br>`src/sema.zig:1494` |
| `E_NEVER_RETURNS` | function declared -&gt; never cannot return normally | `src/sema.zig:2426`<br>`src/sema.zig:2433` |
| `E_NEVER_STORAGE` | never is a control-flow type and cannot be used for storage | `src/sema.zig:3435`<br>`src/sema.zig:3601` |
| `E_NO_ERROR_CONVERSION` | '?' cannot convert the propagated error to the function's error type; declare an #[error_from] fn converting it | `src/sema.zig:2784` |
| `E_NO_IMPLICIT_CONVERSION` | MaybeUninit.write payload must match the storage type<br>Secret&lt;T&gt; can only wrap a value of its underlying type T<br>annotated local initializer requires an explicit conversion<br>_+9 more_ | `src/mir_verify_util.zig:98`<br>`src/mir_verify_util.zig:106`<br>`src/mir_verify_util.zig:131`<br>`src/mir_verify_util.zig:160`<br>`src/sema.zig:1301`<br>`src/sema.zig:1302`<br>_+39 more_ |
| `E_NO_IMPLICIT_INTEGER_PROMOTION` | integer arithmetic requires matching types or an explicit conversion | `src/mir_verify_util.zig:159`<br>`src/sema.zig:5796` |
| `E_NO_IMPLICIT_POINTER_CONVERSION` | pointer and view conversions must be explicit<br>pointer comparisons require compatible pointer or view operands | `src/mir_verify_util.zig:78`<br>`src/mir_verify_util.zig:79`<br>`src/mir_verify_util.zig:92`<br>`src/mir_verify_util.zig:93`<br>`src/mir_verify_util.zig:94`<br>`src/mir_verify_util.zig:95`<br>_+6 more_ |
| `E_NO_LANG_TRAP_EDGE` | HIR verifier found language trap edge {s} before C emission<br>MIR verifier found language trap edge {s}<br>assert may emit a language trap in #[no_lang_trap]<br>_+9 more_ | `src/hir.zig:191`<br>`src/mir.zig:804`<br>`src/sema.zig:2479`<br>`src/sema.zig:2808`<br>`src/sema.zig:2818`<br>`src/sema.zig:2835`<br>_+7 more_ |
| `E_NULLABLE_DYN_DISPATCH` | cannot dispatch a method through a \`?*dyn Trait\` (it may be absent / \`none\`); narrow it first with \`if let\` / \`switch\`, or \`unwrap\` it to a \`*dyn Trait\` | `src/sema.zig:3085` |
| `E_NULLABLE_DYN_NARROW` | a \`?*dyn Trait\` cannot coerce to a non-null \`*dyn Trait\`: it may be \`none\`. Narrow it with \`if let\` / \`switch\`, or \`unwrap\` it first | `src/sema.zig:5288` |
| `E_NULL_NON_NULL_POINTER` | null cannot initialize a non-null pointer | `src/mir_verify_util.zig:77`<br>`src/sema.zig:4993` |
| `E_NULL_REQUIRES_TARGET` | null requires an explicit nullable pointer target type | `src/sema.zig:1289`<br>`src/sema.zig:2527` |
| `E_OPAQUE_DECLASSIFY` | casting an \`opaque struct\` value to another type declassifies its private fields; use an accessor in its \`impl\`, or \`unsafe\` | `src/sema.zig:5694` |
| `E_OPERATOR_OPERAND` | arithmetic operators require integer or arithmetic-domain operands<br>bitwise operators require unsigned integer or wrapping operands<br>equality operators require comparable operands<br>_+3 more_ | `src/mir_verify_util.zig:163`<br>`src/mir_verify_util.zig:197`<br>`src/sema.zig:2885`<br>`src/sema.zig:5802`<br>`src/sema.zig:5806`<br>`src/sema.zig:5813`<br>_+9 more_ |
| `E_ORDERED_ARITH_DOMAIN_OPERAND` | ordered comparisons are not defined on wrap, serial, or counter arithmetic domains | `src/mir_verify_util.zig:145`<br>`src/sema.zig:5902` |
| `E_ORPHAN_IMPL` | impl of an opaque type must be in its defining module (file); a peer impl in another file cannot reach its private fields<br>trait impl for a type must be in the file that declares the type | `src/sema.zig:6121`<br>`src/sema.zig:6137` |
| `E_PACKED_BITS_FIELD_NOT_BOOL` | packed bits fields must be bool | `src/sema.zig:1257` |
| `E_PACKED_BITS_REPR_NOT_INTEGER` | packed bits representation type must be an integer type | `src/sema.zig:1249` |
| `E_PADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:168`<br>`src/sema.zig:7444` |
| `E_PARSE` | _see source_ | `src/parser.zig:2168` |
| `E_PARSE_EXPECTED_EXPRESSION` | _see source_ | `src/parser.zig:2166` |
| `E_PARSE_EXPECTED_PARAMETER_NAME` | _see source_ | `src/parser.zig:2167` |
| `E_PHYS_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:173`<br>`src/sema.zig:7449` |
| `E_POINTER_ARITH_SINGLE_OBJECT` | single-object pointers do not support arithmetic | `src/mir_verify_util.zig:161`<br>`src/sema.zig:2914` |
| `E_POINTER_ORDERING` | optional values support only equality comparisons against null<br>pointer and view values support only equality comparisons | `src/mir_verify_util.zig:162`<br>`src/sema.zig:5933`<br>`src/sema.zig:5949` |
| `E_PRECISE_ASM_CONTRACT` | precise asm requires #[unsafe_contract(precise_asm)] | `src/sema.zig:2385` |
| `E_PRIVATE_FIELD` | cannot construct an \`opaque struct\` outside its associated functions (\`impl\` block); its fields are private<br>field of an \`opaque struct\` is private to its associated functions (\`impl\` block) | `src/sema.zig:5069`<br>`src/sema.zig:5979` |
| `E_PRIVATE_IMPORT` | this name is private under the active visibility mode; only \`pub\`/\`export\` items are visible to importing files | `src/sema.zig:6067` |
| `E_REDUCE_ARG_NOT_SLICE` | reduction expects a slice (\`[]const T\`) of the element type<br>reduction slice element type must match the reduction type argument | `src/sema.zig:3919`<br>`src/sema.zig:3926` |
| `E_REDUCE_REQUIRES_FLOAT` | floating-point reductions are restricted to f32/f64 | `src/sema.zig:3896`<br>`src/sema.zig:3901`<br>`src/sema.zig:3908` |
| `E_REDUCE_REQUIRES_INTEGER` | reduce.sum_checked is restricted to integer types | `src/sema.zig:3896`<br>`src/sema.zig:3901`<br>`src/sema.zig:3905` |
| `E_REFLECTION_FIELD_LITERAL` | field reflection requires an enum-literal field name | `src/sema.zig:4800` |
| `E_REFLECTION_GENERIC_ARG_COUNT` | reflection generic type has the wrong number of type arguments | `src/sema.zig:4843` |
| `E_REFLECTION_TYPE_ARG` | reflection type argument must be a type name | `src/sema.zig:4832` |
| `E_REFLECTION_TYPE_VALUE` | field_type produces a type and is valid only in type position | `src/sema.zig:4813` |
| `E_REFLECTION_UNKNOWN_TYPE` | field reflection requires a known field-bearing layout type<br>reflection layout could not be computed for this type<br>reflection requires a known layout-capable type | `src/sema.zig:4847`<br>`src/sema.zig:4868`<br>`src/sema.zig:4898`<br>`src/sema.zig:4907`<br>`src/sema.zig:4911`<br>`src/sema.zig:4922` |
| `E_REPRESENTATION_CHECK_MISSING` | MIR verifier found representation-sensitive value use without dominating check | `src/mir.zig:885`<br>`src/mir.zig:892` |
| `E_RESERVED_C_IDENTIFIER` | identifier is reserved by the C backend or C headers; choose a different source name<br>local binding name is reserved by the C backend or C headers; choose a different source name<br>parameter name is reserved by the C backend or C headers; choose a different source name | `src/sema.zig:953`<br>`src/sema.zig:1413`<br>`src/sema.zig:2606` |
| `E_RESERVED_QUALIFIED_NAME` | a local binding may not shadow a module/impl name<br>a parameter may not shadow a module/impl name<br>a top-level value may not shadow a module/impl name | `src/sema.zig:960`<br>`src/sema.zig:1415`<br>`src/sema.zig:2610` |
| `E_RESOURCE_LEAK` | linear \`move\` value bound in a switch arm is never consumed (must be moved, returned, or freed)<br>linear \`move\` value bound in an if-let branch is never consumed (must be moved, returned, or freed)<br>linear \`move\` value created in only one branch is never consumed before the branch exits<br>_+2 more_ | `src/sema_move.zig:693`<br>`src/sema_move.zig:723`<br>`src/sema_move.zig:1178`<br>`src/sema_move.zig:1251`<br>`src/sema_move.zig:1310`<br>`src/sema_move.zig:1345`<br>_+2 more_ |
| `E_RESOURCE_OVERWRITE` | cannot assign a linear \`move\` array element through an unknown dynamic index; the selected live element must be consumed first<br>cannot overwrite a live linear \`move\` array element; consume it first<br>cannot overwrite a live linear \`move\` field; consume it first<br>_+1 more_ | `src/sema_move.zig:950`<br>`src/sema_move.zig:1005`<br>`src/sema_move.zig:1022`<br>`src/sema_move.zig:1031` |
| `E_RETURN_MISSING` | function return type requires all paths to return a value | `src/hir.zig:177`<br>`src/mir.zig:795`<br>`src/sema.zig:1496` |
| `E_RETURN_REQUIRES_VALUE` | function return type requires a value | `src/sema.zig:2435` |
| `E_RETURN_TYPE_MISMATCH` | return expression must match the declared return type | `src/mir_verify_util.zig:96`<br>`src/mir_verify_util.zig:114`<br>`src/sema.zig:5371`<br>`src/sema.zig:5372`<br>`src/sema.zig:5373`<br>`src/sema.zig:5395`<br>_+3 more_ |
| `E_SECRET_BRANCH` | secret value cannot drive a branch or switch; this would leak it through control-flow timing — use declassify/reveal (unsafe) or a constant-time select<br>secret value cannot drive a loop condition; this would leak it through control-flow timing | `src/sema.zig:2299`<br>`src/sema.zig:6402` |
| `E_SECRET_DECLASSIFY` | casting a Secret&lt;T&gt; to a non-secret type declassifies it; use reveal/declassify inside unsafe | `src/sema.zig:5611` |
| `E_SECRET_INDEX` | secret value cannot be used as an array index; a secret-dependent memory access leaks it through the cache — declassify/reveal it first (unsafe) or use a constant-time table scan<br>secret value cannot offset a pointer; a secret-dependent memory access leaks it through the cache | `src/sema.zig:2919`<br>`src/sema.zig:3262` |
| `E_SERIAL_OPERATION` | _see source_ | `src/mir_verify_util.zig:146`<br>`src/sema.zig:3850` |
| `E_SIGNED_UNSIGNED_MIX` | signed and unsigned integers do not implicitly mix | `src/mir_verify_util.zig:158`<br>`src/sema.zig:5793` |
| `E_SLEEP_IN_ATOMIC` | calling a #[may_sleep] op from an #[irq_context] function (sleeping in interrupt) | `src/sema.zig:3137` |
| `E_STRUCT_LITERAL_MISSING_FIELD` | packed bits literal must initialize every field<br>struct literal must initialize every field | `src/mir_verify_util.zig:105`<br>`src/sema.zig:5129`<br>`src/sema.zig:5167` |
| `E_STRUCT_LITERAL_REQUIRES_TARGET` | struct literal requires an explicit struct target type | `src/sema.zig:2540` |
| `E_SWITCH_MULTI_BINDING_ARM` | switch arms with multiple patterns cannot introduce bindings | `src/mir_verify_util.zig:121`<br>`src/sema.zig:6619` |
| `E_SWITCH_RESULT_REQUIRED` | switch ok or err patterns require a Result value<br>switch ok(...) or err(...) binding requires a Result value | `src/mir_verify_util.zig:120`<br>`src/sema.zig:6594`<br>`src/sema.zig:6608` |
| `E_SWITCH_RESULT_TAG` | switch result binding supports only ok(...) or err(...)<br>switch result patterns support only ok or err tags | `src/mir_verify_util.zig:119`<br>`src/sema.zig:6592`<br>`src/sema.zig:6606` |
| `E_TRAIT_BOUND_MEMBER` | generic type-parameter member calls require a \`where\` bound whose trait declares that member | `src/sema.zig:3411` |
| `E_TRAIT_EFFECT_MISMATCH` | impl method's effect annotations (#[may_sleep]) do not match the trait signature | `src/sema.zig:6256` |
| `E_TRAIT_INCOHERENT` | duplicate \`impl Trait for Type\` (coherence: at most one impl per (Trait, Type) pair) | `src/sema.zig:6204` |
| `E_TRAIT_MISSING_METHOD` | impl does not provide a trait method | `src/sema.zig:6237` |
| `E_TRAIT_NOT_OBJECT_SAFE` | trait is not object-safe (every method must take \`self\` by pointer and be non-generic) so it cannot be used as \`*dyn Trait\` | `src/sema.zig:3524` |
| `E_TRAIT_NOT_SATISFIED` | a \`*dyn Trait\` can only be formed from a concrete nominal type that implements the trait<br>no \`impl Trait for Type\` for this concrete type, so it cannot coerce to \`*dyn Trait\` | `src/monomorphize.zig:846`<br>`src/sema.zig:5304`<br>`src/sema.zig:5308`<br>`src/sema.zig:5334` |
| `E_TRAIT_SELF_MODE_MISMATCH` | impl method's self-mode does not match the trait signature | `src/sema.zig:6241` |
| `E_TRAIT_SIGNATURE_MISMATCH` | impl method's parameter count does not match the trait signature<br>impl method's parameter type does not match the trait signature<br>impl method's return type does not match the trait signature | `src/sema.zig:6282`<br>`src/sema.zig:6289`<br>`src/sema.zig:6299` |
| `E_TRAIT_UNKNOWN_METHOD` | impl provides a method the trait does not declare | `src/sema.zig:6262` |
| `E_TRIVIAL_DROP_NOT_MOVE` | #[trivial_drop] applies only to a \`move struct\` (it asserts the resource's completion needs no release) | `src/sema.zig:579` |
| `E_TRY_REQUIRES_RESULT_OR_NULLABLE` | postfix '?' requires a Result or nullable operand | `src/mir_verify_util.zig:111`<br>`src/sema.zig:2822` |
| `E_TYPE_ALIAS_CYCLE` | type aliases must not form recursive cycles | `src/sema.zig:711` |
| `E_TYPE_ARG_REQUIRED` | type parameter requires a known type argument<br>type parameter requires a type argument | `src/sema.zig:3152`<br>`src/sema.zig:3154` |
| `E_UNBOUNDED_INDIRECT_CALL` | a \`#[bounded]\` function may not dispatch through \`*dyn Trait\` (the callee's termination cannot be checked through the vtable)<br>a \`#[bounded]\` function may not make an indirect/closure call (the callee's termination cannot be checked through the closure)<br>a \`#[bounded]\` function may not make an indirect/fn-pointer call (the callee's termination cannot be checked through the pointer) | `src/sema.zig:3065`<br>`src/sema.zig:3077`<br>`src/sema.zig:3107` |
| `E_UNBOUNDED_LOOP` | loop in a bounded/IRQ-context function is not statically bounded (no monotone counter toward a bound, fixed-range for, or break) | `src/sema.zig:4251` |
| `E_UNBOUNDED_RECURSION` | direct recursion from a bounded/IRQ-context function (a kernel must not recurse unboundedly in interrupt/atomic context)<br>recursive direct-call cycle among bounded/IRQ-context functions (no decreasing metric is proven) | `src/sema.zig:4290`<br>`src/sema.zig:4386` |
| `E_UNCHECKED_OUTSIDE_CONTRACT` | MIR verifier found unchecked optimizer assumption outside matching contract region<br>unchecked operation requires matching #[unsafe_contract] | `src/mir.zig:815`<br>`src/sema.zig:3002` |
| `E_UNHANDLED_RESULT` | Result defer cleanup must be handled or propagated<br>Result expression statements must be handled or propagated<br>Result local must be handled before reassignment<br>_+2 more_ | `src/mir_verify_util.zig:110`<br>`src/sema.zig:2264`<br>`src/sema.zig:2279`<br>`src/sema.zig:2282`<br>`src/sema.zig:2465`<br>`src/sema.zig:2474` |
| `E_UNINIT_REQUIRES_STORAGE` | uninit is valid only for explicit typed mutable storage initialization | `src/sema.zig:1296`<br>`src/sema.zig:2521`<br>`src/sema.zig:2675`<br>`src/sema.zig:5365`<br>`src/sema.zig:5426` |
| `E_UNION_CASE_HAS_NO_PAYLOAD` | union case binding requires a payload case<br>union case has no payload type | `src/mir_verify_util.zig:130`<br>`src/sema.zig:4919`<br>`src/sema.zig:6603` |
| `E_UNKNOWN_ENUM_CASE` | enum has no case with this name | `src/mir_verify_util.zig:127`<br>`src/sema.zig:5565`<br>`src/sema.zig:6585` |
| `E_UNKNOWN_FUNCTION` | unknown function | `src/sema.zig:3379` |
| `E_UNKNOWN_IDENTIFIER` | asm output names an unknown local<br>unknown identifier<br>unknown identifier \`{s}\` | `src/diagnostics.zig:437`<br>`src/diagnostics.zig:445`<br>`src/diagnostics.zig:489`<br>`src/sema.zig:2398`<br>`src/sema.zig:3363` |
| `E_UNKNOWN_LOOP_LABEL` | break targets a loop label that is not in scope<br>continue targets a loop label that is not in scope | `src/sema.zig:2446`<br>`src/sema.zig:2458` |
| `E_UNKNOWN_STRUCT_FIELD` | layout type has no field with this name<br>member access requires a struct, packed-bits, or overlay-union value<br>packed bits type has no field with this name<br>_+1 more_ | `src/mir_verify_util.zig:104`<br>`src/sema.zig:4903`<br>`src/sema.zig:4915`<br>`src/sema.zig:5099`<br>`src/sema.zig:5151`<br>`src/sema.zig:5986`<br>_+1 more_ |
| `E_UNKNOWN_TRAIT` | unknown trait in \`*dyn Trait\`<br>unknown trait in impl | `src/sema.zig:3520`<br>`src/sema.zig:6229` |
| `E_UNKNOWN_TYPE` | unknown generic type name<br>unknown type name | `src/sema.zig:3437`<br>`src/sema.zig:3481` |
| `E_UNKNOWN_UNION_CASE` | union has no case with this name | `src/mir_verify_util.zig:129`<br>`src/sema.zig:5503`<br>`src/sema.zig:5541`<br>`src/sema.zig:6589`<br>`src/sema.zig:6601` |
| `E_UNSAFE_REQUIRED` | MIR verifier found unsafe machine effect outside unsafe context<br>arc_get_mut yields an aliasable \`*mut T\` whose uniqueness the checker cannot enforce; it requires an unsafe context (do not arc_clone/publish the handle while the pointer lives)<br>declassify/reveal escapes the constant-time discipline and requires unsafe<br>_+2 more_ | `src/mir.zig:822`<br>`src/sema.zig:2379`<br>`src/sema.zig:3006`<br>`src/sema.zig:3013`<br>`src/sema.zig:3220`<br>`src/sema.zig:3296`<br>_+2 more_ |
| `E_UNSIGNED_NEGATION` | unsigned checked integers do not support unary '-' | `src/mir_verify_util.zig:153`<br>`src/sema.zig:2838` |
| `E_UNUSED_MOVE_RESULT` | the linear \`move\` result of this expression is discarded; bind it with \`let\`, return it, or pass it to a consuming function | `src/sema_move.zig:798` |
| `E_USERPTR_CAST_DEREF` | casting a UserPtr&lt;T&gt; to a derefable kernel pointer bypasses uaccess validation; only UserPtr&lt;-&gt;usize is permitted | `src/sema.zig:5618` |
| `E_USER_PTR_DEREF` | cannot directly access a field through UserPtr; copy it in with copy_from_user first | `src/mir_verify_util.zig:171`<br>`src/sema.zig:3326`<br>`src/sema.zig:7447` |
| `E_USE_AFTER_MOVE` | borrow of linear \`move\` array element after it was moved out<br>borrow of linear \`move\` field after it was moved out<br>borrow of linear \`move\` place after one of its child places was moved out<br>_+28 more_ | `src/sema_move.zig:952`<br>`src/sema_move.zig:1003`<br>`src/sema_move.zig:1020`<br>`src/sema_move.zig:1029`<br>`src/sema_move.zig:2625`<br>`src/sema_move.zig:2640`<br>_+42 more_ |
| `E_USE_BEFORE_INIT` | variable initialized with \`uninit\` is read before it is definitely initialized on all paths | `src/sema.zig:1872` |
| `E_VADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:169`<br>`src/sema.zig:7445` |
| `E_VA_START_CONTEXT` | va.start is only valid inside a variadic function | `src/sema.zig:3985` |
| `E_VOID_RETURNS_VALUE` | function declared -&gt; void cannot return a value | `src/sema.zig:2428` |
| `E_VOID_STORAGE` | void is only valid as a function return type or generic marker | `src/sema.zig:3433`<br>`src/sema.zig:3599` |
