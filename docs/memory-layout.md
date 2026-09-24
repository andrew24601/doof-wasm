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
| `bool`, `byte` | 1 | 1 |
| `short` | 2 | 2 |
| `char`, `int`, `float`, class, interface, `any` | 4 | 4 |
| `long`, `double` | 8 | 8 |
| `none` | 0 | 1 |

Allocated sizes use 64 exact classes `24 + n * 16`, for `n` from 0 through 63. The largest block is therefore 1032 bytes. For example, `byte`, `short`, `int`, and `double` fields begin at offsets 8, 10, 12, and 16; this class occupies the minimum 24-byte block. A `none` field consumes no memory and always reads as `none`. Narrow fields use Wasm narrow loads and stores, so neighboring fields are unaffected. Class and interface fields contain class pointers; `any` fields contain box pointers. An interface conversion keeps the same class pointer and therefore the same object identity and reference count. Interface field access selects a layout by class tag; an interface method call selects a function-table slot by tag and uses Wasm `call_indirect`.

An `any` box is 24 bytes. Offset 4 contains its reference count, offset 8 contains the **contained value's two-byte tag**, and offset 16 holds the contained value in an eight-byte slot. Contained tags are `none` 0, `bool` 1, `char` 2, `byte` 3, `short` 4, `int` 5, `long` 6, `float` 7, `double` 8, or a class tag from 32 onward. Boxing a class retains the class pointer. Casting back to a class retains it for the result. `is` and `cast` compare the contained tag exactly; a mismatch in `cast` traps.

An array-data block has runtime tag 30 and reserves bytes 4–7 so its data begins at offset 8. Array data is uniquely owned by its array. Array intrinsics interpret, access, and return these blocks to the allocator and cooperate with reference management for their elements. Array-data pointers must not be passed to the generic retain or release helpers.

Tags are deterministic for a module: primitive tags are fixed, and class tags follow class declaration order. Tags are internal to a compiled module and are not a cross-module ABI.

## Reference counting

The compiler inserts ownership operations; doof-- source has no retain or release instruction. Function arguments are borrowed at the call boundary, then retained for the callee's local ownership. Newly allocated objects and boxes start with one owned reference. `copy`, interface conversion, reference field reads, and block-argument transfers retain their result. A field stores its own retained reference; replacing it releases its old reference. A function releases all owned reference locals on return, retaining a reference result first so ownership passes to the caller. Reassigning a value slot on a loop iteration releases its previous reference.

When a count reaches zero, the release helper recursively releases reference fields. An `any` box releases a contained class. The freed block is tagged free and pushed onto its exact-size free list. Allocation checks that list before advancing the heap cursor, and memory grows in pages when needed. There is no first-fit list, splitting, or coalescing. Fixed class allocations larger than 1032 bytes are rejected. Dynamically sized string and array storage is not implemented yet. Cycles of class instances are not collected and may leak. There are no weak references or destructors in this milestone.

The common heap-management overhead is four bytes per allocation. Reference-counted blocks add a four-byte count, and allocation size classes can add up to 15 bytes of tail padding. The free-list link at offset 4 is used only after an object dies. One mutable Wasm global holds the heap cursor; the 64 free-list heads occupy 256 reserved memory bytes. Blocks are reused only in their exact size class. An interface value adds no allocation; an `any` box adds its own 24-byte allocation.

## Host boundary

Exported functions accept and return only primitive carriers. Classes, interfaces, and `any` remain internal to Wasm. `none` results produce no Wasm result; a `none` parameter is represented by i32 zero. Incoming `byte` and `short` values are narrowed, `bool` is normalized to zero or one, and an invalid `char` scalar traps. The module does not require imported allocator or reference-counting functions.
