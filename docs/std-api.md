# MC standard library API

This file is generated from public declarations in `std/**/*.mc`.
Regenerate it with:

```sh
python3 tools/toolchain/std-api-docs.py --write
```

The extractor is static: it records `pub`/`export` function signatures, public constants,
public type declarations, and local types named by public declarations.

Total modules: **40**.
Total public functions: **341**.
Total public constants: **6**.
Total public type declarations: **24**.
Total referenced local types: **31**.

## Modules

## `std/addr`

Source: `std/addr.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct PhysRange</code> | `std/addr.mc:83` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn pa(value: usize) -&gt; PAddr</code> | `std/addr.mc:19` |
| <code>export fn pa_value(a: PAddr) -&gt; usize</code> | `std/addr.mc:24` |
| <code>export fn pa_offset(a: PAddr, n: usize) -&gt; PAddr</code> | `std/addr.mc:31` |
| <code>export fn pa_diff(from: PAddr, to: PAddr) -&gt; usize</code> | `std/addr.mc:36` |
| <code>export fn pa_is_aligned(a: PAddr, align: usize) -&gt; bool</code> | `std/addr.mc:42` |
| <code>export fn pa_align_down(a: PAddr, align: usize) -&gt; PAddr</code> | `std/addr.mc:46` |
| <code>export fn pa_align_up(a: PAddr, align: usize) -&gt; PAddr</code> | `std/addr.mc:57` |
| <code>export fn pa_lt(a: PAddr, b: PAddr) -&gt; bool</code> | `std/addr.mc:71` |
| <code>export fn pa_le(a: PAddr, b: PAddr) -&gt; bool</code> | `std/addr.mc:74` |
| <code>export fn pa_eq(a: PAddr, b: PAddr) -&gt; bool</code> | `std/addr.mc:77` |
| <code>export fn pr_start(r: *PhysRange) -&gt; PAddr</code> | `std/addr.mc:93` |
| <code>export fn pr_end(r: *PhysRange) -&gt; PAddr</code> | `std/addr.mc:97` |
| <code>export fn pr_len(r: *PhysRange) -&gt; usize</code> | `std/addr.mc:101` |
| <code>export fn pr_contains(r: *PhysRange, a: PAddr) -&gt; bool</code> | `std/addr.mc:106` |
| <code>export fn va(value: usize) -&gt; VAddr</code> | `std/addr.mc:117` |
| <code>export fn va_value(a: VAddr) -&gt; usize</code> | `std/addr.mc:124` |
| <code>export fn va_offset(a: VAddr, n: usize) -&gt; VAddr</code> | `std/addr.mc:128` |
| <code>export fn va_diff(from: VAddr, to: VAddr) -&gt; usize</code> | `std/addr.mc:133` |
| <code>export fn va_is_aligned(a: VAddr, align: usize) -&gt; bool</code> | `std/addr.mc:137` |
| <code>export fn va_align_down(a: VAddr, align: usize) -&gt; VAddr</code> | `std/addr.mc:147` |
| <code>export fn va_align_up(a: VAddr, align: usize) -&gt; VAddr</code> | `std/addr.mc:158` |
| <code>export fn va_lt(a: VAddr, b: VAddr) -&gt; bool</code> | `std/addr.mc:170` |
| <code>export fn va_le(a: VAddr, b: VAddr) -&gt; bool</code> | `std/addr.mc:173` |
| <code>export fn va_eq(a: VAddr, b: VAddr) -&gt; bool</code> | `std/addr.mc:176` |

## `std/alloc/alloc`

Source: `std/alloc/alloc.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>trait Allocator</code> | `std/alloc/alloc.mc:13` |

### Public types

| Signature | Source |
|---|---|
| <code>pub move struct Owned&lt;T&gt;</code> | `std/alloc/alloc.mc:44` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn alloc_bytes(a: *mut dyn Allocator, size: usize, align: usize) -&gt; PAddr</code> | `std/alloc/alloc.mc:23` |
| <code>pub fn free_bytes(a: *mut dyn Allocator, addr: PAddr, size: usize) -&gt; void</code> | `std/alloc/alloc.mc:28` |
| <code>pub fn create(comptime T: type, a: *mut dyn Allocator) -&gt; Owned&lt;T&gt;</code> | `std/alloc/alloc.mc:50` |
| <code>pub fn own_addr(comptime T: type, o: *Owned&lt;T&gt;) -&gt; PAddr</code> | `std/alloc/alloc.mc:55` |
| <code>pub fn own_free(comptime T: type, o: Owned&lt;T&gt;) -&gt; void</code> | `std/alloc/alloc.mc:62` |

## `std/alloc/arena`

