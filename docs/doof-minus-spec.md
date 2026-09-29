# doof--: minimal language specification

doof-- is a lowered, typed, line-oriented language. It is the input to this package's WebAssembly compiler, not a source spelling of Doof. A file contains class, interface, function, and global declarations. `#` begins a comment. Names and type names are case-sensitive. Calls and construction use positional arguments only; there are no defaults.

The encoder interns Wasm function signatures and shares emitted implementations
when their complete bodies and signatures match. It repeats body folding after
callee aliases are known, so identical forwarding functions can also share code.
Function declarations, export names, and indirect-call table slots retain their
identities in the source model; emitted function indexes are assigned separately.
Constants, nominal tags, field offsets, scalar normalization, and reference
ownership operations must all match before implementations are shared.

Encoding validates the original module before optimization. Scalar copies,
bounded integer constants, and unused nontrapping scalar expressions are
simplified. Reachability starts from exports, global initializers, and class
finalizers; an interface call keeps every implementation of that interface's
method. Unreachable bodies and literals are omitted. Surviving indirect-call
slots keep their original numbers, with omitted slots left null.

Scalar locals are allocated from use intervals, including loop back edges and
parallel block-argument transfers. Adjacent single-use scalar results can stay
on the Wasm stack. Reference parameters are borrowed for the call; owned reads
and allocations still retain their required lifetime. Reference aliases are
borrowed only when destructor timing is preserved, and an owned result returned
immediately can transfer ownership to the return slot. Unused calls and trapping
operations remain, and a cast check is omitted only when a matching successful
type test dominates it. These analyses are derived from the structured body.

Immutable reference fields and boxed payloads borrow from a root that survives
the call. Branch and loop parameters borrow only when every incoming path has
such a root; an unsafe input rejects dependent aliases and forwarding cycles.
Mutable fields and array elements retain their snapshots. An interface field
requires immutable storage in every implementation. Borrowing a changing loop
value does not permit aliasing its local slot. Returns and stores still acquire
their recipient's ownership; caller-owned IR is not modified by this analysis.

## Types

The built-in types are `none`, `bool`, `char`, `byte`, `int`, `long`, `float`, `double`, and `any`. `any` is a tagged value carrier, not a class. Other type names must name a class or interface in the module.

| Type | Meaning | Wasm carrier |
| --- | --- | --- |
| `none` | Sole value `none` | No function result; i32 zero where stored or passed |
| `bool` | `true` or `false` | i32, zero or one |
| `char` | Unsigned single-byte character value (0–255) | i32 |
| `byte` | Unsigned 8-bit integer | i32 |
| `int` | Signed 32-bit integer | i32 |
| `long` | Signed 64-bit integer | i64 |
| `float` | IEEE 754 binary32 | f32 |
| `double` | IEEE 754 binary64 | f64 |
| Class, interface, `any` | Owned heap reference | i32 pointer |

Class references are non-null. Use `any` containing `none` when absence must be represented. Integer arithmetic wraps to its type's width; integer division traps on zero. Floating arithmetic follows Wasm. Explicit numeric conversions use Wasm conversion instructions: narrowing integer conversions wrap, while invalid floating-to-integer conversions trap. `char` constants must fit in one byte.

## Declarations

```text
interface HasValue
field let value:int
method get() -> int
end

class Box implements HasValue
field let value:int
end

func Box.get(%self:Box) -> int
block entry
%v:int = get %self.value
return %v
end
```

A class may name a private destructor function. It takes the class receiver and
returns `none`; the runtime calls it once when the receiver's reference count
reaches zero, before releasing the class's reference fields.

```text
class Owner
destructor Owner.destroy
field let handle:int
end

func Owner.destroy(%self:Owner) -> none
block entry
%handle:int = get %self.handle
array-free %handle
return
end
```

`field name:type` is immutable after construction; `field let name:type` is writable. Fields are constructed in declaration order. An interface may declare fields and methods. An implementation must explicitly list the interface and supply compatible fields and a function named `Class.method` with the class receiver first. Method parameters and results must match the interface declaration exactly. Classes have no inheritance or generic parameters.

Functions use `func name(%arg:type, ...) -> type`; `export func` exposes a function to the Wasm host. Exported parameters and results may be primitive or the compiler's `__doof_string` class; a raw Wasm string value is a heap pointer and needs a matching host bridge. Other class, interface, and `any` values cannot cross the export boundary. Class methods are ordinary functions named `Class.method` with a receiver as their first parameter.

