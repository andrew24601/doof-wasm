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
- `none`, `bool`, `char`, `byte`, `short`, `int`, `long`, `float`, `double`,
  `string`, integer-backed enums, classes, interfaces, `SerialValue`, and union
  types (lowered to doof-- `any`), including aliases that resolve to supported
  types. Enum tags remain distinct from integer tags inside `any` unions.
- Mutable and read-only `byte[]` and `char[]` values, including literals,
  `.length`, indexed reads, and indexed writes on mutable arrays. Array literals
  are limited to 1024 elements. Other collection types remain unsupported by
  source lowering.
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
  type captures, `none`, and wildcard arms; and `while` loops.
- Arithmetic `+`, `-`, `*`, `/`; comparisons `==`, `!=`, `<`, `>`; unary `-`
  and `!`; direct, instance, and named calls; field reads and writes;
  positional and named class construction; class-to-interface assignment;
  numeric conversion; and `any`
  boxing/casts. Union members are boxed into `any`; comparisons with `none`
  test the contained tag. A nullable value can be unwrapped with the `else`
  binding form. The `panic(message)` intrinsic is supported as a terminating
  trap; the Wasm backend discards its message.

Local bindings are converted to doof-- SSA values. Values that cross branches
or loop edges are passed as block arguments.

## Not supported yet

Imports and multiple source files, generics, string-backed enums, arrays other
than `byte[]` and `char[]`, labeled loops, `break`, `continue`, while-else
clauses, static members, weak references, closures, case expressions,
value/range patterns, and multiple patterns per case arm,
async code, compound assignments, nested lexical blocks, and other source expressions. The doof-- backend
already supports more control flow and runtime operations; the source lowering
will grow to cover those as the subset is developed.

The compiler currently uses the full Doof front end as a bootstrap parser and
type checker. Replacing this adapter with a parser and checker implemented in
the subset is required before the source compiler can compile itself.