Source: `std/alloc/arena.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub move struct Arena</code> | `std/alloc/arena.mc:13` |
| <code>pub opaque struct GenRef&lt;T&gt;</code> | `std/alloc/arena.mc:105` |
| <code>pub enum ArenaError</code> | `std/alloc/arena.mc:122` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn arena_init(region: PhysRange) -&gt; Arena</code> | `std/alloc/arena.mc:22` |
| <code>pub fn arena_alloc(a: *mut Arena, size: usize, align: usize) -&gt; PAddr</code> | `std/alloc/arena.mc:29` |
| <code>pub fn arena_reset(a: *mut Arena) -&gt; void</code> | `std/alloc/arena.mc:43` |
| <code>pub fn arena_available(a: *mut Arena) -&gt; usize</code> | `std/alloc/arena.mc:49` |
| <code>pub fn arena_destroy(a: Arena) -&gt; void</code> | `std/alloc/arena.mc:55` |
| <code>pub fn arena_allocator(a: *mut Arena) -&gt; *mut dyn Allocator</code> | `std/alloc/arena.mc:89` |
| <code>pub fn arena_alloc_gen(comptime T: type, a: *mut Arena, size: usize, align: usize) -&gt; GenRef&lt;T&gt;</code> | `std/alloc/arena.mc:129` |
| <code>pub fn arena_resolve(comptime T: type, a: *mut Arena, h: GenRef&lt;T&gt;) -&gt; Result&lt;PAddr, ArenaError&gt;</code> | `std/alloc/arena.mc:144` |

## `std/alloc/dma`

Source: `std/alloc/dma.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub move struct CpuBuffer</code> | `std/alloc/dma.mc:15` |
| <code>pub move struct DeviceBuffer</code> | `std/alloc/dma.mc:21` |
| <code>pub enum DmaError</code> | `std/alloc/dma.mc:37` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn alloc(len: usize) -&gt; CpuBuffer</code> | `std/alloc/dma.mc:42` |
| <code>pub fn try_alloc(len: usize) -&gt; Result&lt;CpuBuffer, DmaError&gt;</code> | `std/alloc/dma.mc:53` |
| <code>pub fn free(b: CpuBuffer) -&gt; void</code> | `std/alloc/dma.mc:65` |
| <code>pub fn clean_for_device(b: CpuBuffer) -&gt; DeviceBuffer</code> | `std/alloc/dma.mc:75` |
| <code>pub fn invalidate_for_cpu(b: DeviceBuffer) -&gt; CpuBuffer</code> | `std/alloc/dma.mc:86` |
| <code>pub fn device_addr(b: *DeviceBuffer) -&gt; DmaAddr</code> | `std/alloc/dma.mc:96` |
| <code>pub fn cpu_addr(b: *CpuBuffer) -&gt; PAddr</code> | `std/alloc/dma.mc:102` |
| <code>pub fn cpu_len(b: *CpuBuffer) -&gt; usize</code> | `std/alloc/dma.mc:106` |
| <code>pub fn write_u8(b: *CpuBuffer, offset: usize, value: u8) -&gt; void</code> | `std/alloc/dma.mc:131` |
| <code>pub fn read_u8(b: *CpuBuffer, offset: usize) -&gt; u8</code> | `std/alloc/dma.mc:140` |
| <code>pub fn write_be16(b: *CpuBuffer, offset: usize, value: u16) -&gt; void</code> | `std/alloc/dma.mc:149` |
| <code>pub fn read_be16(b: *CpuBuffer, offset: usize) -&gt; u16</code> | `std/alloc/dma.mc:155` |
| <code>pub fn write_be32(b: *CpuBuffer, offset: usize, value: u32) -&gt; void</code> | `std/alloc/dma.mc:161` |
| <code>pub fn read_be32(b: *CpuBuffer, offset: usize) -&gt; u32</code> | `std/alloc/dma.mc:169` |
| <code>pub fn write_le16(b: *CpuBuffer, offset: usize, value: u16) -&gt; void</code> | `std/alloc/dma.mc:179` |
| <code>pub fn write_le32(b: *CpuBuffer, offset: usize, value: u32) -&gt; void</code> | `std/alloc/dma.mc:185` |
| <code>pub fn write_le64(b: *CpuBuffer, offset: usize, value: u64) -&gt; void</code> | `std/alloc/dma.mc:193` |
| <code>pub fn read_le32(b: *CpuBuffer, offset: usize) -&gt; u32</code> | `std/alloc/dma.mc:199` |

## `std/alloc/pool`

Source: `std/alloc/pool.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct Pool&lt;T, N&gt;</code> | `std/alloc/pool.mc:12` |
| <code>pub opaque struct PoolRef&lt;T&gt;</code> | `std/alloc/pool.mc:23` |
| <code>pub enum PoolError</code> | `std/alloc/pool.mc:40` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn pool_init(comptime T: type, comptime N: usize, p: *mut Pool&lt;T, N&gt;) -&gt; void</code> | `std/alloc/pool.mc:46` |
| <code>pub fn pool_alloc(comptime T: type, comptime N: usize, p: *mut Pool&lt;T, N&gt;) -&gt; Result&lt;PoolRef&lt;T&gt;, PoolError&gt;</code> | `std/alloc/pool.mc:58` |
| <code>pub fn pool_free(comptime T: type, comptime N: usize, p: *mut Pool&lt;T, N&gt;, r: PoolRef&lt;T&gt;) -&gt; Result&lt;bool, PoolError&gt;</code> | `std/alloc/pool.mc:74` |
| <code>pub fn pool_set(comptime T: type, comptime N: usize, p: *mut Pool&lt;T, N&gt;, r: PoolRef&lt;T&gt;, value: T) -&gt; Result&lt;bool, PoolError&gt;</code> | `std/alloc/pool.mc:97` |
| <code>pub fn pool_load(comptime T: type, comptime N: usize, p: *mut Pool&lt;T, N&gt;, r: PoolRef&lt;T&gt;) -&gt; Result&lt;T, PoolError&gt;</code> | `std/alloc/pool.mc:115` |

## `std/ascii`

Source: `std/ascii.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn is_digit(c: u8) -&gt; bool</code> | `std/ascii.mc:5` |
| <code>export const fn is_upper(c: u8) -&gt; bool</code> | `std/ascii.mc:9` |
| <code>export const fn is_lower(c: u8) -&gt; bool</code> | `std/ascii.mc:13` |
| <code>export const fn is_alpha(c: u8) -&gt; bool</code> | `std/ascii.mc:17` |
| <code>export const fn is_alnum(c: u8) -&gt; bool</code> | `std/ascii.mc:21` |
| <code>export const fn is_whitespace(c: u8) -&gt; bool</code> | `std/ascii.mc:25` |
| <code>export const fn to_upper(c: u8) -&gt; u8</code> | `std/ascii.mc:30` |
| <code>export const fn to_lower(c: u8) -&gt; u8</code> | `std/ascii.mc:38` |
| <code>export const fn digit_value(c: u8) -&gt; u32</code> | `std/ascii.mc:46` |

## `std/bits`