## Blocks and instructions

`global name:T = initializer` declares a module-owned value. The initializer
must be a private, non-capturing function with no parameters returning `T`;
`none` globals are invalid. String literals use an active data segment containing
their complete compact/chunked object graphs and ownership headers. Literal
globals hold their final pointers, and the heap cursor starts after these static
objects. String initialization needs no Wasm code or bulk memory operations and
preserves shared literal identity. After the data segment has initialized the
string literal pool, the Wasm start function calls source-level global
initializers in declaration order. Modules without source-level globals need
no start function. The returned
reference transfers into the global root and survives for the instance lifetime.
Reads borrow reference pointers from the permanent root. Returning or storing
the pointer retains ownership for the receiving caller, field, box, or block
parameter. There is no global assignment instruction. Initializers must read only
already initialized globals; the IR producer is responsible for ordering them.
Each Wasm instance initializes and owns its own globals.

Each function has one structured body containing typed code blocks, nested
`scope` exit regions, and `loop` regions. There is no flat-graph body or
dispatcher fallback. The first code block is the entry and has no parameters.
A code block ends in exactly one `return`, `jump`, `branch`, or `panic`.

`scope label` ends with `end-scope` and is immediately followed by the code
block or loop named `label`. A jump to this label exits the scope and reaches
that destination. `loop label` ends with `end-loop`; its first code block must
be named `label`, and jumps to that label restart the loop. Jump and branch
targets must be enclosing scope or loop labels. Conditional transfers emit
Wasm `if` branches directly. Function returns exit to the shared cleanup region.

Values are defined once per function. A definition remains visible wherever
its block dominates the use: every path to the use must pass through that
definition, and same-block uses must follow it. Immutable outer values need no
forwarding parameters. Block parameters represent merges and loop-carried
values; incoming values must match their types and transfer in parallel.

```text
export func count(%limit:int) -> int
scope done
scope loop
block entry
%zero:int = const 0
%one:int = const 1
jump loop(%zero)
end-scope
loop loop
scope step
block loop(%n:int)
%again:bool = lt %n, %limit
branch %again step() done(%n)
end-scope
block step
%next:int = add %n, %one
jump loop(%next)
end-loop
end-scope
block done(%answer:int)
return %answer
end
```

The in-memory model stores only `MinusFunction.body`, a `MinusRegion` tree.
Code regions own their `MinusBlock`; scope and loop regions own child regions.
`minusBlocks(function)` derives a block view for inspection and data-flow
analysis. It does not store a second body. Source/runtime builders may assemble
transient blocks before constructing the tree; irreducible construction is an
internal lowering error. Textual IR must supply its structure explicitly.

Supported instructions are:

| Form | Result or effect |
| --- | --- |
| `%r:T = const literal` | Primitive constant; `char` uses a decimal byte value |
| `%r:T = global-get name` | Read a declared global with matching result type; borrows rooted references |
| `%r:T = add/sub/mul/div %a, %b` | Matching numeric operands and result |
| `%r:T = rem %a, %b` | Matching `byte`, `int`, or `long` operands; signed remainder for `int`/`long`, unsigned for `byte`; division by zero traps |
| `%r:bool = eq/lt %a, %b` | Matching numeric operands; `eq` also accepts `bool`, `char`, `none`, enums, references, and `any`; `lt` also accepts `char` |
| `%r:T = convert %a` | Numeric conversion; integer-backed enums and `char` may also convert to numeric types |
| `%r:T = copy %a` | Copy a value; retains references |
| `%r:C = new C(%a, ...)` | Allocate a class; arguments follow field order |
| `%r:int = array-alloc %length, T` | Allocate an array-data block with `length` elements of type `T` |
| `array-free %handle[, T]` | Release reference elements when `T` is a class, interface, or `any`, then return the block to the allocator |
| `%r:int = array-length %handle` | Read the array element count |
| `%r:T = array-get %handle, %index` | Bounds-checked read; retains class, interface, and `any` values |
| `%r:int = array-push %handle, %value` | Append an element, retaining references; returns the possibly changed handle, replacing the old uniquely owned handle |
| `%r:int = array-reserve %handle, %capacity, T` | Reserve storage for at least `capacity` elements without changing length or contents; returns the possibly changed handle. Nonpositive capacities are no-ops |
| `%r:T = array-pop %handle` | Remove the last element, transferring its reference ownership into the result; preserves capacity and traps when empty |
| `array-set %handle, %index, %value` | Bounds-checked write; retains the new reference and releases the replaced reference |
| `array-copy %destination, %destinationIndex, %source, %sourceIndex, %count, T` | Copy a scalar/enum range, preserving its bits and handling overlap; validate both complete ranges before writing |
| `%r:int = array-compare %left, %right` | Compare byte/character storage lexicographically as unsigned bytes, returning `-1`, `0`, or `1` |
| `%r:T = get %object.field` | Read a class or interface field |
| `set %object.field = %value` | Replace a mutable field |
| `%r:T = call function(%a, ...)` | Direct function call |
| `%r:T = call %object.method(%a, ...)` | Class call or dynamic interface dispatch |
| `%r:I = as %class` | Convert a class to an explicitly implemented interface |
| `%r:any = box %a` | Box `none`, a primitive, enum, class, or interface; interfaces preserve the object's concrete class tag |
| `%r:C = box C(%a)` | Allocate a one-field mutable cell of class `C` containing `%a` |
| `%r:bool = is %box T` | Test the contained nominal tag; interface targets accept concrete classes implementing the interface |
| `%r:T = cast %box T` | Recover a value; traps if its tag does not match the type or implement the target interface |
| `jump block(%a, ...)` | Transfer values to block parameters |
| `branch %bool yes(%a, ...) no(%b, ...)` | Conditional transfer |
| `return` / `return %value` | Return `none` / a typed value |
| `panic` | Trap execution with the Wasm `unreachable` instruction |

Array element types are `bool`, `char`, `byte`, `int`, `long`, `float`,
`double`, enums, `any`, and declared classes or interfaces. Reference elements
are stored as four-byte pointers. To release a reference array correctly, pass
its element type to `array-free`, for example `array-free %handle, Widget`; the
one-argument form remains valid for primitive and enum arrays. Array lengths
must be nonnegative. Push traps at the signed `int` length limit and preserves
element ownership while moving a small payload to a larger block or chunks.
For `array-copy`, handles, indexes, and count are `int`; indexes and count must
be nonnegative, and both ranges must fit their logical lengths. A zero-length
range may begin at the end. Only scalar and enum element types are accepted;
reference and `any` copies require ownership-aware element operations.
`array-compare` requires byte/character storage, with shorter equal prefixes
sorting first. These raw handles carry no element type at runtime.

References compare by identity with `eq`; `any` compares matching nominal tags
and typed payloads (including string content). Payloads above 1024 bytes use 1024-byte chunks behind a
three-level, 256-way radix directory. Their descriptor stores logical length
separately from allocated chunk count so a future append operation can add
chunks without relocating existing elements. The maximum logical length is
the signed `int` limit, subject to available Wasm memory. Negative lengths,
oversized allocations, invalid handles, and out-of-range
indexes trap. These operations are compiler-lowering primitives; source Doof
code reaches them through generated wrapper classes.

For `box C(%a)`, `C` must be a declared class with exactly one mutable field whose type matches `%a`; this form allocates the cell and initializes that field. In the `any` form, interfaces and `any` cannot be boxed directly; box the concrete class value. A failed `cast` traps. Other invalid runtime operations, such as division by zero, follow Wasm trap behavior. The compiler rejects malformed types, calls, interface implementations, and control-flow edges before emission.

Strings, first-class arrays, closures, weak references, inheritance, generics, and source-level sum types are outside this language. Array-data operations are internal lowering instructions; source Doof can access arrays only through compiler-generated wrappers. A source compiler can represent a union as `any`, box each member, and use `is` and `cast` to inspect it.

### Optional panic recovery

The module declaration `recover_panics` enables tagged language panics.
`panic %message` requires a string operand and transfers a retained string into
Wasm tag `__doof_panic_tag`. A `capture func` declaration marks a function
returning `any` whose panic handler releases frame references and returns a boxed
`Failure<string>`. Such functions require the string and Failure runtime classes.
Unmarked functions release their references and rethrow the same exception.
Without this declaration, operand-free `panic` remains a terminating Wasm trap.
These extensions are used by the opt-in source compiler self-hosting mode.
