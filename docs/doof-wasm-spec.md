# doof-wasm source subset

doof-wasm accepts a checked, single-file Doof program and lowers it to
doof--. This is an initial embedded-language subset, not a replacement for
the full Doof compiler.

## Supported source constructs

- Free functions and instance methods with explicit parameter and result types.
- Trailing default parameter values on supported free functions and instance
  methods, for positional and named calls. Omitted defaults are lowered at
  each call site.
- Classes with non-static, non-weak fields, including field defaults evaluated
  when a class is constructed with positional or named arguments, plus
  explicit interface implementations.
- Interfaces with fields and method signatures.
- `none`, `bool`, `char`, `byte`, `int`, `long`, `float`, `double`,
  `string`, integer-backed enums, classes, interfaces, `SerialValue`, and union
  types (lowered to doof-- `any`), including aliases that resolve to supported
  types. `Result<T, E>` is represented as an `any` union of `Success<T>` and
  `Failure<E>`; those arms lower to concrete doof-- classes whose `value` and
  `error` fields hold boxed payloads. Type captures recover the payload's
  checked type when reading those fields. Enum tags remain distinct from
  integer tags inside `any` unions.
- Mutable and read-only arrays of `bool`, `char`, `byte`, `int`,
  `long`, `float`, `double`, enums, class and interface references, and `any`
  unions. This includes strings and nested arrays when their element types are
  supported. Arrays support literals, `.length`, indexed reads, and indexed
  writes and `.push(value)` on mutable arrays, and `.contains(value)` on both
  mutable and read-only arrays. Push preserves aliases, grows small blocks
  geometrically, and migrates to chunks when the payload exceeds 1024 bytes.
  Contains compares primitives and enums by value, strings by content, and
  class, interface, and nested-array references by identity. Union elements
  compare their nominal tags and payload values. Larger arrays use fixed-size chunks behind a
  bounded-depth radix directory and can grow to the signed `int` length limit,
  subject to available Wasm memory. Other collection types remain
  unsupported by source lowering.
- Basic `string` values backed by an injected string class and a wrapped,
  read-only `char[]`; string literals, `.length`, and indexed character reads
  are supported. Content-based comparison operators, `.compare(other)`, and
  `.indexOf(search)` are supported. Interpolation and other string methods
  are not supported.
- Host functions can be declared with `import function name(args): result`.
  They become Wasm imports in the default `doof` namespace and are connected
  through `createDoofImports(host)` from the generated JavaScript companion.
  String arguments/results are bridged to JavaScript strings. An optional
  `from "module"` selects a Wasm import namespace.
- Local `let`, `readonly`, and inferred immutable bindings; returns; `if`,
  `if`/`else`, and `else if` branches that rejoin; union `case` statements with
  type captures, `none`, and wildcard arms; `while` loops; C-style `for` loops;
  and `for-of` loops over supported arrays and integer ranges. Array iterables
  and range endpoints are evaluated once per loop entry.
- Value `if` expressions, `??` for nullable and `Result` values, and `?.`
  member or method access that propagates `none` from a nullable receiver.
- Function values lower to generated `__closure_<result>_<arg>...` interfaces
  and one class per lambda. Lambdas can capture immutable locals by copying
  them into immutable fields. Mutable `let` captures share a generated cell
  with the outer binding, so updates are visible both inside and outside the
  closure. Calls dispatch through the generated `invoke` method.
- Arithmetic `+`, `-`, `*`, `/`; comparisons `==`, `!=`, `<`, `>`; unary `-`
  and `!`; direct, instance, named, and closure calls; field reads and writes;
  positional and named class construction; class-to-interface assignment;
  numeric conversion; and `any`
  boxing/casts. Union members are boxed into `any`; comparisons with `none`
  test the contained tag. `try!` unwraps a Result and traps on failure;
  `try?` unwraps the success value and produces `none` on failure. A nullable
  value can be unwrapped with the `else` binding form. The `panic(message)`
  intrinsic is supported as a terminating trap; the Wasm backend discards its
  message.

Local bindings are converted to doof-- SSA values. Values that cross branches
or loop edges are passed as block arguments.

## Not supported yet

Imports and multiple source files, generics, string-backed enums, arrays whose
element type is unsupported by doof--, labeled loops, `break`, `continue`, loop-else
clauses, for-of destructuring, map/set/stream iteration, static members, weak references, case expressions,
value/range patterns, and multiple patterns per case arm,
async code, compound assignments, nested lexical blocks, and other source expressions. The doof-- backend
already supports more control flow and runtime operations; the source lowering
will grow to cover those as the subset is developed.

The compiler currently uses the full Doof front end as a bootstrap parser and
type checker. Replacing this adapter with a parser and checker implemented in
the subset is required before the source compiler can compile itself.
