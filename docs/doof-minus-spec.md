# doof--: minimal language specification

doof-- is a lowered, typed, line-oriented language. It is the input to this package's WebAssembly compiler, not a source spelling of Doof. A file contains class, interface, and function declarations. `#` begins a comment. Names and type names are case-sensitive. Calls and construction use positional arguments only; there are no defaults.

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

Each function starts with an entry block without parameters. A block ends in exactly one `return`, `jump`, `branch`, or `panic`. Values are defined once per function. A block can read function parameters and its own parameters and results. Values crossing an edge must be supplied as block arguments.

```text
export func count(%limit:int) -> int
block entry
%zero:int = const 0
jump loop(%zero)
block loop(%n:int)
%again:bool = lt %n, %limit
branch %again step(%n) done(%n)
block step(%old:int)
%one:int = const 1
%next:int = add %old, %one
jump loop(%next)
block done(%answer:int)
return %answer
end
```

Supported instructions are:

| Form | Result or effect |
| --- | --- |
| `%r:T = const literal` | Primitive constant; `char` uses a decimal byte value |
| `%r:T = add/sub/mul/div %a, %b` | Matching numeric operands and result |
| `%r:bool = eq/lt %a, %b` | Matching numeric operands; `eq` also accepts `bool`, `char`, `none`, enums, references, and `any`; `lt` also accepts `char` |
| `%r:T = convert %a` | Explicit conversion between numeric types |
| `%r:T = copy %a` | Copy a value; retains references |
| `%r:C = new C(%a, ...)` | Allocate a class; arguments follow field order |
| `%r:int = array-alloc %length, T` | Allocate an array-data block with `length` elements of type `T` |
| `array-free %handle[, T]` | Release reference elements when `T` is a class, interface, or `any`, then return the block to the allocator |
| `%r:int = array-length %handle` | Read the array element count |
| `%r:T = array-get %handle, %index` | Bounds-checked read; retains class, interface, and `any` values |
| `%r:int = array-push %handle, %value` | Append an element, retaining references; returns the possibly changed handle, replacing the old uniquely owned handle |
| `array-set %handle, %index, %value` | Bounds-checked write; retains the new reference and releases the replaced reference |
| `%r:T = get %object.field` | Read a class or interface field |
| `set %object.field = %value` | Replace a mutable field |
| `%r:T = call function(%a, ...)` | Direct function call |
| `%r:T = call %object.method(%a, ...)` | Class call or dynamic interface dispatch |
| `%r:I = as %class` | Convert a class to an explicitly implemented interface |
| `%r:any = box %a` | Box `none`, a primitive, or a concrete class |
| `%r:C = box C(%a)` | Allocate a one-field mutable cell of class `C` containing `%a` |
| `%r:bool = is %box T` | Test the contained concrete type tag |
| `%r:T = cast %box T` | Recover a value; traps if its tag differs |
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