Source: `std/bits.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn count_ones(x: u32) -&gt; u32</code> | `std/bits.mc:7` |
| <code>export const fn is_aligned(x: usize, a: usize) -&gt; bool</code> | `std/bits.mc:18` |
| <code>export const fn low_mask(bits: u32) -&gt; u32</code> | `std/bits.mc:23` |
| <code>export const fn is_single_bit(x: u32) -&gt; bool</code> | `std/bits.mc:31` |
| <code>export const fn next_power_of_two(x: u32) -&gt; u32</code> | `std/bits.mc:36` |
| <code>export const fn trailing_zeros(x: u32) -&gt; u32</code> | `std/bits.mc:45` |
| <code>export const fn is_even(x: u32) -&gt; bool</code> | `std/bits.mc:60` |
| <code>export const fn is_odd(x: u32) -&gt; bool</code> | `std/bits.mc:64` |

## `std/bytes`

Source: `std/bytes.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct ByteReader</code> | `std/bytes.mc:28` |
| <code>pub enum BytesError</code> | `std/bytes.mc:35` |
| <code>pub struct ByteWriter</code> | `std/bytes.mc:214` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn byte_reader(base: PAddr, len: usize) -&gt; ByteReader</code> | `std/bytes.mc:39` |
| <code>pub fn br_len(r: *ByteReader) -&gt; usize</code> | `std/bytes.mc:43` |
| <code>pub fn br_has(r: *ByteReader, off: usize, n: usize) -&gt; bool</code> | `std/bytes.mc:48` |
| <code>pub fn br_u8(r: *ByteReader, off: usize) -&gt; u8</code> | `std/bytes.mc:62` |
| <code>pub fn br_le16(r: *ByteReader, off: usize) -&gt; u16</code> | `std/bytes.mc:69` |
| <code>pub fn br_le32(r: *ByteReader, off: usize) -&gt; u32</code> | `std/bytes.mc:75` |
| <code>pub fn br_le64(r: *ByteReader, off: usize) -&gt; u64</code> | `std/bytes.mc:83` |
| <code>pub fn br_be16(r: *ByteReader, off: usize) -&gt; u16</code> | `std/bytes.mc:89` |
| <code>pub fn br_be32(r: *ByteReader, off: usize) -&gt; u32</code> | `std/bytes.mc:95` |
| <code>pub fn br_try_u8(r: *ByteReader, off: usize) -&gt; Result&lt;u8, BytesError&gt;</code> | `std/bytes.mc:118` |
| <code>pub fn br_try_be16(r: *ByteReader, off: usize) -&gt; Result&lt;u16, BytesError&gt;</code> | `std/bytes.mc:125` |
| <code>pub fn br_try_be32(r: *ByteReader, off: usize) -&gt; Result&lt;u32, BytesError&gt;</code> | `std/bytes.mc:134` |
| <code>pub fn br_try_le16(r: *ByteReader, off: usize) -&gt; Result&lt;u16, BytesError&gt;</code> | `std/bytes.mc:145` |
| <code>pub fn br_try_le32(r: *ByteReader, off: usize) -&gt; Result&lt;u32, BytesError&gt;</code> | `std/bytes.mc:154` |
| <code>pub fn br_try_le64(r: *ByteReader, off: usize) -&gt; Result&lt;u64, BytesError&gt;</code> | `std/bytes.mc:165` |
| <code>pub fn br_validate_len(r: *ByteReader, off: usize, claimed: usize) -&gt; Result&lt;usize, BytesError&gt;</code> | `std/bytes.mc:191` |
| <code>pub fn br_copy_to(r: *ByteReader, off: usize, dst: PAddr, n: usize) -&gt; void</code> | `std/bytes.mc:201` |
| <code>pub fn byte_writer(base: PAddr, len: usize) -&gt; ByteWriter</code> | `std/bytes.mc:219` |
| <code>pub fn bw_u8(w: *ByteWriter, off: usize, value: u8) -&gt; void</code> | `std/bytes.mc:233` |
| <code>pub fn bw_be16(w: *ByteWriter, off: usize, value: u16) -&gt; void</code> | `std/bytes.mc:240` |
| <code>pub fn bw_be32(w: *ByteWriter, off: usize, value: u32) -&gt; void</code> | `std/bytes.mc:246` |

## `std/byteview`

Source: `std/byteview.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct ByteBuf&lt;N&gt;</code> | `std/byteview.mc:18` |
| <code>enum ByteError</code> | `std/byteview.mc:23` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn bytebuf_init(comptime N: usize, b: *mut ByteBuf&lt;N&gt;) -&gt; void</code> | `std/byteview.mc:27` |
| <code>export fn bytebuf_len(comptime N: usize, b: *mut ByteBuf&lt;N&gt;) -&gt; usize</code> | `std/byteview.mc:30` |
| <code>export fn bytebuf_set(comptime N: usize, b: *mut ByteBuf&lt;N&gt;, i: usize, v: u8) -&gt; Result&lt;bool, ByteError&gt;</code> | `std/byteview.mc:36` |
| <code>export fn bytebuf_get(comptime N: usize, b: *mut ByteBuf&lt;N&gt;, i: usize) -&gt; u8</code> | `std/byteview.mc:48` |
| <code>export fn bytebuf_copy_from(comptime N: usize, b: *mut ByteBuf&lt;N&gt;, src: PAddr, n: usize) -&gt; Result&lt;usize, ByteError&gt;</code> | `std/byteview.mc:57` |
| <code>export fn bytebuf_copy_to(comptime N: usize, b: *mut ByteBuf&lt;N&gt;, dst: PAddr, n: usize) -&gt; Result&lt;usize, ByteError&gt;</code> | `std/byteview.mc:68` |

## `std/canary`

Source: `std/canary.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct StackGuard</code> | `std/canary.mc:21` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn guard_new() -&gt; StackGuard</code> | `std/canary.mc:27` |
| <code>export fn guard_ok(g: *StackGuard) -&gt; bool</code> | `std/canary.mc:32` |
| <code>export fn guard_check(g: *StackGuard) -&gt; void</code> | `std/canary.mc:39` |
| <code>export fn guard_smash(g: *mut StackGuard) -&gt; void</code> | `std/canary.mc:48` |

## `std/collections/arc`

Source: `std/collections/arc.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct ArcBlock&lt;T&gt;</code> | `std/collections/arc.mc:16` |
| <code>pub move struct Arc&lt;T&gt;</code> | `std/collections/arc.mc:25` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn arc_new(comptime T: type, a: *mut dyn Allocator, value: T) -&gt; Arc&lt;T&gt;</code> | `std/collections/arc.mc:31` |
| <code>pub fn arc_new_uninit(comptime T: type, a: *mut dyn Allocator) -&gt; Arc&lt;T&gt;</code> | `std/collections/arc.mc:41` |
| <code>pub fn arc_clone(comptime T: type, h: *Arc&lt;T&gt;) -&gt; Arc&lt;T&gt;</code> | `std/collections/arc.mc:50` |
| <code>pub fn arc_get(comptime T: type, h: *Arc&lt;T&gt;) -&gt; *const T</code> | `std/collections/arc.mc:70` |
| <code>pub fn arc_get_mut(comptime T: type, h: *Arc&lt;T&gt;) -&gt; *mut T</code> | `std/collections/arc.mc:83` |
| <code>pub fn arc_count(comptime T: type, h: *Arc&lt;T&gt;) -&gt; u32</code> | `std/collections/arc.mc:92` |
| <code>pub fn arc_drop(comptime T: type, h: Arc&lt;T&gt;) -&gt; bool</code> | `std/collections/arc.mc:100` |

## `std/collections/dynarray`

Source: `std/collections/dynarray.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct Vec&lt;T&gt;</code> | `std/collections/dynarray.mc:33` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn vec_new(comptime T: type, a: *mut dyn Allocator) -&gt; Vec&lt;T&gt;</code> | `std/collections/dynarray.mc:41` |
| <code>export fn vec_len(comptime T: type, v: *Vec&lt;T&gt;) -&gt; usize</code> | `std/collections/dynarray.mc:46` |
| <code>export fn vec_push(comptime T: type, v: *mut Vec&lt;T&gt;, x: T) -&gt; void</code> | `std/collections/dynarray.mc:80` |
| <code>export fn vec_get(comptime T: type, v: *Vec&lt;T&gt;, i: usize) -&gt; T</code> | `std/collections/dynarray.mc:90` |
| <code>export fn vec_set(comptime T: type, v: *mut Vec&lt;T&gt;, i: usize, x: T) -&gt; void</code> | `std/collections/dynarray.mc:103` |
| <code>export fn vec_pop(comptime T: type, v: *mut Vec&lt;T&gt;) -&gt; T</code> | `std/collections/dynarray.mc:114` |
| <code>export fn vec_clear(comptime T: type, v: *mut Vec&lt;T&gt;) -&gt; void</code> | `std/collections/dynarray.mc:128` |
| <code>export fn vec_free(comptime T: type, v: *mut Vec&lt;T&gt;) -&gt; void</code> | `std/collections/dynarray.mc:134` |

