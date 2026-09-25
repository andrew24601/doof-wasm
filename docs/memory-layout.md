# doof-- Wasm memory and ownership

The compiler emits one Wasm linear memory. Bytes 0–255 hold 64 free-list heads; the rest of the first 1024 bytes is reserved. Heap allocation begins at byte 1024. A class or interface value is an i32 pointer to a class block; an `any` value is an i32 pointer to a box. Zero is reserved for an internal empty reference and never produced as a class value.

## Heap blocks

Every block begins with the same four-byte header:

| Offset | Width | Content |
| --- | --- | --- |
| 0 | 2 bytes | Runtime tag: 0 for free, 30 for array data, 31 for `any`, or 32 + class declaration index for a class |
| 2 | 2 bytes | Allocated block size in bytes |

The content following the header depends on the runtime tag. A free block stores its next free-list pointer at offset 4. A class stores its four-byte reference count at offset 4, then fields beginning at offset 8. Each field retains declaration order and starts at the next offset aligned to its storage width:

| Field type | Bytes | Alignment |
| --- | ---: | ---: |
| `bool`, `byte`, `char` | 1 | 1 |
| `short` | 2 | 2 |
| `int`, `float`, class, interface, `any` | 4 | 4 |
| `long`, `double` | 8 | 8 |
| `none` | 0 | 1 |

Allocated sizes use 64 exact classes `24 + n * 16`, for `n` from 0 through 63. The largest block is therefore 1032 bytes. For example, `byte`, `short`, `int`, and `double` fields begin at offsets 8, 10, 12, and 16; this class occupies the minimum 24-byte block. A `none` field consumes no memory and always reads as `none`. Narrow fields use Wasm narrow loads and stores, so neighboring fields are unaffected. Class and interface fields contain class pointers; `any` fields contain box pointers. An interface conversion keeps the same class pointer and therefore the same object identity and reference count. Interface field access selects a layout by class tag; an interface method call selects a function-table slot by tag and uses Wasm `call_indirect`.

An `any` box is 24 bytes. Offset 4 contains its reference count, offset 8 contains the **contained value's two-byte tag**, and offset 16 holds the contained value in an eight-byte slot. Contained tags are `none` 0, `bool` 1, `char` 2, `byte` 3, `short` 4, `int` 5, `long` 6, `float` 7, `double` 8, or a class tag from 32 onward. Boxing a class retains the class pointer. Casting back to a class retains it for the result. `is` and `cast` compare the contained tag exactly; a mismatch in `cast` traps.

An array-data block has runtime tag 30. Offset 4 stores its element count and its data begins at offset 8. The handle is an ordinary `int` in doof--; it is not reference-counted and must not be passed to generic retain or release helpers. Internal array operations allocate, bounds-check, load, store, and free these blocks. Generated array wrappers own their data block and free it from the destructor when the wrapper's reference count reaches zero. Primitive array elements need no element-level reference management. Class, interface, and `any` elements are four-byte pointers: reads retain them, writes retain the new element and release the replaced element, and the wrapper destructor releases each remaining element before freeing the data block. The internal `array-free` instruction therefore carries the element type for reference arrays. Array payloads are limited to 1024 bytes, so the maximum element count depends on the element width.

Tags are deterministic for a module: primitive tags are fixed, and class tags follow class declaration order. Tags are internal to a compiled module and are not a cross-module ABI.

## Reference counting

The compiler inserts ownership operations; doof-- source has no retain or release instruction. Function arguments are borrowed at the call boundary, then retained for the callee's local ownership. Newly allocated objects and boxes start with one owned reference. `copy`, interface conversion, reference field reads, and block-argument transfers retain their result. A field stores its own retained reference; replacing it releases its old reference. A function releases all owned reference locals on return, retaining a reference result first so ownership passes to the caller. Reassigning a value slot on a loop iteration releases its previous reference.

When a count reaches zero, the release helper calls the class destructor, then recursively releases reference fields. An `any` box releases a contained class. The freed block is tagged free and pushed onto its exact-size free list. Allocation checks that list before advancing the heap cursor, and memory grows in pages when needed. There is no first-fit list, splitting, or coalescing. Fixed class allocations larger than 1032 bytes are rejected. Cycles of class instances are not collected and may leak. There are no weak references.

The common heap-management overhead is four bytes per allocation. Reference-counted blocks add a four-byte count, and allocation size classes can add up to 15 bytes of tail padding. The free-list link at offset 4 is used only after an object dies. One mutable Wasm global holds the heap cursor; additional mutable globals hold pooled string pointers when the module has string literals. The 64 free-list heads occupy 256 reserved memory bytes. Blocks are reused only in their exact size class. An interface value adds no allocation; an `any` box adds its own 24-byte allocation.

Each distinct string literal is allocated once by the module start function. A global roots each pooled string for the module lifetime; evaluating a literal retains its pointer to produce an ordinarily owned value. The string wrapper owns a `char[]` wrapper, which owns the array-data block.

## Host boundary

The Wasm module keeps its low-level exports for host use and always exports memory, allocation, and release helpers for the generated JavaScript FFI layer. `none` results produce no Wasm result; a `none` parameter is represented by i32 zero. Incoming `byte` and `short` values are narrowed, `bool` is normalized to zero or one, and `char` must be in the range 0–255. Exported strings use their heap pointer as the raw Wasm ABI; the generated JavaScript wrappers translate between JS strings and Doof string objects and release temporary references after calls.

The CLI always writes a companion `.js` module with `createDoofModule(instance)`, which provides typed stubs for exported functions. String parameters and results cross the wrapper as JS strings; Doof strings currently accept at most 1024 characters, each in the range 0–255. Native declarations such as `import function println(value: string): none` become Wasm imports in the `doof` namespace. `createDoofImports({println})` builds their JS import object; instantiate with its `.imports`, call `.attach(instance)`, then create the exported API with `createDoofModule(instance)`. String arguments from Doof are decoded before host callbacks, and JS string results are allocated as Doof strings. A declaration with `from "module"` uses that Wasm import namespace and expects the host callback at `host.module.functionName`. The `--debug-heap` option adds `createDoofHeapInspector(instance)` with `inspectBlock(address)` and `dumpHeap()`, and exports the current heap cursor as `__doof_debug_heap_end`. The inspector decodes heap headers, class fields, `any` boxes, and array data. It recognizes lowered `__doof_string`, `__doof_array_char`, and `__doof_array_byte` classes and includes idiomatic `value` and `length` properties. The in-memory `compileDoofWasm` and `compileDoofWasmSources` APIs and `encodeDoofMinus` also accept an optional `debugHeap` boolean; pair the resulting module metadata with `renderDoofJs(module, debugHeap)` to generate matching bindings.
