# doof-- Wasm memory and ownership

The compiler emits one Wasm linear memory. Bytes 0–7 are always zero. Bytes 256–511 hold 64 free-list heads, and the rest of the first 1024 bytes is reserved. Heap allocation begins at byte 1024. A class or interface value is an i32 pointer to a class block. An `any` value holding a class or interface value is that same object pointer. An `any` holding `none` is zero, and one holding a primitive or enum is an i32 pointer to a box. Zero is never produced as a class value. Because bytes 0–7 are zero, reading the header of an `any` that holds `none` yields tag 0, which is `none`'s nominal tag. Retain and release ignore zero.

## Heap blocks

Every block begins with the same four-byte header:

| Offset | Width | Content |
| --- | --- | --- |
| 0 | 2 bytes | Runtime tag: 0 for free, 27–30 for array storage, 31 for `any`, or 32 + class declaration index for a class |
| 2 | 2 bytes | Allocated block size in bytes |

The content following the header depends on the runtime tag. A free block stores its next free-list pointer at offset 4. A class stores its four-byte reference count at offset 4, then fields beginning at offset 8. Each field retains declaration order and starts at the next offset aligned to its storage width:

| Field type | Bytes | Alignment |
| --- | ---: | ---: |
| `bool`, `byte`, `char` | 1 | 1 |
| `int`, `float`, class, interface, `any` | 4 | 4 |
| `long`, `double` | 8 | 8 |
| `none` | 0 | 1 |

Allocated sizes use 64 exact classes `24 + n * 16`, for `n` from 0 through 63. The largest block is therefore 1032 bytes. For example, `byte`, `char`, `bool`, `int`, and `double` fields begin at offsets 8, 9, 10, 12, and 16; this class occupies the minimum 24-byte block. A `none` field consumes no memory and always reads as `none`. Narrow fields use Wasm narrow loads and stores, so neighboring fields are unaffected. Class and interface fields contain class pointers; `any` fields contain object or box pointers. An interface conversion keeps the same class pointer and therefore the same object identity and reference count. Interface field access selects a layout by class tag; an interface method call selects a function-table slot by tag and uses Wasm `call_indirect`.

Identical method implementations can share an emitted Wasm function. Their
table slots remain distinct, and each slot points at the surviving implementation.
Function indexes, table slots, and interned signature indexes are separate
namespaces; `call_indirect` uses the shared signature and the original table slot.

An `any` box is 24 bytes, tagged 31. Offset 4 contains its reference count, offset 8 contains the **contained value's two-byte tag**, and offset 16 holds the contained value in an eight-byte slot. Contained tags are `bool` 1, `char` 2, `byte` 3, `int` 4, `long` 5, `float` 6, `double` 7, or an enum tag after the class range. Neither class values nor `none` are boxed. `none` is the zero pointer. For class values, converting a class or interface value to `any` retains and reuses the object pointer, whose header tag (32 onward) is its nominal tag. `is` and `cast` to a class compare the header tag; to an interface, the header tag against each implementing class; to `none`, whether the pointer is zero; to a scalar or enum, the box tag and then the contained tag. Casting to a class returns the same pointer (retained unless borrowed); a mismatch in `cast` traps. `any` equality compares nominal tags, then objects by identity (strings by contents) and boxed scalars by value.

Small arrays and string character storage use runtime tag 30, with the element count at offset 4 and elements beginning at offset 8. Larger array handles use a tag-29 descriptor: logical length at offset 4, allocated chunk count at offset 8, radix root at offset 12, and an ownership-chain head at offset 16. Directory blocks use tag 28 and contain 256 four-byte slots beginning at offset 8. Tag-27 data chunks store an ownership link at offset 4 and 1024 bytes of elements beginning at offset 8. Three directory levels cover every chunk index reachable by a signed 32-bit array length, so indexed access always follows three directory entries. The ownership chain lets destruction visit each directory and data chunk once.

Array handles are ordinary `int` values in doof--; they are not reference-counted and must not be passed to generic retain or release helpers. Generated array wrappers own their handle and free it from the destructor when their reference count reaches zero. Primitive array elements need no element-level reference management. Class, interface, and `any` elements are four-byte pointers: reads retain them, writes retain the new element and release the replaced element, and the wrapper destructor releases each remaining element before freeing the data chunks. The internal `array-free` instruction therefore carries the element type for reference arrays. The descriptor keeps logical length separate from allocated chunk count so append operations can add chunks without relocating existing elements.

