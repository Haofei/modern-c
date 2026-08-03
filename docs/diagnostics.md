# MC compiler diagnostics

This file is generated from `E_*` diagnostic codes emitted by production Zig sources under `src/`.
Regenerate it with:

```sh
python3 tools/toolchain/diagnostics-reference.py --write
```

Total codes: **277**.

| Code | Message examples | Source references |
|---|---|---|
| `E_ADDRESS_CLASS_CAST` | bitcast may not mint, cross, or strip a built-in address class (PAddr/VAddr/DmaAddr/MmioPtr/...); use the typed constructor or \`unsafe\`<br>casting to a built-in address class forges it from a non-address value; use the typed constructor (pa/va/dma/mmio.map) or \`unsafe\` | `src/sema.zig:5226`<br>`src/sema.zig:7158` |
| `E_ADDRESS_CLASS_MISMATCH` | mmio.map requires a PAddr argument | `src/mir_verify_util.zig:180`<br>`src/sema.zig:5152`<br>`src/sema.zig:9393` |
| `E_ADDRESS_CLASS_OPERATION` | MIR verifier found illegal operation on opaque address class<br>opaque address classes do not support this operator | `src/mir.zig:1067`<br>`src/sema.zig:3801`<br>`src/sema.zig:3839` |
| `E_ADDRESS_RESOURCE_PAYLOAD` | external address and DMA payloads cannot store \`move\`/\`linear\`, \`region\`, or \`view struct\` resources by payload type; pass a copyable descriptor or explicit owner token instead | `src/sema.zig:4626` |
| `E_AMBIGUOUS_ERROR_CONVERSION` | multiple #[error_from] conversions for the same source and target error types; keep exactly one | `src/sema.zig:3693` |
| `E_ARITH_DOMAIN_DIVISION` | division and remainder are defined only on checked integers, not arithmetic domains | `src/mir_verify_util.zig:143`<br>`src/sema.zig:3836` |
| `E_ARITH_DOMAIN_UNSIGNED` | MC-C0 arithmetic domains require an unsigned integer type argument | `src/sema.zig:4494` |
| `E_ARITH_POLICY_MIX` | arithmetic domains do not implicitly mix | `src/mir_verify_util.zig:142`<br>`src/mir_verify_util.zig:149`<br>`src/sema.zig:3824` |
| `E_ARRAY_LENGTH_TYPE` | array length must be a compile-time checked usize integer expression | `src/sema.zig:4470` |
| `E_ARRAY_LITERAL_LENGTH` | array literal element count must match the target array length<br>array literal target must have a known constant length | `src/mir_verify_util.zig:102`<br>`src/sema.zig:6231`<br>`src/sema.zig:6235` |
| `E_ARRAY_LITERAL_REQUIRES_TARGET` | array literal requires an explicit array target type | `src/sema.zig:3437` |
| `E_ARRAY_TO_POINTER_DECAY` | arrays do not implicitly decay to pointers | `src/mir_verify_util.zig:97`<br>`src/sema.zig:6207` |
| `E_ASM_ARCH_MIXED` | inline-asm block mixes registers from more than one architecture | `src/sema.zig:5876` |
| `E_ASM_CLOBBER_CONFLICT` | inline-asm clobbers a register it also binds to an operand | `src/sema.zig:5914` |
| `E_ASM_REGISTER_CONFLICT` | inline-asm binds the same register to more than one operand | `src/sema.zig:5892`<br>`src/sema.zig:5902` |
| `E_ASM_UNKNOWN_REGISTER` | inline-asm names a register that is not valid on any supported architecture | `src/sema.zig:5869` |
| `E_ASSIGN_THROUGH_CONST_VIEW` | cannot assign through a const pointer or view | `src/mir_verify_util.zig:137`<br>`src/sema.zig:3556`<br>`src/sema.zig:3561`<br>`src/sema.zig:3569` |
| `E_ASSIGN_TO_IMMUTABLE_LOCAL` | cannot assign to immutable local binding | `src/mir_verify_util.zig:136`<br>`src/sema.zig:3285`<br>`src/sema.zig:3550`<br>`src/sema.zig:3564`<br>`src/sema.zig:3572` |
| `E_ASYNC_AWAIT_UNRESOLVED` | \`await e\` requires \`e\`'s future type be resolvable without sema — a call \`g(args)\`/\`Owner.m(args)\`, a parenthesized such expr, a struct-FIELD future \`base.fut\`, or an array element \`arr[i]\` (base a param/field of a known struct/array-of-future type); \`*dyn Future\` await and other expression shapes are deferred (Phase E) | `src/async_lower.zig:2385` |
| `E_ASYNC_BORROW_ACROSS_AWAIT` | explicit \`borrow\` / \`borrow mut\` cannot be captured by an awaited future in async v0; end the borrow before \`await\`, move owned state into the future, or rebuild the view after the await<br>explicit \`borrow\` / \`borrow mut\` cannot be formed in the same async statement that awaits; split the borrow into a post-await lexical scope<br>explicit \`borrow\` / \`borrow mut\` local in async fn '{s}' cannot live across an \`await\`; end the borrow with a smaller lexical block before awaiting<br>_+1 more_ | `src/async_lower.zig:2400`<br>`src/async_lower.zig:2634`<br>`src/async_lower.zig:2647`<br>`src/async_lower.zig:2650` |
| `E_ASYNC_BRANCH_UNSUPPORTED` | a pre-branch \`let\`/\`var\` live across an await-bearing if/else must have an initializer in async v0<br>a pre-branch \`let\`/\`var\` live across an await-bearing if/else needs an explicit type annotation in async v0<br>a pre-branch \`let\`/\`var\` must bind exactly one name in async v0<br>_+3 more_ | `src/async_lower.zig:589`<br>`src/async_lower.zig:598`<br>`src/async_lower.zig:600`<br>`src/async_lower.zig:652`<br>`src/async_lower.zig:653`<br>`src/async_lower.zig:2449`<br>_+1 more_ |
| `E_ASYNC_FORBIDDEN_CONTEXT` | \`async fn\` is forbidden in a #[{s}] context (it suspends and uses indirect dispatch) | `src/async_lower.zig:492` |
| `E_ASYNC_GENERAL_UNSUPPORTED` | \`{s}\` outside an await-bearing loop in async E3c<br>a \`let\`/\`var\` live across the await regions must bind exactly one name in async E3c<br>a \`let\`/\`var\` live across the await regions needs an explicit type annotation in async E3c<br>_+3 more_ | `src/async_lower.zig:1731`<br>`src/async_lower.zig:1812`<br>`src/async_lower.zig:1815`<br>`src/async_lower.zig:1921`<br>`src/async_lower.zig:2136`<br>`src/async_lower.zig:2174` |
| `E_ASYNC_LOOP_UNSUPPORTED` | a \`while\` loop must have a condition in async v0<br>a pre-loop \`let\`/\`var\` live across the loop needs an explicit type annotation in async v0<br>a pre-loop \`let\`/\`var\` must bind exactly one name in async v0<br>_+5 more_ | `src/async_lower.zig:976`<br>`src/async_lower.zig:978`<br>`src/async_lower.zig:979`<br>`src/async_lower.zig:982`<br>`src/async_lower.zig:987`<br>`src/async_lower.zig:1009`<br>_+2 more_ |
| `E_ATOMIC_OPERATION` | atomic fetch_add/fetch_sub requires an integer payload type<br>unknown atomic operation | `src/mir_verify_util.zig:189`<br>`src/sema.zig:4706`<br>`src/sema.zig:4733` |
| `E_ATOMIC_ORDERING` | atomic load ordering must be .relaxed, .acquire, or .seq_cst<br>atomic read-modify-write ordering must be a valid atomic memory order<br>atomic store ordering must be .relaxed, .release, or .seq_cst | `src/mir_verify_util.zig:191`<br>`src/sema.zig:4792`<br>`src/sema.zig:4796`<br>`src/sema.zig:4802`<br>`src/sema.zig:4806`<br>`src/sema.zig:4812`<br>_+1 more_ |
| `E_ATOMIC_RESOURCE_PAYLOAD` | atomic payloads cannot be \`move\`/\`linear\`, \`region\`, or \`view struct\` resources; store a copyable handle or integer state instead<br>atomic.init cannot materialize \`move\`/\`linear\`, \`region\`, or \`view struct\` resources; store a copyable handle or integer state instead | `src/sema.zig:4697`<br>`src/sema.zig:4744` |
| `E_AWAIT_OUTSIDE_ASYNC` | \`await\` is only valid inside an \`async fn\` (in '{s}') | `src/async_lower.zig:261` |
| `E_BACKEND_UNSUPPORTED` | C backend does not yet support {s}<br>LLVM backend does not yet support {s}<br>{s} backend does not yet support this construct | `src/lower_c_emitter.zig:3601`<br>`src/lower_c_emitter.zig:4128`<br>`src/lower_llvm.zig:1464`<br>`src/lower_llvm.zig:1471`<br>`src/main.zig:1431` |
| `E_BITCAST_TYPE` | bitcast pointer-reinterpret may not cross into or out of a \`move\`/\`linear\` resource pointee; use a typed resource API or an explicit unsafe raw handle<br>bitcast pointer-reinterpret may not cross into or out of a \`region struct\` pointee; use a region-aware view or stable ID<br>bitcast pointer-reinterpret may not cross into or out of a \`view struct\` pointee; rebuild the view from its source inside the lexical scope<br>_+4 more_ | `src/mir_verify_util.zig:194`<br>`src/sema.zig:5167`<br>`src/sema.zig:5177`<br>`src/sema.zig:5180`<br>`src/sema.zig:5195`<br>`src/sema.zig:5199`<br>_+2 more_ |
| `E_BITWISE_ARITH_DOMAIN_OPERAND` | bitwise operations are not defined on this arithmetic domain | `src/mir_verify_util.zig:144`<br>`src/sema.zig:3804`<br>`src/sema.zig:3885` |
| `E_BITWISE_BOOL_OPERAND` | bitwise operations are not defined on bool operands | `src/mir_verify_util.zig:155`<br>`src/sema.zig:3795`<br>`src/sema.zig:3879` |
| `E_BITWISE_POINTER_OPERAND` | bitwise operations are not defined on pointer operands | `src/mir_verify_util.zig:156`<br>`src/sema.zig:3798`<br>`src/sema.zig:3882` |
| `E_BITWISE_SIGNED_OPERAND` | bitwise operations are not defined on signed checked integers | `src/mir_verify_util.zig:154`<br>`src/sema.zig:3792`<br>`src/sema.zig:3870` |
| `E_BOOL_OPERATOR_OPERAND` | boolean operators are defined only for bool operands | `src/mir_verify_util.zig:157`<br>`src/sema.zig:3811`<br>`src/sema.zig:3895` |
| `E_BORROW_CONFLICT` | cannot assign to a local while a scoped borrow of it is live<br>cannot assign to storage while a scoped borrow of it is live<br>cannot move a linear \`move\` value while a scoped borrow is live<br>_+2 more_ | `src/sema_move.zig:976`<br>`src/sema_move.zig:1024`<br>`src/sema_move.zig:1046`<br>`src/sema_move.zig:3051`<br>`src/sema_move.zig:3093`<br>`src/sema_move.zig:4540`<br>_+1 more_ |
| `E_BORROW_ESCAPES_SCOPE` | \`#[c_union]\` fields cannot contain \`view struct\` borrowed aggregates by value; rebuild the view lexically from its source<br>\`view struct\` is a lexical borrowed view and cannot also be \`move\`, \`linear\`, \`region\`, or \`thread_move\`<br>cannot return a wrapper value that carries a scoped borrow of local storage; return a parameter-derived view with \`-&gt; borrow(param)\` or an owned value<br>_+14 more_ | `src/sema.zig:1222`<br>`src/sema.zig:1295`<br>`src/sema.zig:1330`<br>`src/sema.zig:1332`<br>`src/sema.zig:2046`<br>`src/sema.zig:2098`<br>_+12 more_ |
| `E_BORROW_FFI_BOUNDARY` | explicit \`borrow\` cannot cross an extern/C ABI call boundary; bind or copy through an ownership-aware safe wrapper | `src/sema.zig:4150` |
| `E_BORROW_MUT_REQUIRED` | \`borrow\` creates a shared borrow; use \`borrow mut\` for a mutable dyn pointer target<br>\`borrow\` creates a shared borrow; use \`borrow mut\` for a mutable pointer target | `src/sema.zig:6396`<br>`src/sema.zig:6617` |
| `E_BORROW_MUT_REQUIRES_MUTABLE_STORAGE` | \`borrow mut\` requires mutable storage | `src/sema.zig:3760` |
| `E_BORROW_REQUIRES_STORAGE` | explicit \`borrow\` requires addressable storage; bind temporaries to a local before borrowing them | `src/sema.zig:3758` |
| `E_BORROW_RETURN_CONTRACT` | \`borrow(source)\` may return a direct \`view struct\` in Scoped Affine Ownership v0, but not a Result/optional/array/container that stores a view by value<br>\`borrow(source)\` must name one function parameter<br>\`borrow(source)\` return contract is only valid for pointer, slice, cstr, nullable pointer, or \`view struct\` returns<br>_+3 more_ | `src/sema.zig:2386`<br>`src/sema.zig:2390`<br>`src/sema.zig:2396`<br>`src/sema.zig:2409`<br>`src/sema.zig:2413`<br>`src/sema.zig:6752` |
| `E_BORROW_THREAD_BOUNDARY` | \`view struct\` values cannot cross a thread/task spawn boundary; rebuild the view inside the spawned task from owned or thread-safe state<br>address of local storage cannot cross a thread/task spawn boundary; move owned state or use a thread-safe handle instead<br>explicit \`borrow\` cannot cross a thread/task spawn boundary; pass owned state or a \`thread_move\` resource<br>_+1 more_ | `src/sema.zig:6875`<br>`src/sema.zig:6878`<br>`src/sema.zig:6882`<br>`src/sema.zig:6890` |
| `E_BREAK_OUTSIDE_LOOP` | break is valid only inside a loop | `src/sema.zig:3333` |
| `E_BYTE_VIEW_ADDRESS` | mem.as_bytes requires an address expression<br>mem.as_bytes requires an addressable value with known storage type<br>mem.as_bytes requires byte-addressable storage | `src/sema.zig:4980`<br>`src/sema.zig:4984`<br>`src/sema.zig:4989` |
| `E_BYTE_VIEW_RESOURCE` | mem.as_bytes cannot expose a \`region struct\` node by value; serialize through a region-aware view or stable ID<br>mem.as_bytes cannot expose a \`view struct\` by value; copy from the original source view or use an explicit serialization API<br>mem.as_bytes cannot expose the byte representation of a \`move\`/\`linear\` resource; use an explicit serialization or handle API | `src/sema.zig:4993`<br>`src/sema.zig:4997`<br>`src/sema.zig:5000` |
| `E_BYTE_VIEW_SLICE` | mem.bytes_equal expects []const u8 byte slices | `src/sema.zig:5013` |
| `E_CALL_ARG_COUNT` | DmaBuf operation does not take arguments<br>MMIO read expects exactly one ordering argument<br>MMIO write expects a value and one ordering argument<br>_+32 more_ | `src/sema.zig:4009`<br>`src/sema.zig:4031`<br>`src/sema.zig:4061`<br>`src/sema.zig:4110`<br>`src/sema.zig:4187`<br>`src/sema.zig:4198`<br>_+34 more_ |
| `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION` | integer-to-closed-enum conversion must use a checked conversion path | `src/mir_verify_util.zig:193`<br>`src/sema.zig:7015` |
| `E_CLOSED_ENUM_SWITCH_EXHAUSTIVE` | switch over closed enum must cover every case or use '_' | `src/mir_verify_util.zig:128`<br>`src/sema.zig:7992` |
| `E_CLOSURE_RESOURCE_CAPTURE` | closure environments cannot capture \`move\`/\`linear\`, \`region\`, or \`view struct\` resources by value; pass a stable handle/pointer or use an explicit owned-closure API | `src/sema.zig:6494` |
| `E_CLOSURE_SIGNATURE_MISMATCH` | bind target does not match the expected closure type<br>closure signature does not match the expected type | `src/sema.zig:6523`<br>`src/sema.zig:6530` |
| `E_COMPTIME_ARG_REQUIRED` | comptime parameter requires a compile-time constant argument | `src/sema.zig:4125` |
| `E_COMPTIME_ERROR` | _see source_ | `src/sema.zig:3061` |
| `E_COMPTIME_FORBIDS_RUNTIME_EFFECT` | comptime code cannot alter runtime control flow<br>comptime code cannot call runtime functions<br>comptime code cannot perform runtime hardware or I/O effects | `src/sema.zig:3272`<br>`src/sema.zig:3310`<br>`src/sema.zig:3330`<br>`src/sema.zig:3342`<br>`src/sema.zig:3384`<br>`src/sema.zig:3966`<br>_+3 more_ |
| `E_COMPTIME_TRAP` | trap during const eval is a compile error | `src/sema.zig:2152`<br>`src/sema.zig:3041`<br>`src/sema.zig:3049`<br>`src/sema.zig:3052`<br>`src/sema.zig:3067`<br>`src/sema.zig:3074`<br>_+2 more_ |
| `E_CONDITION_NOT_BOOL` | condition must be bool | `src/mir_verify_util.zig:91`<br>`src/sema.zig:3189`<br>`src/sema.zig:3373` |
| `E_CONST_GET_BASE` | const_get is defined only for fixed-length arrays | `src/sema.zig:5117`<br>`src/sema.zig:5121` |
| `E_CONST_GET_BOUNDS` | const_get index is out of bounds for the fixed-length array | `src/sema.zig:5126` |
| `E_CONST_GET_INDEX` | const_get requires exactly one compile-time usize index | `src/sema.zig:5113` |
| `E_CONTINUE_OUTSIDE_LOOP` | continue is valid only inside a loop | `src/sema.zig:3345` |
| `E_CONVERSION_OPERATION` | from_mod is defined only on wrap&lt;T&gt; targets<br>residue() is defined only on wrap&lt;T&gt; values<br>try_from/trap_from/wrap_from/sat_from are defined only on scalar integer targets<br>_+1 more_ | `src/mir_verify_util.zig:148`<br>`src/sema.zig:4873`<br>`src/sema.zig:4877`<br>`src/sema.zig:4912`<br>`src/sema.zig:4922` |
| `E_COPYING_RESOURCE_PAYLOAD` | copying/storage generic APIs such as sort/is_sorted/lower_bound/scan/ring/pool/slotmap/Vec/Arc/StrHashMap cannot use \`move\`/\`linear\`, \`region\`, or \`view struct\` element types; store stable handles or IDs instead | `src/sema.zig:5093`<br>`src/sema.zig:5102` |
| `E_COUNTER_OPERATION` | _see source_ | `src/mir_verify_util.zig:147`<br>`src/sema.zig:4888` |
| `E_C_VOID_CONVERSION` | c_void pointer conversions require an explicit FFI boundary operation | `src/mir_verify_util.zig:87`<br>`src/mir_verify_util.zig:88`<br>`src/mir_verify_util.zig:89`<br>`src/mir_verify_util.zig:90`<br>`src/mir_verify_util.zig:112`<br>`src/sema.zig:3916`<br>_+2 more_ |
| `E_C_VOID_DEREF` | c_void pointer cannot be dereferenced | `src/mir_verify_util.zig:184`<br>`src/sema.zig:4287` |
| `E_C_VOID_NO_LAYOUT` | c_void has no fields in MC<br>c_void has no size or alignment in MC<br>c_void has no size or layout in MC; use pointers to c_void at FFI boundaries | `src/mir_verify_util.zig:185`<br>`src/sema.zig:4308`<br>`src/sema.zig:4429`<br>`src/sema.zig:5964` |
| `E_DECLASSIFY_NOT_SECRET` | declassify/reveal applies only to a Secret&lt;T&gt; value | `src/sema.zig:5312` |
| `E_DEFER_CONTROL_FLOW` | defer is lexical cleanup and must not alter control flow | `src/sema.zig:3358` |
| `E_DIAGNOSTIC_OOM` | compiler diagnostic allocation failed | `src/diagnostics.zig:194`<br>`src/diagnostics.zig:292`<br>`src/diagnostics.zig:518` |
| `E_DMA_ADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:170`<br>`src/sema.zig:9406` |
| `E_DMA_ADDR_NOT_PADDR` | _see source_ | `src/mir_verify_util.zig:178`<br>`src/sema.zig:9391` |
| `E_DMA_ADDR_NOT_VADDR` | _see source_ | `src/mir_verify_util.zig:179`<br>`src/sema.zig:9392` |
| `E_DMA_BUF_MODE` | DmaBuf mode must be .coherent or .noncoherent | `src/sema.zig:4634`<br>`src/sema.zig:4639` |
| `E_DMA_CACHE_MODE` | cache clean/invalidate are required only for noncoherent DmaBuf values | `src/mir_verify_util.zig:195`<br>`src/sema.zig:4835` |
| `E_DMA_OPERATION` | cache DMA operation requires a DmaBuf argument<br>dma_addr/as_slice are defined only on DmaBuf values<br>unknown DmaBuf operation | `src/mir_verify_util.zig:190`<br>`src/sema.zig:4830`<br>`src/sema.zig:4844`<br>`src/sema.zig:4860` |
| `E_DROP_ATTR_SHAPE` | #[drop] applies only to a function declaration<br>#[drop] release function must return void<br>#[drop] release function must take a \`*mut\` checked resource as its first parameter<br>_+2 more_ | `src/sema.zig:973`<br>`src/sema.zig:978`<br>`src/sema.zig:982`<br>`src/sema.zig:992`<br>`src/sema.zig:996` |
| `E_DROP_LINEAR_RESOURCE` | a checked resource value cannot be \`drop\`ped unless its type is marked \`#[trivial_drop]\`; release it with a by-value consuming function, a \`#[drop] fn release(*mut T)\`, or \`forget_unchecked\` in unsafe once transferred | `src/sema_move.zig:2965` |
| `E_DUPLICATE_BACKEND_NAME` | backend symbol "{s}" is assigned to both \`{s}\` and \`{s}\` | `src/sema.zig:5932` |
| `E_DUPLICATE_DECLARATION` | duplicate trait declaration<br>top-level declarations must have unique names | `src/sema.zig:1149`<br>`src/sema.zig:7668` |
| `E_DUPLICATE_ENUM_CASE` | enum case names must be unique | `src/sema.zig:1256` |
| `E_DUPLICATE_ENUM_VALUE` | enum case representation values must be unique | `src/sema.zig:1279` |
| `E_DUPLICATE_LOCAL` | local bindings must have unique names in the current scope | `src/async_lower.zig:1400`<br>`src/sema.zig:3525`<br>`src/sema.zig:8209` |
| `E_DUPLICATE_OVERLAY_FIELD` | overlay union field names must be unique | `src/sema.zig:2103` |
| `E_DUPLICATE_PACKED_BITS_FIELD` | packed bits field names must be unique | `src/sema.zig:2075` |
| `E_DUPLICATE_PARAMETER` | function parameter names must be unique | `src/async_lower.zig:1419`<br>`src/sema.zig:2268` |
| `E_DUPLICATE_STRUCT_FIELD` | struct field names must be unique | `src/sema.zig:1341` |
| `E_DUPLICATE_STRUCT_LITERAL_FIELD` | struct literal field names must be unique | `src/mir_verify_util.zig:103`<br>`src/sema.zig:6306`<br>`src/sema.zig:6360` |
| `E_DUPLICATE_SWITCH_CASE` | switch case pattern is already covered | `src/mir_verify_util.zig:126`<br>`src/mir_verify_util.zig:132`<br>`src/sema.zig:8006`<br>`src/sema.zig:8024`<br>`src/sema.zig:8042`<br>`src/sema.zig:8056`<br>_+4 more_ |
| `E_DUPLICATE_UNION_CASE` | safe tagged union case names must be unique | `src/sema.zig:2052` |
| `E_DYN_FORGE` | a \`*dyn Trait\` cannot be hand-assembled in safe code; build it with \`&amp;x\` / \`&amp;mut x\` (the checked coercion). \`*dyn\` is a compiler-protected type — fabrication requires \`unsafe\` | `src/sema.zig:6666` |
| `E_DYN_MOVE_SELF` | a consuming (\`move self\`/by-value) method cannot be called through \`*dyn Trait\` (you cannot move out of a borrowed trait object) | `src/sema.zig:4056` |
| `E_DYN_MUT_BORROW` | a \`*mut dyn Trait\` requires \`&amp;mut\` of a mutable place<br>a \`*mut dyn Trait\` requires a \`*mut T\` (mutable) source pointer | `src/sema.zig:6624`<br>`src/sema.zig:6655` |
| `E_ENUM_CASE_VALUE_NOT_INTEGER` | enum representation values must be integer literals | `src/sema.zig:1269` |
| `E_ENUM_CASE_VALUE_OUT_OF_RANGE` | enum case value is outside the representation type range | `src/sema.zig:1275` |
| `E_ENUM_LITERAL_REQUIRES_TARGET` | enum literal requires an explicit enum target type | `src/sema.zig:7245` |
| `E_ENUM_REPR_NOT_INTEGER` | enum representation type must be an integer type | `src/sema.zig:1245` |
| `E_EXPLICIT_MOVE_REQUIRED` | _see source_ | `src/sema.zig:3644` |
| `E_EXTERN_STRUCT_BY_VALUE` | C variadic tail arguments must be classified scalar or pointer values<br>explicit C ABI functions cannot pass this unclassified value type by value; use a pointer or mark an MC-only export #[mc_abi]<br>explicit C ABI functions cannot return this unclassified value type by value; use an out pointer or mark an MC-only export #[mc_abi]<br>_+1 more_ | `src/sema.zig:2368`<br>`src/sema.zig:2373`<br>`src/sema.zig:2377`<br>`src/sema.zig:4165` |
| `E_FN_POINTER_SIGNATURE_MISMATCH` | a variadic function cannot be converted to a non-variadic function pointer<br>a variadic function cannot be inferred as a non-variadic function pointer<br>a variadic function cannot be passed as a non-variadic function pointer<br>_+5 more_ | `src/sema.zig:6413`<br>`src/sema.zig:6421`<br>`src/sema.zig:6425`<br>`src/sema.zig:6433`<br>`src/sema.zig:6443`<br>`src/sema.zig:6451`<br>_+4 more_ |
| `E_FOR_BASE_NOT_ARRAY_OR_SLICE` | for loops iterate over arrays and slices | `src/mir_verify_util.zig:84`<br>`src/sema.zig:3191` |
| `E_GENERATED_NAME_COLLISION` | generic specialization would collide with user declaration \`{s}\` | `src/monomorphize.zig:1350` |
| `E_GENERIC_LOOKAHEAD_LIMIT` | generic-call lookahead exceeds {d} tokens | `src/parser.zig:1854` |
| `E_GENERIC_TYPE_ARG_COUNT` | generic type has the wrong number of type arguments | `src/sema.zig:4478`<br>`src/sema.zig:4487` |
| `E_GLOBAL_INITIALIZER_NOT_STATIC` | global initializer must be a compile-time static value for M0 C emission | `src/sema.zig:2156` |
| `E_GLOBAL_REQUIRES_TYPE` | global declarations require an explicit storage type | `src/sema.zig:1230` |
| `E_GLOBAL_RESOURCE_STORAGE` | global storage cannot own \`move\`/\`linear\` resources by value; use an explicit init token, pointer, or copyable handle instead | `src/sema.zig:1227` |
| `E_IF_LET_NARROW_PATTERN` | if let supports only optional bindings and Result ok(...) or err(...) bindings | `src/mir_verify_util.zig:118`<br>`src/sema.zig:7836`<br>`src/sema.zig:7843` |
| `E_IF_LET_OPTIONAL_REQUIRED` | plain if let binding requires a nullable value | `src/mir_verify_util.zig:115`<br>`src/sema.zig:7828` |
| `E_IF_LET_RESULT_REQUIRED` | if let ok(...) or err(...) requires a Result value | `src/mir_verify_util.zig:116`<br>`src/sema.zig:7839` |
| `E_IF_LET_RESULT_TAG` | if let result narrowing supports only ok(...) or err(...) | `src/mir_verify_util.zig:117`<br>`src/sema.zig:7834` |
| `E_ILLEGAL_SLICE_CAST` | cannot cast a non-slice value to a slice: a slice is a fat pointer (ptr+len) and the length has no source. Build one with a slicing expression \`a[i..j]\`, a byte view (\`mem.as_bytes\`), or a string literal | `src/sema.zig:3925` |
| `E_IMPORT_DEPTH_LIMIT` | import depth exceeds configured limit {d} | `src/loader.zig:431`<br>`src/loader.zig:564` |
| `E_IMPORT_EXPANDED_SOURCE_LIMIT` | expanded source exceeds configured limit {d} bytes | `src/loader.zig:576`<br>`src/loader.zig:579`<br>`src/loader.zig:582` |
| `E_IMPORT_FILE_LIMIT` | import graph exceeds configured file limit {d} | `src/loader.zig:435`<br>`src/loader.zig:567` |
| `E_IMPORT_INVALID_STRING` | import path cannot contain NUL<br>import path must be a valid string literal | `src/loader.zig:653`<br>`src/loader.zig:662` |
| `E_IMPORT_NOT_FOUND` | cannot find import "{s}" (resolved candidate: {s}) | `src/loader.zig:452` |
| `E_IMPORT_OUTSIDE_SANDBOX` | import "{s}" resolves to {s}, outside the import sandbox rooted at {s} | `src/loader.zig:421` |
| `E_IMPORT_TOTAL_BYTES_LIMIT` | import graph exceeds configured cumulative input limit {d} bytes | `src/loader.zig:570`<br>`src/loader.zig:573` |
| `E_INDEX_BASE_NOT_ARRAY_OR_SLICE` | indexing is defined only for arrays and slices<br>slicing is defined only for arrays and slices | `src/mir_verify_util.zig:85`<br>`src/sema.zig:4240`<br>`src/sema.zig:4262` |
| `E_INDEX_NOT_USIZE` | array and slice indices must be checked usize<br>slice range bounds must be checked usize | `src/mir_verify_util.zig:86`<br>`src/sema.zig:4249`<br>`src/sema.zig:4266`<br>`src/sema.zig:4270`<br>`src/sema.zig:7216` |
| `E_INTEGER_LITERAL_OUT_OF_RANGE` | integer literal is not representable in its explicit suffix type<br>integer literal is not representable in the annotated type | `src/mir_verify_util.zig:83`<br>`src/sema.zig:6133`<br>`src/sema.zig:6141`<br>`src/sema.zig:6154`<br>`src/sema.zig:6157`<br>`src/sema.zig:6164`<br>_+6 more_ |
| `E_INTERNAL_GENERIC_LINKAGE_COLLISION` | unequal generic instance keys produced the same linkage name \`{s}\` | `src/monomorphize.zig:1361` |
| `E_INTERNAL_OOM` | compiler exceeded implicit resource aggregate classification depth<br>compiler ran out of memory while building symbol tables; results are incomplete | `src/sema.zig:745`<br>`src/sema.zig:1045` |
| `E_INVALID_ASSIGNMENT_TARGET` | assignment target must be assignable storage | `src/mir_verify_util.zig:138`<br>`src/sema.zig:3380` |
| `E_INVALID_ERROR_FROM` | #[error_from] fn must convert one named error type to another (fn(E1) -&gt; E2)<br>#[error_from] fn must take exactly one parameter (the source error type) | `src/sema.zig:3678`<br>`src/sema.zig:3684` |
| `E_INVALID_TRAP_KIND` | trap expects exactly one language TrapKind<br>trap kind must be a language TrapKind enum literal<br>unknown language TrapKind | `src/sema.zig:5943`<br>`src/sema.zig:5949`<br>`src/sema.zig:5954` |
| `E_IRQ_CONTEXT_BLOCKING` | _see source_ | `src/mir_verify_util.zig:47` |
| `E_IRQ_CONTEXT_CALL` | an #[irq_context] function may not dispatch through \`*dyn Trait\` (a virtual call is an indirect call whose target may sleep or block)<br>an #[irq_context] function may not make an indirect/closure call (the target may sleep or block)<br>an #[irq_context] function may not make an indirect/fn-pointer call (the target may sleep or block)<br>_+1 more_ | `src/mir_verify_util.zig:46`<br>`src/sema.zig:4019`<br>`src/sema.zig:4034`<br>`src/sema.zig:4064`<br>`src/sema.zig:4102` |
| `E_LEX_INVALID_CHAR_LITERAL` | invalid char literal | `src/lexer.zig:264` |
| `E_LEX_INVALID_ESCAPE_SEQUENCE` | invalid escape sequence | `src/lexer.zig:281` |
| `E_LEX_INVALID_FLOAT_LITERAL` | invalid float literal | `src/lexer.zig:214` |
| `E_LEX_INVALID_INTEGER_LITERAL` | invalid integer literal | `src/lexer.zig:216` |
| `E_LEX_UNEXPECTED_BYTE` | unexpected byte '{c}' | `src/lexer.zig:65` |
| `E_LEX_UNTERMINATED_BLOCK_COMMENT` | unterminated block comment | `src/lexer.zig:94` |
| `E_LEX_UNTERMINATED_CHAR_LITERAL` | unterminated char literal | `src/lexer.zig:247`<br>`src/lexer.zig:260` |
| `E_LEX_UNTERMINATED_ESCAPE_SEQUENCE` | unterminated escape sequence | `src/lexer.zig:270` |
| `E_LEX_UNTERMINATED_STRING_LITERAL` | unterminated string literal | `src/lexer.zig:225`<br>`src/lexer.zig:236` |
| `E_LITERAL_REQUIRES_TARGET` | literal requires an explicit target type | `src/sema.zig:7249` |
| `E_LOCAL_ADDRESS_ESCAPE` | cannot return a closure that captures local storage (the environment would dangle)<br>cannot return the address of local storage<br>cannot return the address of local storage inside an aggregate (the borrow would dangle)<br>_+2 more_ | `src/mir_verify_util.zig:196`<br>`src/sema.zig:3622`<br>`src/sema.zig:3626`<br>`src/sema.zig:6716`<br>`src/sema.zig:6723`<br>`src/sema.zig:6868`<br>_+1 more_ |
| `E_LOCAL_REQUIRES_INITIALIZER` | ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage | `src/sema.zig:3473` |
| `E_MAYBEUNINIT_RESOURCE_PAYLOAD` | MaybeUninit cannot store \`move\`/\`linear\`, \`region\`, or \`view struct\` payloads; use an ownership-aware resource container instead | `src/sema.zig:4770` |
| `E_MC_VOID_POINTER_FFI` | use c_void for C opaque object pointers, not MC void | `src/sema.zig:4427` |
| `E_MIR_CFG` | MIR verifier found malformed control-flow graph | `src/mir.zig:10393` |
| `E_MIR_IDENTITY` | MIR verifier found malformed instruction identity | `src/mir.zig:1228` |
| `E_MIR_SYMBOL_ID` | MIR verifier found malformed symbol identity table | `src/mir.zig:1216` |
| `E_MMIO_ACCESS_FORBIDDEN` | MIR verifier found MMIO register access disallowed by Reg/RegBits mode<br>MMIO register access mode does not allow read<br>MMIO register access mode does not allow write | `src/mir.zig:1095`<br>`src/sema.zig:4673`<br>`src/sema.zig:4683` |
| `E_MMIO_ACCESS_MODE` | MMIO register access mode must be .read, .write, or .read_write | `src/sema.zig:4653`<br>`src/sema.zig:4658` |
| `E_MMIO_DIRECT_ASSIGN` | MIR verifier found direct assignment to an MMIO register<br>MMIO registers must be accessed through typed read/write methods | `src/mir.zig:1089`<br>`src/sema.zig:3386` |
| `E_MMIO_ORDERING` | MMIO read ordering must be .relaxed or .acquire<br>MMIO write ordering must be .relaxed or .release | `src/mir_verify_util.zig:192`<br>`src/sema.zig:5325`<br>`src/sema.zig:5329`<br>`src/sema.zig:5335`<br>`src/sema.zig:5339` |
| `E_MMIO_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:172`<br>`src/sema.zig:9408` |
| `E_MMIO_PTR_TARGET` | MmioPtr target must be an extern mmio struct type | `src/sema.zig:4600`<br>`src/sema.zig:4605` |
| `E_MMIO_REGBITS_TYPE` | RegBits value type must be a known packed bits type | `src/sema.zig:4561` |
| `E_MMIO_REGISTER_POSITION` | Reg and RegBits types are valid only as extern mmio struct fields | `src/sema.zig:4594` |
| `E_MMIO_REGISTER_WIDTH` | MMIO register width must be u8, u16, u32, or u64 | `src/sema.zig:4645` |
| `E_MONOMORPHIZATION_LIMIT` | _see source_ | `src/monomorphize.zig:1105` |
| `E_MOVE_ABI_BY_VALUE` | explicit C ABI parameters cannot pass \`move\`/\`linear\` resources by value; pass a pointer, an integer handle, or mark an MC-only export \`#[mc_abi]\`<br>explicit C ABI returns cannot carry \`move\`/\`linear\` resources by value; return a pointer, an integer handle, or mark an MC-only export \`#[mc_abi]\` | `src/sema.zig:2259`<br>`src/sema.zig:2290` |
| `E_MOVE_ARRAY_UNSUPPORTED` | a non-\`move\` struct cannot store an array of linear \`move\` values by value; make the struct \`move\`, or hold the resources behind pointers<br>cannot assign a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to update<br>cannot defer a linear \`move\` array element through an untracked dynamic index; the checker has no nameable owner place to reserve<br>_+4 more_ | `src/sema.zig:1225`<br>`src/sema.zig:1324`<br>`src/sema.zig:2261`<br>`src/sema.zig:2292`<br>`src/sema_move.zig:1069`<br>`src/sema_move.zig:2911`<br>_+2 more_ |
| `E_MOVE_BRANCH_MISMATCH` | linear \`move\` field has inconsistent ownership across control-flow branches<br>linear \`move\` value has inconsistent ownership across control-flow branches | `src/sema_move.zig:1565`<br>`src/sema_move.zig:1574`<br>`src/sema_move.zig:1593`<br>`src/sema_move.zig:3240`<br>`src/sema_move.zig:3256` |
| `E_MOVE_FFI_ADDRESS` | safe code cannot pass a pointer to \`move\`/\`linear\`, \`region\`, or \`view struct\` storage across an extern/C ABI boundary; wrap audited byte-level access in unsafe or expose an ownership-aware safe API | `src/sema.zig:5262` |
| `E_MOVE_LOOP_RESOURCE` | cannot consume or reserve an outer linear \`move\` value inside a loop; the loop may run zero or multiple times<br>cannot move an outer linear \`move\` place inside a loop; the loop may run zero or multiple times | `src/sema_move.zig:751`<br>`src/sema_move.zig:766`<br>`src/sema_move.zig:1715` |
| `E_MOVE_UNION_RESOURCE` | \`#[c_union]\` fields cannot contain \`move\`/\`linear\` resources by value; store a pointer or stable handle instead<br>overlay union fields cannot contain \`move\`/\`linear\` resources by value; store a pointer or stable handle instead<br>tagged union cases cannot contain \`move\`/\`linear\` resources by value; store a pointer or stable handle instead | `src/sema.zig:1322`<br>`src/sema.zig:2039`<br>`src/sema.zig:2091` |
| `E_NAKED_BODY` | a #[naked] function body must be exactly one \`asm\` block (optionally wrapped in one \`unsafe {}\`); there is no frame for locals, statements, or expressions | `src/sema.zig:2312` |
| `E_NAKED_RETURN` | a #[naked] function must return \`never\` or \`void\`; it cannot synthesize a value return (the asm body owns the calling convention) | `src/sema.zig:2307` |
| `E_NESTING_TOO_DEEP` | nesting too deep | `src/parser.zig:2281` |
| `E_NEVER_FALLTHROUGH` | function declared -&gt; never can fall off the end | `src/hir.zig:181`<br>`src/mir.zig:1013`<br>`src/sema.zig:2356` |
| `E_NEVER_RETURNS` | function declared -&gt; never cannot return normally | `src/sema.zig:3316`<br>`src/sema.zig:3323` |
| `E_NEVER_STORAGE` | never is a control-flow type and cannot be used for storage | `src/sema.zig:4433`<br>`src/sema.zig:4615` |
| `E_NONLOCAL_JUMP_RESOURCE` | longjmp-style non-local control flow cannot cross live \`move\`/\`linear\`, \`region\`, \`view struct\`, or explicit borrow state; use structured Result/error returns so deterministic cleanup runs | `src/sema.zig:5077` |
| `E_NO_ERROR_CONVERSION` | '?' cannot convert the propagated error to the function's error type; declare an #[error_from] fn converting it | `src/sema.zig:3714` |
| `E_NO_IMPLICIT_CONVERSION` | MaybeUninit.write payload must match the storage type<br>Secret&lt;T&gt; can only wrap a value of its underlying type T<br>annotated local initializer requires an explicit conversion<br>_+9 more_ | `src/mir_verify_util.zig:98`<br>`src/mir_verify_util.zig:106`<br>`src/mir_verify_util.zig:131`<br>`src/mir_verify_util.zig:160`<br>`src/sema.zig:2129`<br>`src/sema.zig:2130`<br>_+39 more_ |
| `E_NO_IMPLICIT_INTEGER_PROMOTION` | integer arithmetic requires matching types or an explicit conversion | `src/mir_verify_util.zig:159`<br>`src/sema.zig:7294` |
| `E_NO_IMPLICIT_POINTER_CONVERSION` | pointer and view conversions must be explicit<br>pointer comparisons require compatible pointer or view operands | `src/mir_verify_util.zig:78`<br>`src/mir_verify_util.zig:79`<br>`src/mir_verify_util.zig:92`<br>`src/mir_verify_util.zig:93`<br>`src/mir_verify_util.zig:94`<br>`src/mir_verify_util.zig:95`<br>_+6 more_ |
| `E_NO_LANG_TRAP_EDGE` | HIR verifier found language trap edge {s} before C emission<br>MIR verifier found language trap edge {s}<br>assert may emit a language trap in #[no_lang_trap]<br>_+9 more_ | `src/hir.zig:195`<br>`src/mir.zig:1022`<br>`src/sema.zig:3369`<br>`src/sema.zig:3741`<br>`src/sema.zig:3766`<br>`src/sema.zig:3783`<br>_+7 more_ |
| `E_NULLABLE_DYN_DISPATCH` | cannot dispatch a method through a \`?*dyn Trait\` (it may be absent / \`none\`); narrow it first with \`if let\` / \`switch\`, or \`unwrap\` it to a \`*dyn Trait\` | `src/sema.zig:4045` |
| `E_NULLABLE_DYN_NARROW` | a \`?*dyn Trait\` cannot coerce to a non-null \`*dyn Trait\`: it may be \`none\`. Narrow it with \`if let\` / \`switch\`, or \`unwrap\` it first | `src/sema.zig:6605` |
| `E_NULL_NON_NULL_POINTER` | null cannot initialize a non-null pointer | `src/mir_verify_util.zig:77`<br>`src/sema.zig:6197` |
| `E_NULL_REQUIRES_TARGET` | null requires an explicit nullable pointer target type | `src/sema.zig:2117`<br>`src/sema.zig:3431` |
| `E_OPAQUE_DECLASSIFY` | casting an \`opaque struct\` value to another type declassifies its private fields; use an accessor in its \`impl\`, or \`unsafe\` | `src/sema.zig:7185` |
| `E_OPERATOR_OPERAND` | arithmetic operators require integer or arithmetic-domain operands<br>bitwise operators require unsigned integer or wrapping operands<br>equality operators require comparable operands<br>_+3 more_ | `src/mir_verify_util.zig:163`<br>`src/mir_verify_util.zig:197`<br>`src/sema.zig:3833`<br>`src/sema.zig:7300`<br>`src/sema.zig:7304`<br>`src/sema.zig:7311`<br>_+9 more_ |
| `E_ORDERED_ARITH_DOMAIN_OPERAND` | ordered comparisons are not defined on wrap, serial, or counter arithmetic domains | `src/mir_verify_util.zig:145`<br>`src/sema.zig:7401` |
| `E_ORPHAN_IMPL` | impl of an opaque type must be in its defining module (file); a peer impl in another file cannot reach its private fields<br>trait impl for a type must be in the file that declares the type | `src/sema.zig:7629`<br>`src/sema.zig:7645` |
| `E_PACKED_BITS_FIELD_NOT_BOOL` | packed bits fields must be bool | `src/sema.zig:2072` |
| `E_PACKED_BITS_REPR_NOT_INTEGER` | packed bits representation type must be an integer type | `src/sema.zig:2064` |
| `E_PADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:168`<br>`src/sema.zig:9404` |
| `E_PARSE` | _see source_ | `src/parser.zig:2259` |
| `E_PARSE_EXPECTED_EXPRESSION` | _see source_ | `src/parser.zig:2257` |
| `E_PARSE_EXPECTED_PARAMETER_NAME` | _see source_ | `src/parser.zig:2258` |
| `E_PARSE_FAILED` | _see source_ | `src/main.zig:711` |
| `E_PHYS_PTR_DEREF` | _see source_ | `src/mir_verify_util.zig:173`<br>`src/sema.zig:9409` |
| `E_POINTER_ARITH_SINGLE_OBJECT` | single-object pointers do not support arithmetic | `src/mir_verify_util.zig:161`<br>`src/sema.zig:3862` |
| `E_POINTER_ORDERING` | optional values support only equality comparisons against null<br>pointer and view values support only equality comparisons | `src/mir_verify_util.zig:162`<br>`src/sema.zig:7441`<br>`src/sema.zig:7457` |
| `E_PRECISE_ASM_CONTRACT` | precise asm requires #[unsafe_contract(precise_asm)] | `src/sema.zig:3275` |
| `E_PRIVATE_FIELD` | cannot construct an \`opaque struct\` outside its associated functions (\`impl\` block); its fields are private<br>field of an \`opaque struct\` is private to its associated functions (\`impl\` block) | `src/sema.zig:6277`<br>`src/sema.zig:7487` |
| `E_PRIVATE_IMPORT` | this name is private under the active visibility mode; only \`pub\`/\`export\` items are visible to importing files | `src/sema.zig:7575` |
| `E_RAW_AGGREGATE_UNSUPPORTED` | raw.load/raw.store currently require a scalar payload; aggregate raw access has no defined single-access volatile contract | `src/sema.zig:6469` |
| `E_RAW_COPY_RESOURCE_PAYLOAD` | memcpy/memmove-style byte copies cannot copy \`move\`/\`linear\`, \`region\`, or \`view struct\` storage; transfer ownership through a typed API or copy a stable handle/ID instead<br>memset/bzero-style byte fills cannot overwrite \`move\`/\`linear\`, \`region\`, or \`view struct\` storage; reset resources through a typed release/reinitialize API instead | `src/sema.zig:5060`<br>`src/sema.zig:5065` |
| `E_RAW_RESOURCE_PAYLOAD` | raw memory operations cannot expose \`move\`/\`linear\`, \`region\`, or \`view struct\` resources by payload type; move ownership through a typed handle API instead | `src/sema.zig:6466` |
| `E_REDUCE_ARG_NOT_SLICE` | reduction expects a slice (\`[]const T\`) of the element type<br>reduction slice element type must match the reduction type argument | `src/sema.zig:4957`<br>`src/sema.zig:4964` |
| `E_REDUCE_REQUIRES_FLOAT` | floating-point reductions are restricted to f32/f64 | `src/sema.zig:4934`<br>`src/sema.zig:4939`<br>`src/sema.zig:4946` |
| `E_REDUCE_REQUIRES_INTEGER` | reduce.sum_checked is restricted to integer types | `src/sema.zig:4934`<br>`src/sema.zig:4939`<br>`src/sema.zig:4943` |
| `E_REFLECTION_FIELD_LITERAL` | field reflection requires an enum-literal field name | `src/sema.zig:5975` |
| `E_REFLECTION_GENERIC_ARG_COUNT` | reflection generic type has the wrong number of type arguments | `src/sema.zig:6018` |
| `E_REFLECTION_TYPE_ARG` | reflection type argument must be a type name | `src/sema.zig:6007` |
| `E_REFLECTION_TYPE_VALUE` | field_type produces a type and is valid only in type position | `src/sema.zig:5988` |
| `E_REFLECTION_UNKNOWN_TYPE` | field reflection requires a known field-bearing layout type<br>reflection layout could not be computed for this type<br>reflection requires a known layout-capable type | `src/sema.zig:6022`<br>`src/sema.zig:6043`<br>`src/sema.zig:6098`<br>`src/sema.zig:6107`<br>`src/sema.zig:6111`<br>`src/sema.zig:6122` |
| `E_REGION_RESOURCE_CONFLICT` | \`#[c_union]\` fields cannot contain \`region struct\` nodes by value; store a pointer, view, or stable ID<br>\`region struct\` cannot also be \`move\` or \`linear\`; the enclosing region owns its lifetime<br>\`region struct\` is region-owned and cannot declare #[trivial_drop]<br>_+8 more_ | `src/sema.zig:610`<br>`src/sema.zig:987`<br>`src/sema.zig:1219`<br>`src/sema.zig:1292`<br>`src/sema.zig:1328`<br>`src/sema.zig:1334`<br>_+5 more_ |
| `E_REPRESENTATION_CHECK_MISSING` | MIR verifier found representation-sensitive value use without dominating check | `src/mir.zig:1103`<br>`src/mir.zig:1110` |
| `E_RESERVED_C_IDENTIFIER` | identifier is reserved by the C backend or C headers; choose a different source name<br>local binding name is reserved by the C backend or C headers; choose a different source name<br>parameter name is reserved by the C backend or C headers; choose a different source name | `src/sema.zig:1156`<br>`src/sema.zig:2264`<br>`src/sema.zig:3514` |
| `E_RESERVED_QUALIFIED_NAME` | a local binding may not shadow a module/impl name<br>a parameter may not shadow a module/impl name<br>a top-level value may not shadow a module/impl name | `src/sema.zig:1163`<br>`src/sema.zig:2266`<br>`src/sema.zig:3518` |
| `E_RESOURCE_COMPARISON` | \`move\`/\`linear\`, \`region\`, and \`view struct\` resources do not support value comparison; compare an explicit stable handle, ID, or nullable presence tag instead | `src/sema.zig:7417` |
| `E_RESOURCE_ITERATION` | \`for\` iteration cannot bind \`move\`/\`linear\`, \`region\`, or \`view struct\` elements by value; iterate indexes and explicitly \`move\` from fixed arrays, or iterate pointers/stable IDs | `src/sema.zig:7899` |
| `E_RESOURCE_LEAK` | linear \`move\` value bound in a switch arm is never consumed (must be moved, returned, or freed)<br>linear \`move\` value bound in an if-let branch is never consumed (must be moved, returned, or freed)<br>linear \`move\` value created in only one branch is never consumed before the branch exits<br>_+2 more_ | `src/sema_move.zig:704`<br>`src/sema_move.zig:734`<br>`src/sema_move.zig:1211`<br>`src/sema_move.zig:1284`<br>`src/sema_move.zig:1343`<br>`src/sema_move.zig:1378`<br>_+3 more_ |
| `E_RESOURCE_OVERWRITE` | cannot assign a linear \`move\` array element through an unknown dynamic index; the selected live element must be consumed first<br>cannot overwrite a live linear \`move\` array element; consume it first<br>cannot overwrite a live linear \`move\` field; consume it first<br>_+1 more_ | `src/sema_move.zig:970`<br>`src/sema_move.zig:1033`<br>`src/sema_move.zig:1055`<br>`src/sema_move.zig:1064` |
| `E_RESOURCE_PATTERN` | \`move\`/\`linear\`, \`region\`, and \`view struct\` resources cannot be used as switch discriminants; narrow Result/nullable wrappers or switch on an explicit stable tag/ID instead | `src/sema.zig:7933` |
| `E_RETURN_MISSING` | function return type requires all paths to return a value | `src/hir.zig:181`<br>`src/mir.zig:1013`<br>`src/sema.zig:2358` |
| `E_RETURN_REQUIRES_VALUE` | function return type requires a value | `src/sema.zig:3325` |
| `E_RETURN_TYPE_MISMATCH` | return expression must match the declared return type | `src/mir_verify_util.zig:96`<br>`src/mir_verify_util.zig:114`<br>`src/sema.zig:6699`<br>`src/sema.zig:6700`<br>`src/sema.zig:6701`<br>`src/sema.zig:6732`<br>_+3 more_ |
| `E_SAFE_MODULE_ADDRESS_OF` | \`#[safe_module]\` requires raw address-taking with \`&amp;\` to be inside an \`unsafe\` block; use explicit \`borrow\` for scoped safe views | `src/sema.zig:3751` |
| `E_SAFE_MODULE_FFI_BOUNDARY` | \`#[safe_module]\` requires external ABI data symbols to be marked \`#[unsafe_ffi]\`; wrap audited FFI edges and expose a safe MC API<br>\`#[safe_module]\` requires external ABI declarations to be marked \`#[unsafe_ffi]\`; wrap audited FFI edges and expose a safe MC API | `src/sema.zig:1184`<br>`src/sema.zig:1213` |
| `E_SAFE_MODULE_POINTER_CAST` | \`#[safe_module]\` requires pointer-to-pointer casts that reinterpret storage to be inside an \`unsafe\` block; expose a typed wrapper or use scoped \`borrow\` | `src/sema.zig:7096` |
| `E_SAFE_MODULE_POINTER_DEREF` | \`#[safe_module]\` requires ordinary pointer dereference to be inside an \`unsafe\` block unless the pointer is derived from an explicit scoped \`borrow\`<br>\`#[safe_module]\` requires ordinary pointer field access to be inside an \`unsafe\` block unless the pointer is derived from an explicit scoped \`borrow\` | `src/sema.zig:4281`<br>`src/sema.zig:4311` |
| `E_SAFE_MODULE_RAW_POINTER` | \`#[safe_module]\` forbids raw-many pointer types outside an \`unsafe\` block; wrap the raw edge in an unsafe implementation and expose pointer/slice/owner types | `src/sema.zig:4452`<br>`src/sema.zig:6050` |
| `E_SECRET_BRANCH` | secret value cannot drive a branch or switch; this would leak it through control-flow timing — use declassify/reveal (unsafe) or a constant-time select<br>secret value cannot drive a loop condition; this would leak it through control-flow timing | `src/sema.zig:3187`<br>`src/sema.zig:7930` |
| `E_SECRET_DECLASSIFY` | casting a Secret&lt;T&gt; to a non-secret type declassifies it; use reveal/declassify inside unsafe | `src/sema.zig:7038` |
| `E_SECRET_INDEX` | secret value cannot be used as an array index; a secret-dependent memory access leaks it through the cache — declassify/reveal it first (unsafe) or use a constant-time table scan<br>secret value cannot offset a pointer; a secret-dependent memory access leaks it through the cache | `src/sema.zig:3867`<br>`src/sema.zig:4247` |
| `E_SERIAL_OPERATION` | _see source_ | `src/mir_verify_util.zig:146`<br>`src/sema.zig:4888` |
| `E_SIGNED_UNSIGNED_MIX` | signed and unsigned integers do not implicitly mix | `src/mir_verify_util.zig:158`<br>`src/sema.zig:7291` |
| `E_SLEEP_IN_ATOMIC` | calling a #[may_sleep] op from an #[irq_context] function (sleeping in interrupt) | `src/sema.zig:4100` |
| `E_STRUCT_LITERAL_MISSING_FIELD` | packed bits literal must initialize every field<br>struct literal must initialize every field | `src/mir_verify_util.zig:105`<br>`src/sema.zig:6345`<br>`src/sema.zig:6383` |
| `E_STRUCT_LITERAL_REQUIRES_TARGET` | struct literal requires an explicit struct target type | `src/sema.zig:3444` |
| `E_SWITCH_MULTI_BINDING_ARM` | switch arms with multiple patterns cannot introduce bindings | `src/mir_verify_util.zig:121`<br>`src/sema.zig:8150` |
| `E_SWITCH_RESULT_REQUIRED` | switch ok or err patterns require a Result value<br>switch ok(...) or err(...) binding requires a Result value | `src/mir_verify_util.zig:120`<br>`src/sema.zig:8125`<br>`src/sema.zig:8139` |
| `E_SWITCH_RESULT_TAG` | switch result binding supports only ok(...) or err(...)<br>switch result patterns support only ok or err tags | `src/mir_verify_util.zig:119`<br>`src/sema.zig:8123`<br>`src/sema.zig:8137` |
| `E_SYMBOLS_INTERNAL` | _see source_ | `src/main.zig:715` |
| `E_THREAD_MOVE_RESOURCE` | \`thread_move\` applies only to checked resource structs (\`move\`, \`linear\`, or an aggregate that stores a checked resource by value)<br>\`thread_move\` resource cannot contain a non-\`thread_move\` resource by value<br>resource transferred across a thread/task spawn boundary must be declared \`thread_move\` | `src/sema.zig:1299`<br>`src/sema.zig:1338`<br>`src/sema.zig:6894` |
| `E_TRAIT_BOUND_MEMBER` | generic type-parameter member calls require a \`where\` bound whose trait declares that member | `src/sema.zig:4409` |
| `E_TRAIT_EFFECT_MISMATCH` | impl method's effect annotations (#[may_sleep]) do not match the trait signature | `src/sema.zig:7770` |
| `E_TRAIT_INCOHERENT` | duplicate \`impl Trait for Type\` (coherence: at most one impl per (Trait, Type) pair) | `src/sema.zig:7718` |
| `E_TRAIT_MISSING_METHOD` | impl does not provide a trait method | `src/sema.zig:7751` |
| `E_TRAIT_NOT_OBJECT_SAFE` | trait is not object-safe (every method must take \`self\` by pointer and be non-generic) so it cannot be used as \`*dyn Trait\` | `src/sema.zig:4527` |
| `E_TRAIT_NOT_SATISFIED` | a \`*dyn Trait\` can only be formed from a concrete nominal type that implements the trait<br>no \`impl Trait for Type\` for this concrete type, so it cannot coerce to \`*dyn Trait\` | `src/monomorphize.zig:1002`<br>`src/sema.zig:6629`<br>`src/sema.zig:6633`<br>`src/sema.zig:6659` |
| `E_TRAIT_SELF_MODE_MISMATCH` | impl method's self-mode does not match the trait signature | `src/sema.zig:7755` |
| `E_TRAIT_SIGNATURE_MISMATCH` | impl method's parameter count does not match the trait signature<br>impl method's parameter type does not match the trait signature<br>impl method's return borrow source does not match the trait signature<br>_+1 more_ | `src/sema.zig:7796`<br>`src/sema.zig:7803`<br>`src/sema.zig:7813`<br>`src/sema.zig:7820` |
| `E_TRAIT_UNKNOWN_METHOD` | impl provides a method the trait does not declare | `src/sema.zig:7776` |
| `E_TRIVIAL_DROP_NOT_MOVE` | #[trivial_drop] applies only to a \`move struct\` or \`linear struct\` (it asserts the resource's completion needs no release) | `src/sema.zig:635` |
| `E_TRY_REQUIRES_RESULT_OR_NULLABLE` | postfix '?' requires a Result or nullable operand | `src/mir_verify_util.zig:111`<br>`src/sema.zig:3770` |
| `E_TYPE_ALIAS_CYCLE` | type aliases must not form recursive cycles | `src/sema.zig:788` |
| `E_TYPE_ARG_REQUIRED` | type parameter requires a known type argument<br>type parameter requires a type argument | `src/sema.zig:4120`<br>`src/sema.zig:4122` |
| `E_UNBOUNDED_INDIRECT_CALL` | a \`#[bounded]\` function may not dispatch through \`*dyn Trait\` (the callee's termination cannot be checked through the vtable)<br>a \`#[bounded]\` function may not make an indirect/closure call (the callee's termination cannot be checked through the closure)<br>a \`#[bounded]\` function may not make an indirect/fn-pointer call (the callee's termination cannot be checked through the pointer) | `src/sema.zig:4025`<br>`src/sema.zig:4037`<br>`src/sema.zig:4067` |
| `E_UNBOUNDED_LOOP` | loop in a bounded/IRQ-context function is not statically bounded (no monotone counter toward a bound, fixed-range for, or break) | `src/sema.zig:5426` |
| `E_UNBOUNDED_RECURSION` | direct recursion from a bounded/IRQ-context function (a kernel must not recurse unboundedly in interrupt/atomic context)<br>recursive direct-call cycle among bounded/IRQ-context functions (no decreasing metric is proven) | `src/sema.zig:5465`<br>`src/sema.zig:5561` |
| `E_UNCHECKED_OUTSIDE_CONTRACT` | MIR verifier found unchecked optimizer assumption outside matching contract region<br>unchecked operation requires matching #[unsafe_contract] | `src/mir.zig:1033`<br>`src/sema.zig:3952` |
| `E_UNHANDLED_RESULT` | Result defer cleanup must be handled or propagated<br>Result expression statements must be handled or propagated<br>Result local must be handled before reassignment<br>_+2 more_ | `src/mir_verify_util.zig:110`<br>`src/sema.zig:3152`<br>`src/sema.zig:3167`<br>`src/sema.zig:3170`<br>`src/sema.zig:3355`<br>`src/sema.zig:3364` |
| `E_UNINIT_REQUIRES_STORAGE` | uninit is valid only for explicit typed mutable storage initialization | `src/sema.zig:2124`<br>`src/sema.zig:3423`<br>`src/sema.zig:3583`<br>`src/sema.zig:6693`<br>`src/sema.zig:6800` |
| `E_UNINIT_RESOURCE_STORAGE` | \`uninit\` cannot create \`move\`/\`linear\`, \`region\`, or \`view struct\` storage; construct the resource with a typed initializer or keep raw bytes behind scalar storage | `src/sema.zig:3649` |
| `E_UNION_CASE_HAS_NO_PAYLOAD` | union case binding requires a payload case<br>union case has no payload type | `src/mir_verify_util.zig:130`<br>`src/sema.zig:6119`<br>`src/sema.zig:8134` |
| `E_UNKNOWN_ENUM_CASE` | enum has no case with this name | `src/mir_verify_util.zig:127`<br>`src/sema.zig:6992`<br>`src/sema.zig:8116` |
| `E_UNKNOWN_FUNCTION` | unknown function | `src/sema.zig:4377` |
| `E_UNKNOWN_IDENTIFIER` | asm output names an unknown local<br>unknown identifier<br>unknown identifier \`{s}\` | `src/diagnostics.zig:461`<br>`src/diagnostics.zig:469`<br>`src/diagnostics.zig:535`<br>`src/sema.zig:3288`<br>`src/sema.zig:4361` |
| `E_UNKNOWN_LOOP_LABEL` | break targets a loop label that is not in scope<br>continue targets a loop label that is not in scope | `src/sema.zig:3336`<br>`src/sema.zig:3348` |
| `E_UNKNOWN_STRUCT_FIELD` | layout type has no field with this name<br>member access requires a struct, packed-bits, or overlay-union value<br>packed bits type has no field with this name<br>_+1 more_ | `src/mir_verify_util.zig:104`<br>`src/sema.zig:6103`<br>`src/sema.zig:6115`<br>`src/sema.zig:6313`<br>`src/sema.zig:6367`<br>`src/sema.zig:7494`<br>_+1 more_ |
| `E_UNKNOWN_TRAIT` | unknown trait in \`*dyn Trait\`<br>unknown trait in impl | `src/sema.zig:4523`<br>`src/sema.zig:7743` |
| `E_UNKNOWN_TYPE` | enum literals are values, not runtime types<br>type members are not supported; this member does not resolve to a declared type<br>unknown generic type name<br>_+1 more_ | `src/sema.zig:4435`<br>`src/sema.zig:4441`<br>`src/sema.zig:4443`<br>`src/sema.zig:4484` |
| `E_UNKNOWN_UNION_CASE` | union has no case with this name | `src/mir_verify_util.zig:129`<br>`src/sema.zig:6922`<br>`src/sema.zig:6963`<br>`src/sema.zig:8120`<br>`src/sema.zig:8132` |
| `E_UNSAFE_REQUIRED` | MIR verifier found unsafe machine effect outside unsafe context<br>a \`#[unsafe_ffi]\` boundary cannot be converted to a plain function pointer; wrap it in an audited safe MC function<br>a \`#[unsafe_ffi]\` boundary cannot be inferred as a plain function pointer; wrap it in an audited safe MC function<br>_+16 more_ | `src/mir.zig:1040`<br>`src/sema.zig:3269`<br>`src/sema.zig:3956`<br>`src/sema.zig:3963`<br>`src/sema.zig:4075`<br>`src/sema.zig:4205`<br>_+17 more_ |
| `E_UNSIGNED_NEGATION` | unsigned checked integers do not support unary '-' | `src/mir_verify_util.zig:153`<br>`src/sema.zig:3786` |
| `E_UNUSED_MOVE_RESULT` | the linear \`move\` result of this expression is discarded; bind it with \`let\`, return it, or pass it to a consuming function | `src/sema_move.zig:809` |
| `E_USERPTR_CAST_DEREF` | casting a UserPtr&lt;T&gt; to a derefable kernel pointer bypasses uaccess validation; only UserPtr&lt;-&gt;usize is permitted | `src/sema.zig:7045` |
| `E_USER_PTR_DEREF` | cannot directly access a field through UserPtr; copy it in with copy_from_user first | `src/mir_verify_util.zig:171`<br>`src/sema.zig:4317`<br>`src/sema.zig:9407` |
| `E_USE_AFTER_MOVE` | borrow of linear \`move\` array element after it was moved out<br>borrow of linear \`move\` field after it was moved out<br>borrow of linear \`move\` place after one of its child places was moved out<br>_+31 more_ | `src/sema_move.zig:972`<br>`src/sema_move.zig:1031`<br>`src/sema_move.zig:1053`<br>`src/sema_move.zig:1062`<br>`src/sema_move.zig:2859`<br>`src/sema_move.zig:2874`<br>_+45 more_ |
| `E_USE_BEFORE_INIT` | variable initialized with \`uninit\` is read before it is definitely initialized on all paths | `src/sema.zig:2775` |
| `E_VADDR_DEREF` | _see source_ | `src/mir_verify_util.zig:169`<br>`src/sema.zig:9405` |
| `E_VA_RESOURCE_PAYLOAD` | C variadic tail arguments cannot pass \`move\`/\`linear\`, \`region\`, or \`view struct\` resources by value; pass a copyable ABI handle or pointer through an audited wrapper<br>va.arg cannot materialize \`move\`/\`linear\`, \`region\`, or \`view struct\` resources from an untracked C varargs cursor; pass a copyable ABI value or explicit handle instead | `src/sema.zig:4163`<br>`src/sema.zig:5051` |
| `E_VA_START_CONTEXT` | va.start is only valid inside a variadic function | `src/sema.zig:5026` |
| `E_VOID_RETURNS_VALUE` | function declared -&gt; void cannot return a value | `src/sema.zig:3318` |
| `E_VOID_STORAGE` | void is only valid as a function return type or generic marker | `src/sema.zig:4431`<br>`src/sema.zig:4613` |
