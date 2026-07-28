# MC compiler diagnostics

This file is generated from `E_*` diagnostic codes emitted by production Zig sources under `src/`.
Regenerate it with:

```sh
python3 tools/toolchain/diagnostics-reference.py --write
```

Total codes: **241**.

| Code | Message examples | Source references |
|---|---|---|
| `E_ADDRESS_CLASS_CAST` | bitcast may not mint, cross, or strip a built-in address class (PAddr/VAddr/DmaAddr/MmioPtr/...); use the typed constructor or \`unsafe\`<br>casting to a built-in address class forges it from a non-address value; use the typed constructor (pa/va/dma/mmio.map) or \`unsafe\` | `src/sema.zig:4151`<br>`src/sema.zig:5755` |
| `E_ADDRESS_CLASS_MISMATCH` | mmio.map requires a PAddr argument | `src/mir_verify_util.zig:180`<br>`src/sema.zig:4092`<br>`src/sema.zig:7593` |
| `E_ADDRESS_CLASS_OPERATION` | MIR verifier found illegal operation on opaque address class<br>opaque address classes do not support this operator | `src/mir.zig:958`<br>`src/sema.zig:2883`<br>`src/sema.zig:2921` |
| `E_AMBIGUOUS_ERROR_CONVERSION` | multiple #[error_from] conversions for the same source and target error types; keep exactly one | `src/sema.zig:2790` |
| `E_ARITH_DOMAIN_DIVISION` | division and remainder are defined only on checked integers, not arithmetic domains | `src/mir_verify_util.zig:143`<br>`src/sema.zig:2918` |
| `E_ARITH_DOMAIN_UNSIGNED` | MC-C0 arithmetic domains require an unsigned integer type argument | `src/sema.zig:3531` |
| `E_ARITH_POLICY_MIX` | arithmetic domains do not implicitly mix | `src/mir_verify_util.zig:142`<br>`src/mir_verify_util.zig:149`<br>`src/sema.zig:2906` |
| `E_ARRAY_LENGTH_TYPE` | array length must be a compile-time checked usize integer expression | `src/sema.zig:3507` |
| `E_ARRAY_LITERAL_LENGTH` | array literal element count must match the target array length<br>array literal target must have a known constant length | `src/mir_verify_util.zig:102`<br>`src/sema.zig:5071`<br>`src/sema.zig:5075` |
| `E_ARRAY_LITERAL_REQUIRES_TARGET` | array literal requires an explicit array target type | `src/sema.zig:2559` |
| `E_ARRAY_TO_POINTER_DECAY` | arrays do not implicitly decay to pointers | `src/mir_verify_util.zig:97`<br>`src/sema.zig:5047` |
| `E_ASM_ARCH_MIXED` | inline-asm block mixes registers from more than one architecture | `src/sema.zig:4741` |
| `E_ASM_CLOBBER_CONFLICT` | inline-asm clobbers a register it also binds to an operand | `src/sema.zig:4779` |
| `E_ASM_REGISTER_CONFLICT` | inline-asm binds the same register to more than one operand | `src/sema.zig:4757`<br>`src/sema.zig:4767` |
| `E_ASM_UNKNOWN_REGISTER` | inline-asm names a register that is not valid on any supported architecture | `src/sema.zig:4734` |
| `E_ASSIGN_THROUGH_CONST_VIEW` | cannot assign through a const pointer or view | `src/mir_verify_util.zig:137`<br>`src/sema.zig:2675`<br>`src/sema.zig:2680`<br>`src/sema.zig:2688` |
| `E_ASSIGN_TO_IMMUTABLE_LOCAL` | cannot assign to immutable local binding | `src/mir_verify_util.zig:136`<br>`src/sema.zig:2421`<br>`src/sema.zig:2669`<br>`src/sema.zig:2683`<br>`src/sema.zig:2691` |
| `E_ASYNC_AWAIT_UNRESOLVED` | \`await e\` requires \`e\`'s future type be resolvable without sema — a call \`g(args)\`/\`Owner.m(args)\`, a parenthesized such expr, a struct-FIELD future \`base.fut\`, or an array element \`arr[i]\` (base a param/field of a known struct/array-of-future type); \`*dyn Future\` await and other expression shapes are deferred (Phase E) | `src/async_lower.zig:2376` |
| `E_ASYNC_BORROW_ACROSS_AWAIT` | in async fn '{s}', a reference to a local or parameter (\`&amp;x\`) is captured across an \`await\` — the future is returned by value, so an interior pointer dangles after the move (self-referential futures need pinning, unsupported in async v0). Restructure so no borrow of a captured value crosses the await | `src/async_lower.zig:2622` |
| `E_ASYNC_BRANCH_UNSUPPORTED` | a pre-branch \`let\`/\`var\` live across an await-bearing if/else must have an initializer in async v0<br>a pre-branch \`let\`/\`var\` live across an await-bearing if/else needs an explicit type annotation in async v0<br>a pre-branch \`let\`/\`var\` must bind exactly one name in async v0<br>_+3 more_ | `src/async_lower.zig:577`<br>`src/async_lower.zig:586`<br>`src/async_lower.zig:588`<br>`src/async_lower.zig:640`<br>`src/async_lower.zig:641`<br>`src/async_lower.zig:2437`<br>_+1 more_ |
| `E_ASYNC_FORBIDDEN_CONTEXT` | \`async fn\` is forbidden in a #[{s}] context (it suspends and uses indirect dispatch) | `src/async_lower.zig:482` |
| `E_ASYNC_GENERAL_UNSUPPORTED` | \`{s}\` outside an await-bearing loop in async E3c<br>a \`let\`/\`var\` live across the await regions must bind exactly one name in async E3c<br>a \`let\`/\`var\` live across the await regions needs an explicit type annotation in async E3c<br>_+3 more_ | `src/async_lower.zig:1721`<br>`src/async_lower.zig:1802`<br>`src/async_lower.zig:1805`<br>`src/async_lower.zig:1911`<br>`src/async_lower.zig:2127`<br>`src/async_lower.zig:2165` |
| `E_ASYNC_LOOP_UNSUPPORTED` | a \`while\` loop must have a condition in async v0<br>a pre-loop \`let\`/\`var\` live across the loop needs an explicit type annotation in async v0<br>a pre-loop \`let\`/\`var\` must bind exactly one name in async v0<br>_+5 more_ | `src/async_lower.zig:967`<br>`src/async_lower.zig:969`<br>`src/async_lower.zig:970`<br>`src/async_lower.zig:973`<br>`src/async_lower.zig:978`<br>`src/async_lower.zig:1000`<br>_+2 more_ |
| `E_ATOMIC_OPERATION` | atomic fetch_add/fetch_sub requires an integer payload type<br>unknown atomic operation | `src/mir_verify_util.zig:189`<br>`src/sema.zig:3721`<br>`src/sema.zig:3748` |
| `E_ATOMIC_ORDERING` | atomic load ordering must be .relaxed, .acquire, or .seq_cst<br>atomic read-modify-write ordering must be a valid atomic memory order<br>atomic store ordering must be .relaxed, .release, or .seq_cst | `src/mir_verify_util.zig:191`<br>`src/sema.zig:3794`<br>`src/sema.zig:3798`<br>`src/sema.zig:3804`<br>`src/sema.zig:3808`<br>`src/sema.zig:3814`<br>_+1 more_ |
| `E_AWAIT_OUTSIDE_ASYNC` | \`await\` is only valid inside an \`async fn\` (in '{s}') | `src/async_lower.zig:255` |
| `E_BACKEND_UNSUPPORTED` | C backend does not yet support {s}<br>LLVM backend does not yet support {s}<br>{s} backend does not yet support this construct | `src/lower_c_emitter.zig:3434`<br>`src/lower_c_emitter.zig:3863`<br>`src/lower_llvm.zig:1385`<br>`src/lower_llvm.zig:1392`<br>`src/main.zig:1111` |
| `E_BITCAST_TYPE` | bitcast pointer-reinterpret may not cross into or out of an opaque/secret/userptr class<br>bitcast source must have a fixed scalar, pointer, or address-class layout<br>bitcast source type must be known<br>_+1 more_ | `src/mir_verify_util.zig:194`<br>`src/sema.zig:4107`<br>`src/sema.zig:4117`<br>`src/sema.zig:4120`<br>`src/sema.zig:4135` |
| `E_BITWISE_ARITH_DOMAIN_OPERAND` | bitwise operations are not defined on this arithmetic domain | `src/mir_verify_util.zig:144`<br>`src/sema.zig:2886`<br>`src/sema.zig:2967` |
| `E_BITWISE_BOOL_OPERAND` | bitwise operations are not defined on bool operands | `src/mir_verify_util.zig:155`<br>`src/sema.zig:2877`<br>`src/sema.zig:2961` |
| `E_BITWISE_POINTER_OPERAND` | bitwise operations are not defined on pointer operands | `src/mir_verify_util.zig:156`<br>`src/sema.zig:2880`<br>`src/sema.zig:2964` |
| `E_BITWISE_SIGNED_OPERAND` | bitwise operations are not defined on signed checked integers | `src/mir_verify_util.zig:154`<br>`src/sema.zig:2874`<br>`src/sema.zig:2952` |
| `E_BOOL_OPERATOR_OPERAND` | boolean operators are defined only for bool operands | `src/mir_verify_util.zig:157`<br>`src/sema.zig:2893`<br>`src/sema.zig:2977` |
| `E_BORROW_ESCAPES_SCOPE` | cannot store the address of local storage where it outlives the local's scope (the borrow would dangle) | `src/sema.zig:2730`<br>`src/sema.zig:2733` |
| `E_BREAK_OUTSIDE_LOOP` | break is valid only inside a loop | `src/sema.zig:2469` |
| `E_BYTE_VIEW_ADDRESS` | mem.as_bytes requires an address expression<br>mem.as_bytes requires an addressable value with known storage type<br>mem.as_bytes requires byte-addressable storage | `src/sema.zig:3986`<br>`src/sema.zig:3991`<br>`src/sema.zig:3996`<br>`src/sema.zig:4001` |
| `E_BYTE_VIEW_SLICE` | mem.bytes_equal expects []const u8 byte slices | `src/sema.zig:4012` |
| `E_CALL_ARG_COUNT` | DmaBuf operation does not take arguments<br>MMIO read expects exactly one ordering argument<br>MMIO write expects a value and one ordering argument<br>_+32 more_ | `src/sema.zig:3080`<br>`src/sema.zig:3102`<br>`src/sema.zig:3132`<br>`src/sema.zig:3178`<br>`src/sema.zig:3240`<br>`src/sema.zig:3251`<br>_+34 more_ |
| `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION` | integer-to-closed-enum conversion must use a checked conversion path | `src/mir_verify_util.zig:193`<br>`src/sema.zig:5676` |
| `E_CLOSED_ENUM_SWITCH_EXHAUSTIVE` | switch over closed enum must cover every case or use '_' | `src/mir_verify_util.zig:128`<br>`src/sema.zig:6556` |
| `E_CLOSURE_SIGNATURE_MISMATCH` | bind target does not match the expected closure type<br>closure signature does not match the expected type | `src/sema.zig:5283`<br>`src/sema.zig:5290` |
| `E_COMPTIME_ARG_REQUIRED` | comptime parameter requires a compile-time constant argument | `src/sema.zig:3193` |
| `E_COMPTIME_ERROR` | _see source_ | `src/sema.zig:2199` |
| `E_COMPTIME_FORBIDS_RUNTIME_EFFECT` | comptime code cannot alter runtime control flow<br>comptime code cannot call runtime functions<br>comptime code cannot perform runtime hardware or I/O effects | `src/sema.zig:2408`<br>`src/sema.zig:2446`<br>`src/sema.zig:2466`<br>`src/sema.zig:2478`<br>`src/sema.zig:2520`<br>`src/sema.zig:3046`<br>_+3 more_ |
| `E_COMPTIME_TRAP` | trap during const eval is a compile error | `src/sema.zig:1345`<br>`src/sema.zig:2179`<br>`src/sema.zig:2187`<br>`src/sema.zig:2190`<br>`src/sema.zig:2205`<br>`src/sema.zig:2212`<br>_+2 more_ |
| `E_CONDITION_NOT_BOOL` | condition must be bool | `src/mir_verify_util.zig:91`<br>`src/sema.zig:2327`<br>`src/sema.zig:2509` |
| `E_CONST_GET_BASE` | const_get is defined only for fixed-length arrays | `src/sema.zig:4058`<br>`src/sema.zig:4062` |
| `E_CONST_GET_BOUNDS` | const_get index is out of bounds for the fixed-length array | `src/sema.zig:4067` |
| `E_CONST_GET_INDEX` | const_get requires exactly one compile-time usize index | `src/sema.zig:4054` |
| `E_CONTINUE_OUTSIDE_LOOP` | continue is valid only inside a loop | `src/sema.zig:2481` |
| `E_CONVERSION_OPERATION` | from_mod is defined only on wrap&lt;T&gt; targets<br>residue() is defined only on wrap&lt;T&gt; values<br>try_from/trap_from/wrap_from/sat_from are defined only on scalar integer targets<br>_+1 more_ | `src/mir_verify_util.zig:148`<br>`src/sema.zig:3875`<br>`src/sema.zig:3879`<br>`src/sema.zig:3914`<br>`src/sema.zig:3924` |
| `E_COUNTER_OPERATION` | _see source_ | `src/mir_verify_util.zig:147`<br>`src/sema.zig:3890` |
| `E_C_VOID_CONVERSION` | c_void pointer conversions require an explicit FFI boundary operation | `src/mir_verify_util.zig:87`<br>`src/mir_verify_util.zig:88`<br>`src/mir_verify_util.zig:89`<br>`src/mir_verify_util.zig:90`<br>`src/mir_verify_util.zig:112`<br>`src/sema.zig:2998`<br>_+1 more_ |
| `E_C_VOID_DEREF` | c_void pointer cannot be dereferenced | `src/mir_verify_util.zig:184`<br>`src/sema.zig:3337` |
| `E_C_VOID_NO_LAYOUT` | c_void has no fields in MC<br>c_void has no size or alignment in MC<br>c_void has no size or layout in MC; use pointers to c_void at FFI boundaries | `src/mir_verify_util.zig:185`<br>`src/sema.zig:3358`<br>`src/sema.zig:3469`<br>`src/sema.zig:4829` |
| `E_DECLASSIFY_NOT_SECRET` | declassify/reveal applies only to a Secret&lt;T&gt; value | `src/sema.zig:4177` |
| `E_DEFER_CONTROL_FLOW` | defer is lexical cleanup and must not alter control flow | `src/sema.zig:2494` |
| `E_DMA_ADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:170`<br>`src/sema.zig:7606` |
| `E_DMA_ADDR_NOT_PADDR` | _see source_ | `src/mir_verify_util.zig:178`<br>`src/sema.zig:7591` |
| `E_DMA_ADDR_NOT_VADDR` | _see source_ | `src/mir_verify_util.zig:179`<br>`src/sema.zig:7592` |
| `E_DMA_BUF_MODE` | DmaBuf mode must be .coherent or .noncoherent | `src/sema.zig:3654`<br>`src/sema.zig:3659` |
| `E_DMA_CACHE_MODE` | cache clean/invalidate are required only for noncoherent DmaBuf values | `src/mir_verify_util.zig:195`<br>`src/sema.zig:3837` |
| `E_DMA_OPERATION` | cache DMA operation requires a DmaBuf argument<br>dma_addr/as_slice are defined only on DmaBuf values<br>unknown DmaBuf operation | `src/mir_verify_util.zig:190`<br>`src/sema.zig:3832`<br>`src/sema.zig:3846`<br>`src/sema.zig:3862` |
| `E_DROP_LINEAR_RESOURCE` | a linear \`move\` value cannot be \`drop\`ped (it frees nothing); release it with its free function, \`forget_unchecked\` it in an unsafe block once its contents have been transferred, or mark the type \`#[trivial_drop]\` if completing it needs no release | `src/sema_move.zig:2913` |
| `E_DUPLICATE_BACKEND_NAME` | backend symbol "{s}" is assigned to both \`{s}\` and \`{s}\` | `src/sema.zig:4797` |
| `E_DUPLICATE_DECLARATION` | duplicate trait declaration<br>top-level declarations must have unique names | `src/sema.zig:961`<br>`src/sema.zig:6255` |
| `E_DUPLICATE_ENUM_CASE` | enum case names must be unique | `src/sema.zig:1053` |
| `E_DUPLICATE_ENUM_VALUE` | enum case representation values must be unique | `src/sema.zig:1076` |
| `E_DUPLICATE_LOCAL` | local bindings must have unique names in the current scope | `src/async_lower.zig:1392`<br>`src/sema.zig:2644`<br>`src/sema.zig:6773` |
| `E_DUPLICATE_OVERLAY_FIELD` | overlay union field names must be unique | `src/sema.zig:1296` |
| `E_DUPLICATE_PACKED_BITS_FIELD` | packed bits field names must be unique | `src/sema.zig:1281` |
| `E_DUPLICATE_PARAMETER` | function parameter names must be unique | `src/async_lower.zig:1411`<br>`src/sema.zig:1455` |
| `E_DUPLICATE_STRUCT_FIELD` | struct field names must be unique | `src/sema.zig:1118` |
| `E_DUPLICATE_STRUCT_LITERAL_FIELD` | struct literal field names must be unique | `src/mir_verify_util.zig:103`<br>`src/sema.zig:5136`<br>`src/sema.zig:5188` |
| `E_DUPLICATE_SWITCH_CASE` | switch case pattern is already covered | `src/mir_verify_util.zig:126`<br>`src/mir_verify_util.zig:132`<br>`src/sema.zig:6570`<br>`src/sema.zig:6588`<br>`src/sema.zig:6606`<br>`src/sema.zig:6620`<br>_+4 more_ |
| `E_DUPLICATE_UNION_CASE` | safe tagged union case names must be unique | `src/sema.zig:1258` |
| `E_DYN_FORGE` | a \`*dyn Trait\` cannot be hand-assembled in safe code; build it with \`&amp;x\` / \`&amp;mut x\` (the checked coercion). \`*dyn\` is a compiler-protected type — fabrication requires \`unsafe\` | `src/sema.zig:5418` |
| `E_DYN_MOVE_SELF` | a consuming (\`move self\`/by-value) method cannot be called through \`*dyn Trait\` (you cannot move out of a borrowed trait object) | `src/sema.zig:3127` |
| `E_DYN_MUT_BORROW` | a \`*mut dyn Trait\` requires \`&amp;mut\` of a mutable place<br>a \`*mut dyn Trait\` requires a \`*mut T\` (mutable) source pointer | `src/sema.zig:5376`<br>`src/sema.zig:5407` |
| `E_ENUM_CASE_VALUE_NOT_INTEGER` | enum representation values must be integer literals | `src/sema.zig:1066` |
| `E_ENUM_CASE_VALUE_OUT_OF_RANGE` | enum case value is outside the representation type range | `src/sema.zig:1072` |
| `E_ENUM_LITERAL_REQUIRES_TARGET` | enum literal requires an explicit enum target type | `src/sema.zig:5842` |
| `E_ENUM_REPR_NOT_INTEGER` | enum representation type must be an integer type | `src/sema.zig:1042` |
| `E_EXTERN_STRUCT_BY_VALUE` | C variadic tail arguments must be classified scalar or pointer values<br>explicit C ABI functions cannot pass this unclassified value type by value; use a pointer or mark an MC-only export #[mc_abi]<br>explicit C ABI functions cannot return this unclassified value type by value; use an out pointer or mark an MC-only export #[mc_abi]<br>_+1 more_ | `src/sema.zig:1544`<br>`src/sema.zig:1549`<br>`src/sema.zig:1553`<br>`src/sema.zig:3219` |
| `E_FN_POINTER_SIGNATURE_MISMATCH` | a variadic function cannot be converted to a non-variadic function pointer<br>a variadic function cannot be inferred as a non-variadic function pointer<br>a variadic function cannot be passed as a non-variadic function pointer<br>_+5 more_ | `src/sema.zig:5233`<br>`src/sema.zig:5237`<br>`src/sema.zig:5241`<br>`src/sema.zig:5249`<br>`src/sema.zig:5259`<br>`src/sema.zig:5263`<br>_+4 more_ |
| `E_FOR_BASE_NOT_ARRAY_OR_SLICE` | for loops iterate over arrays and slices | `src/mir_verify_util.zig:84`<br>`src/sema.zig:2329` |
| `E_GENERATED_NAME_COLLISION` | generic specialization would collide with user declaration \`{s}\` | `src/monomorphize.zig:1341` |
| `E_GENERIC_LOOKAHEAD_LIMIT` | generic-call lookahead exceeds {d} tokens | `src/parser.zig:1764` |
| `E_GENERIC_TYPE_ARG_COUNT` | generic type has the wrong number of type arguments | `src/sema.zig:3515`<br>`src/sema.zig:3524` |
| `E_GLOBAL_INITIALIZER_NOT_STATIC` | global initializer must be a compile-time static value for M0 C emission | `src/sema.zig:1349` |
| `E_GLOBAL_REQUIRES_TYPE` | global declarations require an explicit storage type | `src/sema.zig:1027` |
| `E_IF_LET_NARROW_PATTERN` | if let supports only optional bindings and Result ok(...) or err(...) bindings | `src/mir_verify_util.zig:118`<br>`src/sema.zig:6410`<br>`src/sema.zig:6417` |
| `E_IF_LET_OPTIONAL_REQUIRED` | plain if let binding requires a nullable value | `src/mir_verify_util.zig:115`<br>`src/sema.zig:6402` |
| `E_IF_LET_RESULT_REQUIRED` | if let ok(...) or err(...) requires a Result value | `src/mir_verify_util.zig:116`<br>`src/sema.zig:6413` |
| `E_IF_LET_RESULT_TAG` | if let result narrowing supports only ok(...) or err(...) | `src/mir_verify_util.zig:117`<br>`src/sema.zig:6408` |
| `E_ILLEGAL_SLICE_CAST` | cannot cast a non-slice value to a slice: a slice is a fat pointer (ptr+len) and the length has no source. Build one with a slicing expression \`a[i..j]\`, a byte view (\`mem.as_bytes\`), or a string literal | `src/sema.zig:3007` |
| `E_IMPORT_DEPTH_LIMIT` | import depth exceeds configured limit {d} | `src/loader.zig:431`<br>`src/loader.zig:564` |
| `E_IMPORT_EXPANDED_SOURCE_LIMIT` | expanded source exceeds configured limit {d} bytes | `src/loader.zig:576`<br>`src/loader.zig:579`<br>`src/loader.zig:582` |
| `E_IMPORT_FILE_LIMIT` | import graph exceeds configured file limit {d} | `src/loader.zig:435`<br>`src/loader.zig:567` |
| `E_IMPORT_INVALID_STRING` | import path cannot contain NUL<br>import path must be a valid string literal | `src/loader.zig:653`<br>`src/loader.zig:662` |
| `E_IMPORT_NOT_FOUND` | cannot find import "{s}" (resolved candidate: {s}) | `src/loader.zig:452` |
| `E_IMPORT_OUTSIDE_SANDBOX` | import "{s}" resolves to {s}, outside the import sandbox rooted at {s} | `src/loader.zig:421` |
| `E_IMPORT_TOTAL_BYTES_LIMIT` | import graph exceeds configured cumulative input limit {d} bytes | `src/loader.zig:570`<br>`src/loader.zig:573` |
| `E_INDEX_BASE_NOT_ARRAY_OR_SLICE` | indexing is defined only for arrays and slices<br>slicing is defined only for arrays and slices | `src/mir_verify_util.zig:85`<br>`src/sema.zig:3293`<br>`src/sema.zig:3315` |
| `E_INDEX_NOT_USIZE` | array and slice indices must be checked usize<br>slice range bounds must be checked usize | `src/mir_verify_util.zig:86`<br>`src/sema.zig:3302`<br>`src/sema.zig:3319`<br>`src/sema.zig:3323`<br>`src/sema.zig:5813` |
| `E_INTEGER_LITERAL_OUT_OF_RANGE` | integer literal is not representable in its explicit suffix type<br>integer literal is not representable in the annotated type | `src/mir_verify_util.zig:83`<br>`src/sema.zig:4973`<br>`src/sema.zig:4981`<br>`src/sema.zig:4994`<br>`src/sema.zig:4997`<br>`src/sema.zig:5004`<br>_+6 more_ |
| `E_INTERNAL_GENERIC_LINKAGE_COLLISION` | unequal generic instance keys produced the same linkage name \`{s}\` | `src/monomorphize.zig:1352` |
| `E_INTERNAL_OOM` | compiler ran out of memory while building symbol tables; results are incomplete | `src/sema.zig:688` |
| `E_INVALID_ASSIGNMENT_TARGET` | assignment target must be assignable storage | `src/mir_verify_util.zig:138`<br>`src/sema.zig:2516` |
| `E_INVALID_ERROR_FROM` | #[error_from] fn must convert one named error type to another (fn(E1) -&gt; E2)<br>#[error_from] fn must take exactly one parameter (the source error type) | `src/sema.zig:2775`<br>`src/sema.zig:2781` |
| `E_INVALID_TRAP_KIND` | trap expects exactly one language TrapKind<br>trap kind must be a language TrapKind enum literal<br>unknown language TrapKind | `src/sema.zig:4808`<br>`src/sema.zig:4814`<br>`src/sema.zig:4819` |
| `E_IRQ_CONTEXT_BLOCKING` | _see source_ | `src/mir_verify_util.zig:47` |
| `E_IRQ_CONTEXT_CALL` | an #[irq_context] function may not dispatch through \`*dyn Trait\` (a virtual call is an indirect call whose target may sleep or block)<br>an #[irq_context] function may not make an indirect/closure call (the target may sleep or block)<br>an #[irq_context] function may not make an indirect/fn-pointer call (the target may sleep or block)<br>_+1 more_ | `src/mir_verify_util.zig:46`<br>`src/sema.zig:3090`<br>`src/sema.zig:3105`<br>`src/sema.zig:3135`<br>`src/sema.zig:3170` |
| `E_LEX_INVALID_CHAR_LITERAL` | invalid char literal | `src/lexer.zig:264` |
| `E_LEX_INVALID_ESCAPE_SEQUENCE` | invalid escape sequence | `src/lexer.zig:281` |
| `E_LEX_INVALID_FLOAT_LITERAL` | invalid float literal | `src/lexer.zig:214` |
| `E_LEX_INVALID_INTEGER_LITERAL` | invalid integer literal | `src/lexer.zig:216` |
| `E_LEX_UNEXPECTED_BYTE` | unexpected byte '{c}' | `src/lexer.zig:65` |
| `E_LEX_UNTERMINATED_BLOCK_COMMENT` | unterminated block comment | `src/lexer.zig:94` |
| `E_LEX_UNTERMINATED_CHAR_LITERAL` | unterminated char literal | `src/lexer.zig:247`<br>`src/lexer.zig:260` |
| `E_LEX_UNTERMINATED_ESCAPE_SEQUENCE` | unterminated escape sequence | `src/lexer.zig:270` |
| `E_LEX_UNTERMINATED_STRING_LITERAL` | unterminated string literal | `src/lexer.zig:225`<br>`src/lexer.zig:236` |
| `E_LITERAL_REQUIRES_TARGET` | literal requires an explicit target type | `src/sema.zig:5846` |
| `E_LOCAL_ADDRESS_ESCAPE` | cannot return a closure that captures local storage (the environment would dangle)<br>cannot return the address of local storage<br>cannot return the address of local storage inside an aggregate (the borrow would dangle)<br>_+2 more_ | `src/mir_verify_util.zig:196`<br>`src/sema.zig:2738`<br>`src/sema.zig:2742`<br>`src/sema.zig:5468`<br>`src/sema.zig:5473`<br>`src/sema.zig:5569`<br>_+1 more_ |
| `E_LOCAL_REQUIRES_INITIALIZER` | ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage | `src/sema.zig:2592` |
| `E_MC_VOID_POINTER_FFI` | use c_void for C opaque object pointers, not MC void | `src/sema.zig:3467` |
| `E_MIR_CFG` | MIR verifier found malformed control-flow graph | `src/mir.zig:9686` |
| `E_MMIO_ACCESS_FORBIDDEN` | MIR verifier found MMIO register access disallowed by Reg/RegBits mode<br>MMIO register access mode does not allow read<br>MMIO register access mode does not allow write | `src/mir.zig:986`<br>`src/sema.zig:3693`<br>`src/sema.zig:3703` |
| `E_MMIO_ACCESS_MODE` | MMIO register access mode must be .read, .write, or .read_write | `src/sema.zig:3673`<br>`src/sema.zig:3678` |
| `E_MMIO_DIRECT_ASSIGN` | MIR verifier found direct assignment to an MMIO register<br>MMIO registers must be accessed through typed read/write methods | `src/mir.zig:980`<br>`src/sema.zig:2522` |
| `E_MMIO_ORDERING` | MMIO read ordering must be .relaxed or .acquire<br>MMIO write ordering must be .relaxed or .release | `src/mir_verify_util.zig:192`<br>`src/sema.zig:4190`<br>`src/sema.zig:4194`<br>`src/sema.zig:4200`<br>`src/sema.zig:4204` |
| `E_MMIO_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:172`<br>`src/sema.zig:7608` |
| `E_MMIO_PTR_TARGET` | MmioPtr target must be an extern mmio struct type | `src/sema.zig:3626`<br>`src/sema.zig:3631` |
| `E_MMIO_REGBITS_TYPE` | RegBits value type must be a known packed bits type | `src/sema.zig:3598` |
| `E_MMIO_REGISTER_POSITION` | Reg and RegBits types are valid only as extern mmio struct fields | `src/sema.zig:3620` |
| `E_MMIO_REGISTER_WIDTH` | MMIO register width must be u8, u16, u32, or u64 | `src/sema.zig:3665` |
| `E_MONOMORPHIZATION_LIMIT` | _see source_ | `src/monomorphize.zig:1096` |
| `E_MOVE_ARRAY_UNSUPPORTED` | a non-\`move\` struct cannot store an array of linear \`move\` values by value; make the struct \`move\`, or hold the resources behind pointers<br>cannot assign a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to update<br>cannot defer a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to reserve<br>_+4 more_ | `src/sema.zig:1024`<br>`src/sema.zig:1113`<br>`src/sema.zig:1448`<br>`src/sema.zig:1473`<br>`src/sema_move.zig:1043`<br>`src/sema_move.zig:2860`<br>_+2 more_ |
| `E_MOVE_BRANCH_MISMATCH` | linear \`move\` field has inconsistent ownership across control-flow branches<br>linear \`move\` value has inconsistent ownership across control-flow branches | `src/sema_move.zig:1537`<br>`src/sema_move.zig:1546`<br>`src/sema_move.zig:1565`<br>`src/sema_move.zig:3172`<br>`src/sema_move.zig:3188` |
| `E_MOVE_FIELD_IN_NONMOVE` | a linear \`move\` value cannot be stored by value in a non-\`move\` struct (it would be duplicated or leaked); make the struct \`move\`, or store the resource behind a pointer | `src/sema.zig:1115` |
| `E_MOVE_LOOP_RESOURCE` | cannot consume or reserve an outer linear \`move\` value inside a loop; the loop may run zero or multiple times<br>cannot move an outer linear \`move\` place inside a loop; the loop may run zero or multiple times | `src/sema_move.zig:747`<br>`src/sema_move.zig:762`<br>`src/sema_move.zig:1664` |
| `E_NAKED_BODY` | a #[naked] function body must be exactly one \`asm\` block (optionally wrapped in one \`unsafe {}\`); there is no frame for locals, statements, or expressions | `src/sema.zig:1490` |
| `E_NAKED_RETURN` | a #[naked] function must return \`never\` or \`void\`; it cannot synthesize a value return (the asm body owns the calling convention) | `src/sema.zig:1485` |
| `E_NESTING_TOO_DEEP` | nesting too deep | `src/parser.zig:2190` |
| `E_NEVER_FALLTHROUGH` | function declared -&gt; never can fall off the end | `src/hir.zig:177`<br>`src/mir.zig:904`<br>`src/sema.zig:1532` |
| `E_NEVER_RETURNS` | function declared -&gt; never cannot return normally | `src/sema.zig:2452`<br>`src/sema.zig:2459` |
| `E_NEVER_STORAGE` | never is a control-flow type and cannot be used for storage | `src/sema.zig:3473`<br>`src/sema.zig:3641` |
| `E_NO_ERROR_CONVERSION` | '?' cannot convert the propagated error to the function's error type; declare an #[error_from] fn converting it | `src/sema.zig:2811` |
| `E_NO_IMPLICIT_CONVERSION` | MaybeUninit.write payload must match the storage type<br>Secret&lt;T&gt; can only wrap a value of its underlying type T<br>annotated local initializer requires an explicit conversion<br>_+9 more_ | `src/mir_verify_util.zig:98`<br>`src/mir_verify_util.zig:106`<br>`src/mir_verify_util.zig:131`<br>`src/mir_verify_util.zig:160`<br>`src/sema.zig:1322`<br>`src/sema.zig:1323`<br>_+39 more_ |
| `E_NO_IMPLICIT_INTEGER_PROMOTION` | integer arithmetic requires matching types or an explicit conversion | `src/mir_verify_util.zig:159`<br>`src/sema.zig:5891` |
| `E_NO_IMPLICIT_POINTER_CONVERSION` | pointer and view conversions must be explicit<br>pointer comparisons require compatible pointer or view operands | `src/mir_verify_util.zig:78`<br>`src/mir_verify_util.zig:79`<br>`src/mir_verify_util.zig:92`<br>`src/mir_verify_util.zig:93`<br>`src/mir_verify_util.zig:94`<br>`src/mir_verify_util.zig:95`<br>_+6 more_ |
| `E_NO_LANG_TRAP_EDGE` | HIR verifier found language trap edge {s} before C emission<br>MIR verifier found language trap edge {s}<br>assert may emit a language trap in #[no_lang_trap]<br>_+9 more_ | `src/hir.zig:191`<br>`src/mir.zig:913`<br>`src/sema.zig:2505`<br>`src/sema.zig:2838`<br>`src/sema.zig:2848`<br>`src/sema.zig:2865`<br>_+7 more_ |
| `E_NULLABLE_DYN_DISPATCH` | cannot dispatch a method through a \`?*dyn Trait\` (it may be absent / \`none\`); narrow it first with \`if let\` / \`switch\`, or \`unwrap\` it to a \`*dyn Trait\` | `src/sema.zig:3116` |
| `E_NULLABLE_DYN_NARROW` | a \`?*dyn Trait\` cannot coerce to a non-null \`*dyn Trait\`: it may be \`none\`. Narrow it with \`if let\` / \`switch\`, or \`unwrap\` it first | `src/sema.zig:5365` |
| `E_NULL_NON_NULL_POINTER` | null cannot initialize a non-null pointer | `src/mir_verify_util.zig:77`<br>`src/sema.zig:5037` |
| `E_NULL_REQUIRES_TARGET` | null requires an explicit nullable pointer target type | `src/sema.zig:1310`<br>`src/sema.zig:2553` |
| `E_OPAQUE_DECLASSIFY` | casting an \`opaque struct\` value to another type declassifies its private fields; use an accessor in its \`impl\`, or \`unsafe\` | `src/sema.zig:5782` |
| `E_OPERATOR_OPERAND` | arithmetic operators require integer or arithmetic-domain operands<br>bitwise operators require unsigned integer or wrapping operands<br>equality operators require comparable operands<br>_+3 more_ | `src/mir_verify_util.zig:163`<br>`src/mir_verify_util.zig:197`<br>`src/sema.zig:2915`<br>`src/sema.zig:5897`<br>`src/sema.zig:5901`<br>`src/sema.zig:5908`<br>_+9 more_ |
| `E_ORDERED_ARITH_DOMAIN_OPERAND` | ordered comparisons are not defined on wrap, serial, or counter arithmetic domains | `src/mir_verify_util.zig:145`<br>`src/sema.zig:5997` |
| `E_ORPHAN_IMPL` | impl of an opaque type must be in its defining module (file); a peer impl in another file cannot reach its private fields<br>trait impl for a type must be in the file that declares the type | `src/sema.zig:6216`<br>`src/sema.zig:6232` |
| `E_PACKED_BITS_FIELD_NOT_BOOL` | packed bits fields must be bool | `src/sema.zig:1278` |
| `E_PACKED_BITS_REPR_NOT_INTEGER` | packed bits representation type must be an integer type | `src/sema.zig:1270` |
| `E_PADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:168`<br>`src/sema.zig:7604` |
| `E_PARSE` | _see source_ | `src/parser.zig:2168` |
| `E_PARSE_EXPECTED_EXPRESSION` | _see source_ | `src/parser.zig:2166` |
| `E_PARSE_EXPECTED_PARAMETER_NAME` | _see source_ | `src/parser.zig:2167` |
| `E_PARSE_FAILED` | _see source_ | `src/main.zig:526` |
| `E_PHYS_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:173`<br>`src/sema.zig:7609` |
| `E_POINTER_ARITH_SINGLE_OBJECT` | single-object pointers do not support arithmetic | `src/mir_verify_util.zig:161`<br>`src/sema.zig:2944` |
| `E_POINTER_ORDERING` | optional values support only equality comparisons against null<br>pointer and view values support only equality comparisons | `src/mir_verify_util.zig:162`<br>`src/sema.zig:6028`<br>`src/sema.zig:6044` |
| `E_PRECISE_ASM_CONTRACT` | precise asm requires #[unsafe_contract(precise_asm)] | `src/sema.zig:2411` |
| `E_PRIVATE_FIELD` | cannot construct an \`opaque struct\` outside its associated functions (\`impl\` block); its fields are private<br>field of an \`opaque struct\` is private to its associated functions (\`impl\` block) | `src/sema.zig:5113`<br>`src/sema.zig:6074` |
| `E_PRIVATE_IMPORT` | this name is private under the active visibility mode; only \`pub\`/\`export\` items are visible to importing files | `src/sema.zig:6162` |
| `E_RAW_AGGREGATE_UNSUPPORTED` | raw.load/raw.store currently require a scalar payload; aggregate raw access has no defined single-access volatile contract | `src/sema.zig:5275` |
| `E_REDUCE_ARG_NOT_SLICE` | reduction expects a slice (\`[]const T\`) of the element type<br>reduction slice element type must match the reduction type argument | `src/sema.zig:3959`<br>`src/sema.zig:3966` |
| `E_REDUCE_REQUIRES_FLOAT` | floating-point reductions are restricted to f32/f64 | `src/sema.zig:3936`<br>`src/sema.zig:3941`<br>`src/sema.zig:3948` |
| `E_REDUCE_REQUIRES_INTEGER` | reduce.sum_checked is restricted to integer types | `src/sema.zig:3936`<br>`src/sema.zig:3941`<br>`src/sema.zig:3945` |
| `E_REFLECTION_FIELD_LITERAL` | field reflection requires an enum-literal field name | `src/sema.zig:4840` |
| `E_REFLECTION_GENERIC_ARG_COUNT` | reflection generic type has the wrong number of type arguments | `src/sema.zig:4883` |
| `E_REFLECTION_TYPE_ARG` | reflection type argument must be a type name | `src/sema.zig:4872` |
| `E_REFLECTION_TYPE_VALUE` | field_type produces a type and is valid only in type position | `src/sema.zig:4853` |
| `E_REFLECTION_UNKNOWN_TYPE` | field reflection requires a known field-bearing layout type<br>reflection layout could not be computed for this type<br>reflection requires a known layout-capable type | `src/sema.zig:4887`<br>`src/sema.zig:4908`<br>`src/sema.zig:4938`<br>`src/sema.zig:4947`<br>`src/sema.zig:4951`<br>`src/sema.zig:4962` |
| `E_REPRESENTATION_CHECK_MISSING` | MIR verifier found representation-sensitive value use without dominating check | `src/mir.zig:994`<br>`src/mir.zig:1001` |
| `E_RESERVED_C_IDENTIFIER` | identifier is reserved by the C backend or C headers; choose a different source name<br>local binding name is reserved by the C backend or C headers; choose a different source name<br>parameter name is reserved by the C backend or C headers; choose a different source name | `src/sema.zig:968`<br>`src/sema.zig:1451`<br>`src/sema.zig:2633` |
| `E_RESERVED_QUALIFIED_NAME` | a local binding may not shadow a module/impl name<br>a parameter may not shadow a module/impl name<br>a top-level value may not shadow a module/impl name | `src/sema.zig:975`<br>`src/sema.zig:1453`<br>`src/sema.zig:2637` |
| `E_RESOURCE_LEAK` | linear \`move\` value bound in a switch arm is never consumed (must be moved, returned, or freed)<br>linear \`move\` value bound in an if-let branch is never consumed (must be moved, returned, or freed)<br>linear \`move\` value created in only one branch is never consumed before the branch exits<br>_+2 more_ | `src/sema_move.zig:700`<br>`src/sema_move.zig:730`<br>`src/sema_move.zig:1185`<br>`src/sema_move.zig:1258`<br>`src/sema_move.zig:1317`<br>`src/sema_move.zig:1352`<br>_+3 more_ |
| `E_RESOURCE_OVERWRITE` | cannot assign a linear \`move\` array element through an unknown dynamic index; the selected live element must be consumed first<br>cannot overwrite a live linear \`move\` array element; consume it first<br>cannot overwrite a live linear \`move\` field; consume it first<br>_+1 more_ | `src/sema_move.zig:957`<br>`src/sema_move.zig:1012`<br>`src/sema_move.zig:1029`<br>`src/sema_move.zig:1038` |
| `E_RETURN_MISSING` | function return type requires all paths to return a value | `src/hir.zig:177`<br>`src/mir.zig:904`<br>`src/sema.zig:1534` |
| `E_RETURN_REQUIRES_VALUE` | function return type requires a value | `src/sema.zig:2461` |
| `E_RETURN_TYPE_MISMATCH` | return expression must match the declared return type | `src/mir_verify_util.zig:96`<br>`src/mir_verify_util.zig:114`<br>`src/sema.zig:5451`<br>`src/sema.zig:5452`<br>`src/sema.zig:5453`<br>`src/sema.zig:5475`<br>_+3 more_ |
| `E_SECRET_BRANCH` | secret value cannot drive a branch or switch; this would leak it through control-flow timing — use declassify/reveal (unsafe) or a constant-time select<br>secret value cannot drive a loop condition; this would leak it through control-flow timing | `src/sema.zig:2325`<br>`src/sema.zig:6497` |
| `E_SECRET_DECLASSIFY` | casting a Secret&lt;T&gt; to a non-secret type declassifies it; use reveal/declassify inside unsafe | `src/sema.zig:5699` |
| `E_SECRET_INDEX` | secret value cannot be used as an array index; a secret-dependent memory access leaks it through the cache — declassify/reveal it first (unsafe) or use a constant-time table scan<br>secret value cannot offset a pointer; a secret-dependent memory access leaks it through the cache | `src/sema.zig:2949`<br>`src/sema.zig:3300` |
| `E_SERIAL_OPERATION` | _see source_ | `src/mir_verify_util.zig:146`<br>`src/sema.zig:3890` |
| `E_SIGNED_UNSIGNED_MIX` | signed and unsigned integers do not implicitly mix | `src/mir_verify_util.zig:158`<br>`src/sema.zig:5888` |
| `E_SLEEP_IN_ATOMIC` | calling a #[may_sleep] op from an #[irq_context] function (sleeping in interrupt) | `src/sema.zig:3168` |
| `E_STRUCT_LITERAL_MISSING_FIELD` | packed bits literal must initialize every field<br>struct literal must initialize every field | `src/mir_verify_util.zig:105`<br>`src/sema.zig:5173`<br>`src/sema.zig:5211` |
| `E_STRUCT_LITERAL_REQUIRES_TARGET` | struct literal requires an explicit struct target type | `src/sema.zig:2566` |
| `E_SWITCH_MULTI_BINDING_ARM` | switch arms with multiple patterns cannot introduce bindings | `src/mir_verify_util.zig:121`<br>`src/sema.zig:6714` |
| `E_SWITCH_RESULT_REQUIRED` | switch ok or err patterns require a Result value<br>switch ok(...) or err(...) binding requires a Result value | `src/mir_verify_util.zig:120`<br>`src/sema.zig:6689`<br>`src/sema.zig:6703` |
| `E_SWITCH_RESULT_TAG` | switch result binding supports only ok(...) or err(...)<br>switch result patterns support only ok or err tags | `src/mir_verify_util.zig:119`<br>`src/sema.zig:6687`<br>`src/sema.zig:6701` |
| `E_SYMBOLS_INTERNAL` | _see source_ | `src/main.zig:530` |
| `E_TRAIT_BOUND_MEMBER` | generic type-parameter member calls require a \`where\` bound whose trait declares that member | `src/sema.zig:3449` |
| `E_TRAIT_EFFECT_MISMATCH` | impl method's effect annotations (#[may_sleep]) do not match the trait signature | `src/sema.zig:6351` |
| `E_TRAIT_INCOHERENT` | duplicate \`impl Trait for Type\` (coherence: at most one impl per (Trait, Type) pair) | `src/sema.zig:6299` |
| `E_TRAIT_MISSING_METHOD` | impl does not provide a trait method | `src/sema.zig:6332` |
| `E_TRAIT_NOT_OBJECT_SAFE` | trait is not object-safe (every method must take \`self\` by pointer and be non-generic) so it cannot be used as \`*dyn Trait\` | `src/sema.zig:3564` |
| `E_TRAIT_NOT_SATISFIED` | a \`*dyn Trait\` can only be formed from a concrete nominal type that implements the trait<br>no \`impl Trait for Type\` for this concrete type, so it cannot coerce to \`*dyn Trait\` | `src/monomorphize.zig:1001`<br>`src/sema.zig:5381`<br>`src/sema.zig:5385`<br>`src/sema.zig:5411` |
| `E_TRAIT_SELF_MODE_MISMATCH` | impl method's self-mode does not match the trait signature | `src/sema.zig:6336` |
| `E_TRAIT_SIGNATURE_MISMATCH` | impl method's parameter count does not match the trait signature<br>impl method's parameter type does not match the trait signature<br>impl method's return type does not match the trait signature | `src/sema.zig:6377`<br>`src/sema.zig:6384`<br>`src/sema.zig:6394` |
| `E_TRAIT_UNKNOWN_METHOD` | impl provides a method the trait does not declare | `src/sema.zig:6357` |
| `E_TRIVIAL_DROP_NOT_MOVE` | #[trivial_drop] applies only to a \`move struct\` (it asserts the resource's completion needs no release) | `src/sema.zig:592` |
| `E_TRY_REQUIRES_RESULT_OR_NULLABLE` | postfix '?' requires a Result or nullable operand | `src/mir_verify_util.zig:111`<br>`src/sema.zig:2852` |
| `E_TYPE_ALIAS_CYCLE` | type aliases must not form recursive cycles | `src/sema.zig:724` |
| `E_TYPE_ARG_REQUIRED` | type parameter requires a known type argument<br>type parameter requires a type argument | `src/sema.zig:3188`<br>`src/sema.zig:3190` |
| `E_UNBOUNDED_INDIRECT_CALL` | a \`#[bounded]\` function may not dispatch through \`*dyn Trait\` (the callee's termination cannot be checked through the vtable)<br>a \`#[bounded]\` function may not make an indirect/closure call (the callee's termination cannot be checked through the closure)<br>a \`#[bounded]\` function may not make an indirect/fn-pointer call (the callee's termination cannot be checked through the pointer) | `src/sema.zig:3096`<br>`src/sema.zig:3108`<br>`src/sema.zig:3138` |
| `E_UNBOUNDED_LOOP` | loop in a bounded/IRQ-context function is not statically bounded (no monotone counter toward a bound, fixed-range for, or break) | `src/sema.zig:4291` |
| `E_UNBOUNDED_RECURSION` | direct recursion from a bounded/IRQ-context function (a kernel must not recurse unboundedly in interrupt/atomic context)<br>recursive direct-call cycle among bounded/IRQ-context functions (no decreasing metric is proven) | `src/sema.zig:4330`<br>`src/sema.zig:4426` |
| `E_UNCHECKED_OUTSIDE_CONTRACT` | MIR verifier found unchecked optimizer assumption outside matching contract region<br>unchecked operation requires matching #[unsafe_contract] | `src/mir.zig:924`<br>`src/sema.zig:3032` |
| `E_UNHANDLED_RESULT` | Result defer cleanup must be handled or propagated<br>Result expression statements must be handled or propagated<br>Result local must be handled before reassignment<br>_+2 more_ | `src/mir_verify_util.zig:110`<br>`src/sema.zig:2290`<br>`src/sema.zig:2305`<br>`src/sema.zig:2308`<br>`src/sema.zig:2491`<br>`src/sema.zig:2500` |
| `E_UNINIT_REQUIRES_STORAGE` | uninit is valid only for explicit typed mutable storage initialization | `src/sema.zig:1317`<br>`src/sema.zig:2547`<br>`src/sema.zig:2702`<br>`src/sema.zig:5445`<br>`src/sema.zig:5506` |
| `E_UNION_CASE_HAS_NO_PAYLOAD` | union case binding requires a payload case<br>union case has no payload type | `src/mir_verify_util.zig:130`<br>`src/sema.zig:4959`<br>`src/sema.zig:6698` |
| `E_UNKNOWN_ENUM_CASE` | enum has no case with this name | `src/mir_verify_util.zig:127`<br>`src/sema.zig:5653`<br>`src/sema.zig:6680` |
| `E_UNKNOWN_FUNCTION` | unknown function | `src/sema.zig:3417` |
| `E_UNKNOWN_IDENTIFIER` | asm output names an unknown local<br>unknown identifier<br>unknown identifier \`{s}\` | `src/diagnostics.zig:437`<br>`src/diagnostics.zig:445`<br>`src/diagnostics.zig:489`<br>`src/sema.zig:2424`<br>`src/sema.zig:3401` |
| `E_UNKNOWN_LOOP_LABEL` | break targets a loop label that is not in scope<br>continue targets a loop label that is not in scope | `src/sema.zig:2472`<br>`src/sema.zig:2484` |
| `E_UNKNOWN_STRUCT_FIELD` | layout type has no field with this name<br>member access requires a struct, packed-bits, or overlay-union value<br>packed bits type has no field with this name<br>_+1 more_ | `src/mir_verify_util.zig:104`<br>`src/sema.zig:4943`<br>`src/sema.zig:4955`<br>`src/sema.zig:5143`<br>`src/sema.zig:5195`<br>`src/sema.zig:6081`<br>_+1 more_ |
| `E_UNKNOWN_TRAIT` | unknown trait in \`*dyn Trait\`<br>unknown trait in impl | `src/sema.zig:3560`<br>`src/sema.zig:6324` |
| `E_UNKNOWN_TYPE` | enum literals are values, not runtime types<br>type members are not supported; this member does not resolve to a declared type<br>unknown generic type name<br>_+1 more_ | `src/sema.zig:3475`<br>`src/sema.zig:3481`<br>`src/sema.zig:3483`<br>`src/sema.zig:3521` |
| `E_UNKNOWN_UNION_CASE` | union has no case with this name | `src/mir_verify_util.zig:129`<br>`src/sema.zig:5591`<br>`src/sema.zig:5629`<br>`src/sema.zig:6684`<br>`src/sema.zig:6696` |
| `E_UNSAFE_REQUIRED` | MIR verifier found unsafe machine effect outside unsafe context<br>arc_get_mut yields an aliasable \`*mut T\` whose uniqueness the checker cannot enforce; it requires an unsafe context (do not arc_clone/publish the handle while the pointer lives)<br>declassify/reveal escapes the constant-time discipline and requires unsafe<br>_+2 more_ | `src/mir.zig:931`<br>`src/sema.zig:2405`<br>`src/sema.zig:3036`<br>`src/sema.zig:3043`<br>`src/sema.zig:3258`<br>`src/sema.zig:3334`<br>_+2 more_ |
| `E_UNSIGNED_NEGATION` | unsigned checked integers do not support unary '-' | `src/mir_verify_util.zig:153`<br>`src/sema.zig:2868` |
| `E_UNUSED_MOVE_RESULT` | the linear \`move\` result of this expression is discarded; bind it with \`let\`, return it, or pass it to a consuming function | `src/sema_move.zig:805` |
| `E_USERPTR_CAST_DEREF` | casting a UserPtr&lt;T&gt; to a derefable kernel pointer bypasses uaccess validation; only UserPtr&lt;-&gt;usize is permitted | `src/sema.zig:5706` |
| `E_USER_PTR_DEREF` | cannot directly access a field through UserPtr; copy it in with copy_from_user first | `src/mir_verify_util.zig:171`<br>`src/sema.zig:3364`<br>`src/sema.zig:7607` |
| `E_USE_AFTER_MOVE` | borrow of linear \`move\` array element after it was moved out<br>borrow of linear \`move\` field after it was moved out<br>borrow of linear \`move\` place after one of its child places was moved out<br>_+28 more_ | `src/sema_move.zig:959`<br>`src/sema_move.zig:1010`<br>`src/sema_move.zig:1027`<br>`src/sema_move.zig:1036`<br>`src/sema_move.zig:2808`<br>`src/sema_move.zig:2823`<br>_+42 more_ |
| `E_USE_BEFORE_INIT` | variable initialized with \`uninit\` is read before it is definitely initialized on all paths | `src/sema.zig:1914` |
| `E_VADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:169`<br>`src/sema.zig:7605` |
| `E_VA_START_CONTEXT` | va.start is only valid inside a variadic function | `src/sema.zig:4025` |
| `E_VOID_RETURNS_VALUE` | function declared -&gt; void cannot return a value | `src/sema.zig:2454` |
| `E_VOID_STORAGE` | void is only valid as a function return type or generic marker | `src/sema.zig:3471`<br>`src/sema.zig:3639` |