Tags are deterministic for a module: primitive tags are fixed, and class tags follow class declaration order. Tags are internal to a compiled module and are not a cross-module ABI.

## Reference counting

The compiler inserts ownership operations; doof-- source has no retain or release instruction. Function arguments borrow the caller's ownership during the call. Literal and global reads borrow their instance-lifetime roots, including repeated reads inside loops. Newly allocated objects and boxes start with one owned reference. Mutable reference field reads retain their snapshots, since a field can be replaced. Immutable field reads and boxed payload reads can borrow when the owner keeps the value alive throughout the call. Interface field reads require immutable storage in every concrete implementation, not just a read-only interface view.

Copies, interface conversions, and block arguments also borrow when all their incoming ownership paths have a root that survives the call. A dependency worklist rejects candidates backed by a repeating owned value; rejection propagates through aliases, fields, and loop-forwarding cycles. Single-definition owned locals can provide a frame-lifetime root only when removing a reference cannot change observable destructor order. With custom destructors, borrowed descendants must trace to caller or instance roots. A borrowed pointer that changes between loop iterations still gets its own local; slot aliasing requires an invariant source pointer. Edge assignments remain parallel, including swaps.

A field stores its own retained reference; replacing it releases its old reference. A function releases all owned reference locals on return. Borrowed reference results are retained for the caller; immediately returned owned results transfer ownership. Reassigning an owned value slot on a loop iteration releases its previous reference; borrowed slots need no replacement release or exit cleanup. Array element reads remain owned because element mutation and storage replacement can invalidate a borrowed snapshot.

When a count reaches zero, the release helper calls the class destructor, then recursively releases reference fields in declaration order. Dense class cleanup dispatch uses `br_table`, with identical cleanup sequences sharing blocks inside the release function. Missing tags skip directly to the free-list epilogue. At most three cleanup classes, or a tag span exceeding four times the cleanup-class count, use balanced comparisons with exact matches at sparse leaves instead. Sharing preserves finalizer identity and field order without adding call frames. An `any` box contains only scalar payloads, so destroying it releases nothing else. The freed block is tagged free and pushed onto its exact-size free list. Allocation checks that list before advancing the heap cursor, and memory grows in pages when needed. There is no first-fit list, splitting, or coalescing. Fixed class allocations larger than 1032 bytes are rejected. Cycles of class instances are not collected and may leak. There are no weak references.

The common heap-management overhead is four bytes per allocation. Reference-counted blocks add a four-byte count, and allocation size classes can add up to 15 bytes of tail padding. The free-list link at offset 4 is used only after an object dies. One mutable Wasm global holds the heap cursor; additional mutable globals hold pooled string pointers when the module has string literals. The 64 free-list heads occupy 256 reserved memory bytes, starting at byte 256. Blocks are reused only in their exact size class. An interface value adds no allocation, nor does a class value converted to `any`; `none` needs no allocation; a boxed scalar or enum adds its own 24-byte allocation.

Each distinct string literal has a complete object graph in an active Wasm
data segment. It occupies a static heap prefix beginning at byte 1024, with the
same headers, size classes, ownership links, and compact/radix layouts as
runtime allocations. Instantiation initializes the literal globals to their
string pointers and the heap cursor to the end of this prefix. The initial
memory size covers every static block. No string startup code runs. A global
roots each pooled string for the module lifetime; evaluating a literal borrows
its pointer. Returning or storing the pointer retains the recipient's ownership.
The string wrapper owns a
`char[]` wrapper, which owns the array-data blocks. Heap inspection includes
these roots, and dynamic allocation begins after them.

Array instructions call private helpers shared by operation and storage type.
The helpers borrow their arguments and return owned references for reads and
pops. They are appended after source functions, preserving exported function
indices and interface method-table slots. Functions have one structured body
whose scope and loop regions emit direct Wasm blocks, loops, and conditional
branches. There is no program counter or dispatch table. Dominating values
remain visible without another ownership copy; explicit merge and loop
arguments still transfer in parallel. Unchanged arguments keep their existing
ownership. Normal and language-panic exits share one reference-cleanup epilogue.