## `std/collections/hashmap`

Source: `std/collections/hashmap.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct StrHashMap&lt;V&gt;</code> | `std/collections/hashmap.mc:52` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn strmap_new(comptime V: type, a: *mut dyn Allocator) -&gt; StrHashMap&lt;V&gt;</code> | `std/collections/hashmap.mc:147` |
| <code>export fn strmap_len(comptime V: type, m: *StrHashMap&lt;V&gt;) -&gt; usize</code> | `std/collections/hashmap.mc:152` |
| <code>export fn strmap_put(comptime V: type, m: *mut StrHashMap&lt;V&gt;, key: []const u8, val: V) -&gt; void</code> | `std/collections/hashmap.mc:158` |
| <code>export fn strmap_get(comptime V: type, m: *StrHashMap&lt;V&gt;, key: []const u8) -&gt; ?*mut V</code> | `std/collections/hashmap.mc:177` |
| <code>export fn strmap_get_or(comptime V: type, m: *StrHashMap&lt;V&gt;, key: []const u8, fallback: V) -&gt; V</code> | `std/collections/hashmap.mc:197` |
| <code>export fn strmap_contains(comptime V: type, m: *StrHashMap&lt;V&gt;, key: []const u8) -&gt; bool</code> | `std/collections/hashmap.mc:210` |
| <code>export fn strmap_del(comptime V: type, m: *mut StrHashMap&lt;V&gt;, key: []const u8) -&gt; void</code> | `std/collections/hashmap.mc:224` |
| <code>export fn strmap_free(comptime V: type, m: *mut StrHashMap&lt;V&gt;) -&gt; void</code> | `std/collections/hashmap.mc:269` |

## `std/collections/ring`

Source: `std/collections/ring.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct Ring&lt;T, N&gt;</code> | `std/collections/ring.mc:12` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn ring_init(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; void</code> | `std/collections/ring.mc:21` |
| <code>export fn ring_len(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; usize</code> | `std/collections/ring.mc:27` |
| <code>export fn ring_is_empty(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; bool</code> | `std/collections/ring.mc:31` |
| <code>export fn ring_is_full(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; bool</code> | `std/collections/ring.mc:34` |
| <code>export fn ring_push(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;, x: T) -&gt; bool</code> | `std/collections/ring.mc:39` |
| <code>export fn ring_front(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; T</code> | `std/collections/ring.mc:50` |
| <code>export fn ring_pop(comptime T: type, comptime N: usize, r: *mut Ring&lt;T, N&gt;) -&gt; T</code> | `std/collections/ring.mc:59` |

## `std/collections/slotmap`

Source: `std/collections/slotmap.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct SlotMap&lt;T, N&gt;</code> | `std/collections/slotmap.mc:15` |
| <code>pub enum SlotError</code> | `std/collections/slotmap.mc:21` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn slotmap_init(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;) -&gt; void</code> | `std/collections/slotmap.mc:26` |
| <code>pub fn slotmap_alloc(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;) -&gt; Result&lt;usize, SlotError&gt;</code> | `std/collections/slotmap.mc:36` |
| <code>pub fn slotmap_alloc_at(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;, h: usize) -&gt; Result&lt;usize, SlotError&gt;</code> | `std/collections/slotmap.mc:52` |
| <code>pub fn slotmap_live(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;, h: usize) -&gt; bool</code> | `std/collections/slotmap.mc:64` |
| <code>pub fn slotmap_set(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;, h: usize, value: T) -&gt; Result&lt;bool, SlotError&gt;</code> | `std/collections/slotmap.mc:72` |
| <code>pub fn slotmap_get(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;, h: usize) -&gt; Result&lt;T, SlotError&gt;</code> | `std/collections/slotmap.mc:81` |
| <code>pub fn slotmap_free(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;, h: usize) -&gt; Result&lt;bool, SlotError&gt;</code> | `std/collections/slotmap.mc:89` |
| <code>pub fn slotmap_count(comptime T: type, comptime N: usize, m: *mut SlotMap&lt;T, N&gt;) -&gt; usize</code> | `std/collections/slotmap.mc:98` |

## `std/collections/vec`

Source: `std/collections/vec.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn f32x4_splat(x: f32) -&gt; [4]f32</code> | `std/collections/vec.mc:11` |
| <code>export fn f32x4_load(base: PAddr) -&gt; [4]f32</code> | `std/collections/vec.mc:15` |
| <code>export fn f32x4_store(base: PAddr, values: [4]f32) -&gt; void</code> | `std/collections/vec.mc:26` |
| <code>export fn f32x4_add(a: [4]f32, b: [4]f32) -&gt; [4]f32</code> | `std/collections/vec.mc:35` |
| <code>export fn f32x4_mul(a: [4]f32, b: [4]f32) -&gt; [4]f32</code> | `std/collections/vec.mc:39` |
| <code>export fn f32x4_max(a: [4]f32, b: [4]f32) -&gt; [4]f32</code> | `std/collections/vec.mc:48` |
| <code>export fn f32x4_sum(values: [4]f32) -&gt; f32</code> | `std/collections/vec.mc:57` |
| <code>export fn f32x4_to_bits(values: [4]f32) -&gt; [4]u32</code> | `std/collections/vec.mc:61` |
| <code>export fn f32x4_from_bits(values: [4]u32) -&gt; [4]f32</code> | `std/collections/vec.mc:70` |

## `std/core`

Source: `std/core.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn min_u32(a: u32, b: u32) -&gt; u32</code> | `std/core.mc:13` |
| <code>export const fn max_u32(a: u32, b: u32) -&gt; u32</code> | `std/core.mc:20` |
| <code>export const fn clamp_u32(x: u32, lo: u32, hi: u32) -&gt; u32</code> | `std/core.mc:27` |
| <code>export const fn min_usize(a: usize, b: usize) -&gt; usize</code> | `std/core.mc:31` |
| <code>export const fn max_usize(a: usize, b: usize) -&gt; usize</code> | `std/core.mc:38` |
| <code>export const fn is_power_of_two(x: usize) -&gt; bool</code> | `std/core.mc:46` |
| <code>export const fn align_up(x: usize, a: usize) -&gt; usize</code> | `std/core.mc:51` |
| <code>export const fn align_down(x: usize, a: usize) -&gt; usize</code> | `std/core.mc:56` |

## `std/endian`

Source: `std/endian.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn swap_u16(x: u16) -&gt; u16</code> | `std/endian.mc:6` |
| <code>export const fn swap_u32(x: u32) -&gt; u32</code> | `std/endian.mc:10` |
| <code>export const fn swap_u64(x: u64) -&gt; u64</code> | `std/endian.mc:17` |
| <code>export const fn to_be16(x: u16) -&gt; u16</code> | `std/endian.mc:33` |
| <code>export const fn from_be16(x: u16) -&gt; u16</code> | `std/endian.mc:34` |
| <code>export const fn to_be32(x: u32) -&gt; u32</code> | `std/endian.mc:35` |
| <code>export const fn from_be32(x: u32) -&gt; u32</code> | `std/endian.mc:36` |
| <code>export const fn to_be64(x: u64) -&gt; u64</code> | `std/endian.mc:37` |
| <code>export const fn from_be64(x: u64) -&gt; u64</code> | `std/endian.mc:38` |
| <code>export const fn to_le16(x: u16) -&gt; u16</code> | `std/endian.mc:40` |
| <code>export const fn from_le16(x: u16) -&gt; u16</code> | `std/endian.mc:41` |
| <code>export const fn to_le32(x: u32) -&gt; u32</code> | `std/endian.mc:42` |
| <code>export const fn from_le32(x: u32) -&gt; u32</code> | `std/endian.mc:43` |
| <code>export const fn to_le64(x: u64) -&gt; u64</code> | `std/endian.mc:44` |
| <code>export const fn from_le64(x: u64) -&gt; u64</code> | `std/endian.mc:45` |

## `std/fmt/fmt`

Source: `std/fmt/fmt.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn digit_char(d: u32) -&gt; u8</code> | `std/fmt/fmt.mc:21` |

## `std/grant`

Source: `std/grant.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct Grant</code> | `std/grant.mc:15` |
| <code>pub struct GrantRef</code> | `std/grant.mc:25` |
| <code>pub enum GrantError</code> | `std/grant.mc:31` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn grant_make(base: PAddr, len: usize) -&gt; Grant</code> | `std/grant.mc:50` |
| <code>pub fn grant_make_gen(base: PAddr, len: usize, gen: u32) -&gt; Grant</code> | `std/grant.mc:58` |
| <code>pub fn grant_ref(g: *Grant) -&gt; GrantRef</code> | `std/grant.mc:63` |
| <code>pub fn grant_revoke(g: *mut Grant) -&gt; void</code> | `std/grant.mc:70` |
| <code>pub fn grant_open(g: *Grant, r: GrantRef) -&gt; Result&lt;bool, GrantError&gt;</code> | `std/grant.mc:75` |
| <code>pub fn grant_copy_out(g: *Grant, r: GrantRef, off: usize, dst: PAddr, n: usize) -&gt; Result&lt;bool, GrantError&gt;</code> | `std/grant.mc:83` |
| <code>pub fn grant_copy_in(g: *Grant, r: GrantRef, off: usize, src: PAddr, n: usize) -&gt; Result&lt;bool, GrantError&gt;</code> | `std/grant.mc:100` |

## `std/hosted_args`

Source: `std/hosted_args.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn args_count() -&gt; i32</code> | `std/hosted_args.mc:42` |
| <code>export fn arg_len(i: i32) -&gt; usize</code> | `std/hosted_args.mc:48` |
| <code>export fn arg(i: i32) -&gt; ByteReader</code> | `std/hosted_args.mc:56` |
| <code>export fn arg_byte(i: i32, j: usize) -&gt; u8</code> | `std/hosted_args.mc:63` |
| <code>export fn arg_eq(i: i32, expected: *const u8) -&gt; bool</code> | `std/hosted_args.mc:70` |

## `std/hosted_io`

Source: `std/hosted_io.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct Fd</code> | `std/hosted_io.mc:24` |
| <code>enum IoError</code> | `std/hosted_io.mc:62` |

### Public constants

| Signature | Source |
|---|---|
| <code>export const O_RDONLY: i32 = 0;</code> | `std/hosted_io.mc:38` |
| <code>export const O_WRONLY: i32 = 1;</code> | `std/hosted_io.mc:39` |
| <code>export const O_RDWR: i32 = 2;</code> | `std/hosted_io.mc:40` |
| <code>export const O_CREAT: i32 = 64;</code> | `std/hosted_io.mc:41` |
| <code>export const O_TRUNC: i32 = 512;</code> | `std/hosted_io.mc:42` |
| <code>export const MODE_0644: i32 = 420;</code> | `std/hosted_io.mc:45` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn fd_raw(f: Fd) -&gt; i32</code> | `std/hosted_io.mc:28` |
| <code>export fn stdin_fd() -&gt; Fd</code> | `std/hosted_io.mc:32` |
| <code>export fn stdout_fd() -&gt; Fd</code> | `std/hosted_io.mc:33` |
| <code>export fn stderr_fd() -&gt; Fd</code> | `std/hosted_io.mc:34` |
| <code>export fn io_open(path: *const u8, flags: i32, mode: i32) -&gt; Result&lt;Fd, IoError&gt;</code> | `std/hosted_io.mc:88` |
| <code>export fn io_read(f: Fd, buf: PAddr, n: usize) -&gt; Result&lt;usize, IoError&gt;</code> | `std/hosted_io.mc:100` |
| <code>export fn io_write(f: Fd, buf: PAddr, n: usize) -&gt; Result&lt;usize, IoError&gt;</code> | `std/hosted_io.mc:115` |
| <code>export fn io_write_all(f: Fd, buf: PAddr, n: usize) -&gt; Result&lt;usize, IoError&gt;</code> | `std/hosted_io.mc:129` |
| <code>export fn io_close(f: Fd) -&gt; Result&lt;bool, IoError&gt;</code> | `std/hosted_io.mc:147` |
| <code>export fn io_printf_f64(f: Fd, fmt: *const u8, value: f64) -&gt; Result&lt;usize, IoError&gt;</code> | `std/hosted_io.mc:159` |

## `std/libc`

Source: `std/libc.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn mc_memeq(a: PAddr, b: PAddr, n: usize) -&gt; bool</code> | `std/libc.mc:6` |
| <code>export fn mc_strlen(s: PAddr) -&gt; usize</code> | `std/libc.mc:23` |
| <code>export fn mc_atoi(s: PAddr, n: usize) -&gt; u32</code> | `std/libc.mc:41` |

## `std/mask`

Source: `std/mask.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct Mask32</code> | `std/mask.mc:8` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub fn mask32_zero() -&gt; Mask32</code> | `std/mask.mc:12` |
| <code>pub fn mask32_from(bits: u32) -&gt; Mask32</code> | `std/mask.mc:15` |
| <code>pub fn mask32_raw(m: *mut Mask32) -&gt; u32</code> | `std/mask.mc:18` |
| <code>pub fn mask32_set(m: *mut Mask32, b: u32) -&gt; void</code> | `std/mask.mc:23` |
| <code>pub fn mask32_clear(m: *mut Mask32, b: u32) -&gt; void</code> | `std/mask.mc:29` |
| <code>pub fn mask32_contains(m: *mut Mask32, b: u32) -&gt; bool</code> | `std/mask.mc:34` |
| <code>pub fn mask32_is_empty(m: *mut Mask32) -&gt; bool</code> | `std/mask.mc:41` |
| <code>pub fn mask32_take_first(m: *mut Mask32) -&gt; u32</code> | `std/mask.mc:46` |

## `std/math`

Source: `std/math.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export const fn gcd(a: u32, b: u32) -&gt; u32</code> | `std/math.mc:7` |
| <code>export const fn lcm(a: u32, b: u32) -&gt; u32</code> | `std/math.mc:19` |
| <code>export const fn pow_u32(base: u32, exp: u32) -&gt; u32</code> | `std/math.mc:28` |
| <code>export const fn ilog2(x: u32) -&gt; u32</code> | `std/math.mc:39` |
| <code>export const fn wrapping_add_u32(a: u32, b: u32) -&gt; u32</code> | `std/math.mc:52` |
| <code>export const fn wrapping_sub_u32(a: u32, b: u32) -&gt; u32</code> | `std/math.mc:57` |
| <code>export const fn wrapping_mul_u32(a: u32, b: u32) -&gt; u32</code> | `std/math.mc:65` |
| <code>export const fn wrapping_add_u16(a: u16, b: u16) -&gt; u16</code> | `std/math.mc:72` |
| <code>export const fn wrapping_shl_u32(x: u32, n: u32) -&gt; u32</code> | `std/math.mc:80` |

## `std/mathf`

Source: `std/mathf.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn sqrt_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:33` |
| <code>export fn sin_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:34` |
| <code>export fn cos_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:35` |
| <code>export fn exp2_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:36` |
| <code>export fn log2_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:37` |
| <code>export fn exp_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:38` |
| <code>export fn log_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:39` |
| <code>export fn tanh_f64(x: f64) -&gt; f64</code> | `std/mathf.mc:40` |
| <code>export fn sqrt_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:53` |
| <code>export fn sin_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:54` |
| <code>export fn cos_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:55` |
| <code>export fn exp2_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:56` |
| <code>export fn log2_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:57` |
| <code>export fn exp_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:58` |
| <code>export fn log_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:59` |
| <code>export fn tanh_f32(x: f32) -&gt; f32</code> | `std/mathf.mc:60` |

## `std/mem`

Source: `std/mem.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct Split</code> | `std/mem.mc:240` |
| <code>pub struct SplitField</code> | `std/mem.mc:247` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn is_aligned(addr: usize, align: usize) -&gt; bool</code> | `std/mem.mc:27` |
| <code>export fn align_down(addr: usize, align: usize) -&gt; usize</code> | `std/mem.mc:32` |
| <code>export fn align_up(addr: usize, align: usize) -&gt; usize</code> | `std/mem.mc:37` |
| <code>export fn fits_within(used: usize, len: usize, limit: usize) -&gt; bool</code> | `std/mem.mc:47` |
| <code>export fn mem_copy(dst: PAddr, src: PAddr, len: usize) -&gt; void</code> | `std/mem.mc:65` |
| <code>export fn mem_set(dst: PAddr, value: u8, len: usize) -&gt; void</code> | `std/mem.mc:114` |
| <code>export fn mem_eql(a: []const u8, b: []const u8) -&gt; bool</code> | `std/mem.mc:164` |
| <code>export fn mem_starts_with(hay: []const u8, prefix: []const u8) -&gt; bool</code> | `std/mem.mc:179` |
| <code>export fn mem_index_of_byte(hay: []const u8, b: u8) -&gt; ?usize</code> | `std/mem.mc:194` |
| <code>export fn mem_index_of(hay: []const u8, needle: []const u8) -&gt; ?usize</code> | `std/mem.mc:207` |
| <code>pub fn split_by(s: []const u8, sep: u8) -&gt; Split</code> | `std/mem.mc:253` |
| <code>pub fn split_next(sp: *mut Split) -&gt; SplitField</code> | `std/mem.mc:260` |

## `std/mmio`

Source: `std/mmio.mc`

### Public types

| Signature | Source |
|---|---|
| <code>pub struct RegField</code> | `std/mmio.mc:27` |

### Public functions

| Signature | Source |
|---|---|
| <code>pub const fn reg_field(shift: u32, width: u32) -&gt; RegField</code> | `std/mmio.mc:34` |
| <code>pub const fn reg_field_mask(f: RegField) -&gt; u32</code> | `std/mmio.mc:55` |
| <code>pub const fn reg_field_get(reg: u32, f: RegField) -&gt; u32</code> | `std/mmio.mc:60` |
| <code>pub const fn reg_field_set(reg: u32, f: RegField, value: u32) -&gt; u32</code> | `std/mmio.mc:66` |
| <code>pub const fn reg_bit(n: u32) -&gt; u32</code> | `std/mmio.mc:74` |
| <code>pub const fn reg_bit_set(reg: u32, n: u32) -&gt; u32</code> | `std/mmio.mc:81` |
| <code>pub const fn reg_bit_clear(reg: u32, n: u32) -&gt; u32</code> | `std/mmio.mc:85` |
| <code>pub const fn reg_bit_toggle(reg: u32, n: u32) -&gt; u32</code> | `std/mmio.mc:89` |
| <code>pub const fn reg_bit_test(reg: u32, n: u32) -&gt; bool</code> | `std/mmio.mc:93` |
| <code>pub const fn reg_set_bits(reg: u32, mask: u32) -&gt; u32</code> | `std/mmio.mc:99` |
| <code>pub const fn reg_clear_bits(reg: u32, mask: u32) -&gt; u32</code> | `std/mmio.mc:103` |
| <code>pub const fn reg_test_all(reg: u32, mask: u32) -&gt; bool</code> | `std/mmio.mc:108` |
| <code>pub const fn reg_test_any(reg: u32, mask: u32) -&gt; bool</code> | `std/mmio.mc:112` |
| <code>pub fn mmio_write_block(dst: PAddr, src: PAddr, len: usize) -&gt; void</code> | `std/mmio.mc:125` |
| <code>pub fn mmio_read_block(dst: PAddr, src: PAddr, len: usize) -&gt; void</code> | `std/mmio.mc:138` |
| <code>pub fn mmio_write32(reg: PAddr, value: u32) -&gt; void</code> | `std/mmio.mc:152` |
| <code>pub fn mmio_read32(reg: PAddr) -&gt; u32</code> | `std/mmio.mc:159` |
| <code>pub fn mmio_modify_field(reg: PAddr, f: RegField, value: u32) -&gt; void</code> | `std/mmio.mc:170` |
| <code>pub fn mmio_set_bits(reg: PAddr, mask: u32) -&gt; void</code> | `std/mmio.mc:176` |
| <code>pub fn mmio_clear_bits(reg: PAddr, mask: u32) -&gt; void</code> | `std/mmio.mc:182` |

## `std/scan`

Source: `std/scan.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn find_index(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -&gt; bool) -&gt; usize</code> | `std/scan.mc:7` |
| <code>export fn any(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -&gt; bool) -&gt; bool</code> | `std/scan.mc:19` |

## `std/sort`

Source: `std/sort.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn sort_u32(xs: []mut u32) -&gt; void</code> | `std/sort.mc:18` |
| <code>export fn is_sorted_u32(xs: []mut u32) -&gt; bool</code> | `std/sort.mc:37` |
| <code>export fn binary_search_u32(xs: []mut u32, key: u32) -&gt; usize</code> | `std/sort.mc:51` |
| <code>export fn sort(comptime T: type, xs: []mut T, less: closure(T, T) -&gt; bool) -&gt; void</code> | `std/sort.mc:73` |
| <code>export fn is_sorted(comptime T: type, xs: []mut T, less: closure(T, T) -&gt; bool) -&gt; bool</code> | `std/sort.mc:92` |
| <code>export fn lower_bound(comptime T: type, xs: []mut T, key: T, less: closure(T, T) -&gt; bool) -&gt; usize</code> | `std/sort.mc:106` |

## `std/strbuf`

Source: `std/strbuf.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct StrBuf</code> | `std/strbuf.mc:30` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn sb_new(a: *mut dyn Allocator) -&gt; StrBuf</code> | `std/strbuf.mc:35` |
| <code>export fn sb_len(sb: *StrBuf) -&gt; usize</code> | `std/strbuf.mc:40` |
| <code>export fn sb_byte(sb: *StrBuf, i: usize) -&gt; u8</code> | `std/strbuf.mc:45` |
| <code>export fn sb_ptr(sb: *StrBuf) -&gt; PAddr</code> | `std/strbuf.mc:52` |
| <code>export fn sb_put_byte(sb: *mut StrBuf, b: u8) -&gt; void</code> | `std/strbuf.mc:57` |
| <code>export fn sb_put_str(sb: *mut StrBuf, s: []const u8) -&gt; void</code> | `std/strbuf.mc:62` |
| <code>export fn sb_put_cstr(sb: *mut StrBuf, s: *const u8) -&gt; void</code> | `std/strbuf.mc:75` |
| <code>export fn sb_put_u32(sb: *mut StrBuf, n: u32) -&gt; void</code> | `std/strbuf.mc:92` |
| <code>export fn sb_put_hex_u32(sb: *mut StrBuf, n: u32) -&gt; void</code> | `std/strbuf.mc:115` |
| <code>export fn sb_free(sb: *mut StrBuf) -&gt; void</code> | `std/strbuf.mc:132` |

## `std/sync/barrier`

Source: `std/sync/barrier.mc`

### Public functions

| Signature | Source |
|---|---|
| <code>export fn mb() -&gt; void</code> | `std/sync/barrier.mc:9` |
| <code>export fn rmb() -&gt; void</code> | `std/sync/barrier.mc:13` |
| <code>export fn wmb() -&gt; void</code> | `std/sync/barrier.mc:17` |
| <code>export fn dma_wmb() -&gt; void</code> | `std/sync/barrier.mc:21` |

## `std/sync/rwlock`

Source: `std/sync/rwlock.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct RwLock</code> | `std/sync/rwlock.mc:12` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn rwlock_init(rw: *mut RwLock) -&gt; void</code> | `std/sync/rwlock.mc:17` |
| <code>export fn read_lock(rw: *mut RwLock) -&gt; void</code> | `std/sync/rwlock.mc:24` |
| <code>export fn read_unlock(rw: *mut RwLock) -&gt; void</code> | `std/sync/rwlock.mc:30` |
| <code>export fn write_lock(rw: *mut RwLock) -&gt; void</code> | `std/sync/rwlock.mc:36` |
| <code>export fn write_unlock(rw: *mut RwLock) -&gt; void</code> | `std/sync/rwlock.mc:46` |
| <code>export fn rwlock_readers(rw: *mut RwLock) -&gt; u32</code> | `std/sync/rwlock.mc:51` |

## `std/sync/seqlock`

Source: `std/sync/seqlock.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct SeqLock</code> | `std/sync/seqlock.mc:17` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn seqlock_init(s: *mut SeqLock) -&gt; void</code> | `std/sync/seqlock.mc:22` |
| <code>export fn seq_write_begin(s: *mut SeqLock) -&gt; void</code> | `std/sync/seqlock.mc:28` |
| <code>export fn seq_write_end(s: *mut SeqLock) -&gt; void</code> | `std/sync/seqlock.mc:35` |
| <code>export fn seq_read_begin(s: *mut SeqLock) -&gt; u32</code> | `std/sync/seqlock.mc:42` |
| <code>export fn seq_read_retry(s: *mut SeqLock, start: u32) -&gt; bool</code> | `std/sync/seqlock.mc:53` |

## `std/sync/spinlock`

Source: `std/sync/spinlock.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct Spinlock</code> | `std/sync/spinlock.mc:9` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn spinlock_init(l: *mut Spinlock) -&gt; void</code> | `std/sync/spinlock.mc:14` |
| <code>export fn spin_lock(l: *mut Spinlock) -&gt; void</code> | `std/sync/spinlock.mc:19` |
| <code>export fn spin_unlock(l: *mut Spinlock) -&gt; void</code> | `std/sync/spinlock.mc:31` |

## `std/sync/sync`

Source: `std/sync/sync.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct SpinLock</code> | `std/sync/sync.mc:12` |
| <code>move struct Guard</code> | `std/sync/sync.mc:17` |
| <code>move struct IrqGuard</code> | `std/sync/sync.mc:23` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn lock(l: *SpinLock) -&gt; Guard</code> | `std/sync/sync.mc:34` |
| <code>export fn unlock(g: Guard) -&gt; void</code> | `std/sync/sync.mc:39` |
| <code>export fn lock_irqsave(l: *SpinLock) -&gt; IrqGuard</code> | `std/sync/sync.mc:45` |
| <code>export fn unlock_irqrestore(g: IrqGuard) -&gt; void</code> | `std/sync/sync.mc:49` |

## `std/task`

Source: `std/task.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>trait Future</code> | `std/task.mc:27` |
| <code>struct SlotFuture</code> | `std/task.mc:44` |
| <code>struct Join2</code> | `std/task.mc:83` |
| <code>struct Race2</code> | `std/task.mc:118` |
| <code>struct Timeout</code> | `std/task.mc:158` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn slot_future_init(s: *mut SlotFuture, id: u64, done: fn(u64) -&gt; bool, cancel: fn(u64) -&gt; void) -&gt; void</code> | `std/task.mc:51` |
| <code>export fn slot_future_cancel(s: *mut SlotFuture) -&gt; void</code> | `std/task.mc:75` |
| <code>export fn join2_init(j: *mut Join2, a: *mut dyn Future, b: *mut dyn Future) -&gt; void</code> | `std/task.mc:90` |
| <code>export fn race2_init(r: *mut Race2, a: *mut dyn Future, b: *mut dyn Future) -&gt; void</code> | `std/task.mc:124` |
| <code>export fn race2_winner(r: *Race2) -&gt; i32</code> | `std/task.mc:130` |
| <code>export fn timeout_init(t: *mut Timeout, inner: *mut dyn Future, budget_ticks: u64) -&gt; void</code> | `std/task.mc:165` |
| <code>export fn timeout_timed_out(t: *Timeout) -&gt; bool</code> | `std/task.mc:172` |
| <code>export fn run_to_completion(f: *mut dyn Future, idle: fn() -&gt; void) -&gt; u64</code> | `std/task.mc:207` |

## `std/time`

Source: `std/time.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>type Ticks = counter&lt;u64&gt;;</code> | `std/time.mc:15` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn read_ticks() -&gt; Ticks</code> | `std/time.mc:20` |
| <code>export fn delta_mod(start: Ticks, now: Ticks) -&gt; u64</code> | `std/time.mc:31` |
| <code>export fn timed_out(start: Ticks, now: Ticks, limit: u64) -&gt; bool</code> | `std/time.mc:40` |
| <code>export fn poll_until(probe: fn() -&gt; bool, timeout: u64) -&gt; bool</code> | `std/time.mc:50` |
| <code>export fn udelay(us: u32) -&gt; void</code> | `std/time.mc:61` |
| <code>export fn mdelay(ms: u32) -&gt; void</code> | `std/time.mc:65` |

## `std/virtio`

Source: `std/virtio.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>extern mmio struct VirtioMmio</code> | `std/virtio.mc:8` |
| <code>enum VirtioError</code> | `std/virtio.mc:47` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn virtio_reset(regs: MmioPtr&lt;VirtioMmio&gt;) -&gt; bool</code> | `std/virtio.mc:65` |
| <code>export fn virtio_init(regs: MmioPtr&lt;VirtioMmio&gt;, device_id: u32, want_lo: u32, want_hi: u32) -&gt; Result&lt;bool, VirtioError&gt;</code> | `std/virtio.mc:84` |
| <code>export fn virtio_driver_ok(regs: MmioPtr&lt;VirtioMmio&gt;) -&gt; void</code> | `std/virtio.mc:135` |

## `std/virtqueue`

Source: `std/virtqueue.mc`

### Referenced local types

| Signature | Source |
|---|---|
| <code>struct Virtq</code> | `std/virtqueue.mc:33` |
| <code>enum VqError</code> | `std/virtqueue.mc:138` |
| <code>enum VqSubmitError</code> | `std/virtqueue.mc:143` |
| <code>enum VqCompleteError</code> | `std/virtqueue.mc:326` |
| <code>move struct CompletedChain3</code> | `std/virtqueue.mc:339` |
| <code>move struct CompletedBuffer</code> | `std/virtqueue.mc:458` |

### Public functions

| Signature | Source |
|---|---|
| <code>export fn bus_addr(comptime T: type, p: *mut T) -&gt; u64</code> | `std/virtqueue.mc:51` |
| <code>export fn vq_free_count(vq: *mut Virtq) -&gt; u16</code> | `std/virtqueue.mc:72` |
| <code>export fn vq_free_desc(vq: *mut Virtq, id: u16) -&gt; void</code> | `std/virtqueue.mc:92` |
| <code>export fn vq_free_chain3(vq: *mut Virtq, head: u16) -&gt; void</code> | `std/virtqueue.mc:111` |
| <code>export fn vq_setup(regs: MmioPtr&lt;VirtioMmio&gt;, q: u32, vq: *mut Virtq) -&gt; Result&lt;bool, VqError&gt;</code> | `std/virtqueue.mc:153` |
| <code>export fn vq_submit_tx(vq: *mut Virtq, buf: DeviceBuffer) -&gt; Result&lt;u16, VqSubmitError&gt;</code> | `std/virtqueue.mc:233` |
| <code>export fn vq_submit_rx(vq: *mut Virtq, buf: DeviceBuffer) -&gt; Result&lt;u16, VqSubmitError&gt;</code> | `std/virtqueue.mc:237` |
| <code>export fn vq_submit_chain3(vq: *mut Virtq, header: DeviceBuffer, data: DeviceBuffer, status: DeviceBuffer, data_writable: bool) -&gt; Result&lt;u16, VqSubmitError&gt;</code> | `std/virtqueue.mc:251` |
| <code>export fn vq_complete_chain(vq: *mut Virtq) -&gt; Result&lt;CompletedChain3, VqCompleteError&gt;</code> | `std/virtqueue.mc:352` |
| <code>export fn vq_kick(regs: MmioPtr&lt;VirtioMmio&gt;, q: u32) -&gt; void</code> | `std/virtqueue.mc:418` |
| <code>export fn vq_has_used(vq: *mut Virtq) -&gt; bool</code> | `std/virtqueue.mc:424` |
| <code>export fn vq_wait_used(vq: *mut Virtq, timeout: u64) -&gt; bool</code> | `std/virtqueue.mc:434` |
| <code>export fn vq_used_len(vq: *mut Virtq) -&gt; u32</code> | `std/virtqueue.mc:446` |
| <code>export fn vq_complete(vq: *mut Virtq) -&gt; Result&lt;CompletedBuffer, VqCompleteError&gt;</code> | `std/virtqueue.mc:473` |
| <code>export fn vq_reset_reclaim(vq: *mut Virtq) -&gt; usize</code> | `std/virtqueue.mc:504` |