The backend lowers doof-- into `WasmInstruction` records with logical local
indexes, function indexes, label depths, memory operands, and typed constants.
Wasm peepholes run on this stream before operand serialization and implementation
folding. Module sections remain byte-level encoding; doof-- remains the semantic
and control-flow IR.

The peephole pass replaces adjacent `local.set n; local.get n` with
`local.tee n`. It removes an unconditional branch only when all crossed empty labels immediately close and
the target is an exit label. Loop back edges, branches that skip work or an
else arm, and value-producing labels keep their branches. The instruction encoder
writes LEB operands and float payloads afterwards, keeping direct calls as relocation operands until folded function indexes are
assigned.

After peepholes, nonparameter locals are ranked by their final access counts.
Their carrier types move with them, and all local get/set/tee operands use the
new mapping. The original order is retained within each LEB operand-width range. The permutation is accepted only when shorter operands outweigh
any extra local-declaration groups. Parameter positions remain fixed. Cleanup
instructions keep their original order, preserving destructor timing.

After body folding, surviving functions are ranked by the number of direct
call, table-element, export, and start operands referring to them. Logical
function identities, import indexes, and indirect-call table slots remain fixed;
all physical function indexes use the resulting mapping. Frequency selects which bodies receive each operand width; within each width,
the prior body order is preserved to limit compression regressions. The audit identifies runtime helpers by their stable table
slots rather than assuming fixed physical indexes.

After validating the original IR, the encoder removes unused block parameters
and their incoming arguments. Uses in instructions, conditions, and returns
seed a backward worklist through incoming edges, so an unobserved cycle of
forwarded parameters is removed too. This avoids their Wasm locals, transfers,
and reference cleanup. The pass builds a separate model; caller-owned IR,
function signatures, instructions, source locations, and exports remain intact.
Calls and allocations are preserved even when their results become unused.
If a module contains a destructor beyond a proven storage-cleanup body, the
pass keeps reference block parameters to preserve observable destruction timing;
unused scalar parameters can still be removed.

## Host boundary

The Wasm module keeps its low-level exports for host use and always exports memory, allocation, and release helpers for the generated JavaScript FFI layer. `none` results produce no Wasm result; a `none` parameter is represented by i32 zero. Incoming `byte` values are narrowed, `bool` is normalized to zero or one, and `char` must be in the range 0–255. Exported strings use their heap pointer as the raw Wasm ABI; the generated JavaScript wrappers translate between JS strings and Doof string objects and release temporary references after calls.

The CLI always writes a companion `.js` module with `createDoofModule(instance)`, which provides typed stubs for exported functions. String parameters and results cross the wrapper as JS strings; Doof strings use the same compact or chunked storage as character arrays, with each character in the range 0–255. The bridge supports lengths up to the runtime’s signed 32-bit array range, subject to available Wasm memory and the host’s string limits. Native declarations such as `import function println(value: string): none` become Wasm imports in the `doof` namespace. `createDoofImports({println})` builds their JS import object; instantiate with its `.imports`, call `.attach(instance)`, then create the exported API with `createDoofModule(instance)`. String arguments from Doof are decoded before host callbacks, and JS string results are allocated as Doof strings. A declaration with `from "module"` uses that Wasm import namespace and expects the host callback at `host.module.functionName`. The `--debug-heap` option adds `createDoofHeapInspector(instance)` with `inspectBlock(address)` and `dumpHeap()`, and exports the current heap cursor as `__doof_debug_heap_end`. The inspector decodes heap headers, class fields, `any` boxes, and array data. It recognizes lowered `__doof_string`, `__doof_array_char`, and `__doof_array_byte` classes and includes idiomatic `value` and `length` properties. The in-memory `compileDoofWasm` and `compileDoofWasmSources` APIs and `encodeDoofMinus` also accept an optional `debugHeap` boolean; pair the resulting module metadata with `renderDoofJs(module, debugHeap)` to generate matching bindings.

Source array `.push` updates the wrapper's mutable `data` handle so aliases
observe the new length and storage. Small blocks grow geometrically up to
1024 payload bytes, then migrate to a radix descriptor. Existing element
references transfer without changing their reference counts; the appended
reference is retained once. Descriptor pushes allocate a chunk only when
the previous chunk is full, creating directory nodes as needed.
