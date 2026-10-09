# doof-wasm source subset

doof-wasm accepts a checked Doof module graph and lowers it to
doof--. This is an initial embedded-language subset, not a replacement for
the full Doof compiler.

## Supported source constructs

- Free functions, instance methods, and direct static method calls with explicit
  parameter and result types. Static methods lower to free functions without a
  receiver. Bare instance fields and method calls use `this`, including inside
  closures; local shadowing still follows the checker.
- Trailing default parameter values on supported free functions and instance/static
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
  Integer-backed enum `.value` reads expose their backing integer.
- Mutable and read-only arrays of `bool`, `char`, `byte`, `int`,
  `long`, `float`, `double`, enums, class and interface references, and `any`
  unions. This includes strings and nested arrays when their element types are
  supported. Arrays support literals, `.length`, indexed reads, and indexed
  writes, `.push(value)`, `.reserve(capacity)`, and `.pop()` on mutable arrays,
  and `.contains(value)` on both mutable and read-only arrays. Reserve preserves
  length and contents while allocating backing capacity. Pop removes the last
  element and returns `Result<T, string>`, with Failure on empty arrays; removed
  references remain owned by the Result. Both methods preserve aliases. Push grows small blocks
  geometrically, and migrates to chunks when the payload exceeds 1024 bytes.
  Contains compares primitives and enums by value, strings by content, and
  class, interface, and nested-array references by identity. Union elements
  compare their nominal tags and payload values. Larger arrays use fixed-size chunks behind a
  bounded-depth radix directory and can grow to the signed `int` length limit,
  subject to available Wasm memory.
  Byte arrays also support `.cloneReadonly()` and `.cloneMutable()` as independent
  copies, including arrays that span multiple chunks.
  Nullable arrays and strings support optional indexing (`receiver?[index]`).
  The receiver evaluates once; an absent receiver returns `none` without
  evaluating the index. Present receivers retain ordinary bounds checks, and
  reference and union element types keep their checked ownership and tags.
- `Map<string, bool>` with empty/populated literals, `.has(key)`,
  `.get(key): Result<bool, string>`, `.set(key, value)`, and `.size`. Missing
  keys return `Failure("Map key not found")`. Keys compare by string content;
  updates replace the value without changing size. Aliases share the map's owned
  key/value arrays, and lookup is linear. Readonly maps support reads; frontend
  checks reject mutation. Maps may be held in fields, arrays, closures, and
  nullable unions. Other map types, indexing, iteration, methods, spreads, and
  top-level map initializers remain unsupported. Other collection types remain
  unsupported by source lowering.
- Basic `string` values backed by an injected string class and a wrapped,
  read-only `char[]`; string literals, `.length`, and indexed character reads
  are supported. An active Wasm data segment initializes the complete literal
  object graph, including compact/chunked storage, array wrappers, string
  wrappers, and reference counts. Literal globals point directly at these
  objects; the heap cursor starts after this static prefix. Strings need no
  startup function or bulk memory operations. Each encoding call computes its
  pool once; literal identity and global indices remain stable. Source-level
  global initializers run after the data segment has initialized the strings.
  Content-based comparison operators, `.compare(other)`, and
  `.indexOf(search)`, `.contains(search)`, `.startsWith(prefix)`,
  `.endsWith(suffix)`, `.substring(start[, end])`, `.split(separator)`,
  `.replaceAll(search, replacement)`, `.trim()`, `.trimStart()`, and
  `.trimEnd([suffix])` are supported. Concatenation and `+=` allocate a new string without mutating either
  operand. Split retains empty fields for a nonempty separator and splits into
  individual characters for an empty separator. ReplaceAll leaves empty searches
  unchanged, replaces non-overlapping matches, and does not search inserted text
  or interpret replacement markers. It allocates the output once after checking
  its signed 32-bit length with 64-bit arithmetic. Overflow becomes a language
  panic in self-hosting mode. Trimming removes exactly ASCII space and codes 9–13;
  an explicit trimEnd character removes only that character, including NUL.
  `string(value)` supports `int`, `long`, `byte`, `bool`, `char`, `float`, `double`, and string values,
  including the minimum signed integer values. Floating formatting uses the
  generated std host helper with six significant digits. Integer-backed enums
  format as their declared variant names, including through imported aliases.
  String interpolation evaluates each expression once in source order and uses
  these same formatting rules; `none` interpolates as native `"null"`. It supports
  primitive/string/enum expressions, nested interpolation, and terminating
  expressions. Collection and boxed-union interpolation and other string methods
  remain unsupported. Invalid enum values panic; self-hosting mode preserves the
  native diagnostic and releases temporary strings.
- Host functions can be declared with `import function name(args): result`.
  They become Wasm imports in the default `doof` namespace and are connected
  through `createDoofImports(host)` from the generated JavaScript companion.
  String arguments/results are bridged to JavaScript strings. An optional
  `from "module"` selects a Wasm import namespace.
- Relative imports and multiple source files, flattened with module-qualified
  names. Type-alias declarations use the checker-resolved target type. Scalar
  top-level immutable/readonly constants with literal, constant reference, unary,
  and binary initializers are expanded at their use sites. Top-level immutable
  and readonly array literal trees of primitive values and strings (including
  nested arrays, empty arrays, and scalar constant references) initialize once at
  Wasm startup. Their module roots
  preserve shared identity, mutable interiors on shallow immutable bindings, and
  reference ownership across calls. The frontend's module-initializer checks
  still apply; arbitrary executable initializers remain unsupported.
- Local `let`, `readonly`, and inferred immutable bindings; scoped `with`
  bindings with optional annotations, sequential initializers, nesting, and
  retained `_` discards. Scoped roots remain alive throughout the body and
  release at normal scope exits, loop exits, and `yield`; function exits use
  the shared cleanup epilogue. Escaping references retain their ownership,
  and shadowed outer bindings are restored with their latest assignments.
  Returns; `if`,
  `if`/`else`, and `else if` branches that rejoin; `case` statements over supported
  scalar and union subjects with type captures (including union aliases), value,
  integer range, and wildcard arms. Ranges may be inclusive, exclusive, or
  open-ended; alternative patterns use `|` and short-circuit in source order.
  The subject evaluates once. Multiple patterns in one arm cannot introduce
  named type captures. Case expressions support the same patterns and produce
  checked arm values, including numeric widening, reference/interface results,
  union boxing, and `Result` captures. Block arms use scoped `yield` exits through
  nested branches and loops; nested cases and local `<-` value blocks keep their
  own yield targets. Mutable locals rejoin with the result, and terminating arms
  contribute no value edge. Local `<-` declarations and reassignments are
  supported, including reassignments of captured mutable bindings.
  Also supported are `while`
  loops; C-style `for` loops;
  and `for-of` loops over supported arrays and integer ranges. Checked statements
  after a terminating return, loop exit, or exhaustive branch are omitted.
  Constant-true loops without a reachable break have no fallthrough.
  Array iterables
  and range endpoints are evaluated once per loop entry. Loops may have labels;
  `break` and `continue` target the innermost loop or the named enclosing loop
  and carry local values through the exit or update edge. Labeled and unlabeled
  `continue` execute the target loop's C-style updates or for-of increments.
- Value `if` expressions, `??` for nullable and `Result` values, and `?.`
  member or method access that propagates `none` from a nullable receiver.
  Shared field reads through class unions dispatch by concrete tag, preserving
  different field layouts and coercing values to the checked joined field type.
  Ordinary, forced, and optional reads support imported aliases, reference and
  array fields, numeric widening, and closure captures. Presence assertions on
  multi-type unions retain their boxed tags; `none` becomes a language panic in
  self-hosting mode. Ordinary reads also dispatch for a single nullable class,
  including locals, parameters, and captured mutable cells. Shared field writes
  dispatch by concrete tag for simple and compound assignments; every class
  must have a mutable field of the same checked type. Receivers and right-hand
  sides evaluate once, and assignments keep the checked expression result type.
  Missing receivers become language panics in self-hosting mode. Multi-class
  union method dispatch remains unsupported.
- Function values lower to generated `__closure_<result>_<arg>...` interfaces
  and forwarding classes for named free-function values, including imported
  aliases and host imports. Each lambda has its own class. Lambdas can capture
  immutable locals by copying
  them into immutable fields. Mutable `let` captures share a generated cell
  with the outer binding, so updates are visible both inside and outside the
  closure. Calls dispatch through the generated `invoke` method.
  Union type patterns test concrete runtime tags and keep union captures boxed
  for subsequent narrowing.
- Arithmetic `+`, `-`, `*`, `/`, integer division `\`, and integer remainder
  `%`; compound arithmetic assignments on locals, fields, and array elements;
  short-circuit `&&` and `||`; comparisons `==`, `!=`, `<`, `>`, `<=`, `>=`
  (numeric comparisons promote mixed primitive widths); unary `-` and `!`;
  direct, instance, named, and closure calls; field reads and writes;
  positional and named class construction; class-to-interface assignment;
  numeric conversion; and `any`
  boxing/casts. Union members are boxed into `any`; comparisons with `none`
  test the contained tag. Equality between boxed and concrete values boxes the
  concrete operand and uses nominal tag/payload equality, comparing strings by
  content and class/array references by identity. Plain statement-level `try` unwraps a Result and
  returns the original Failure arm on failure. `Success(...)` and `Failure(...)`
  calls and brace constructors are supported, including payloadless `Success()`
  and `Failure()`. Intrinsic arm equality compares payloads by value, including
  Results nested in payloads. Discarded bindings evaluate their
  value. Forced access on strong nullable receivers casts and traps on `none`.
  Postfix `!` checks every absent layer and traps on outer `none`, Failure, or
  a nullable success payload of `none`; `Result<none, E>!` checks only Failure.
  Postfix `?` collapses those layers to a nullable present value. `?.`, `?[]`,
  and `??` use the same absence rules, evaluate their subject once, and skip
  arguments, indexes, or fallbacks when appropriate. A Result-valued optional
  access keeps the member's own Failure and wraps receiver absence in `Success(none)`.
  The removed `try!` / `try?` forms receive frontend diagnostics naming their
  postfix replacements. Only statement `try` propagates Failure; declarations
  and assignments to supported targets retain checked success types.
  Declaration-`else` checks all absent layers and can capture `E | none` when
  absence can come from `none`. Named success bindings require a terminating
  handler; `_ := expr else ...` permits a continuing handler. The `panic(message)`
  intrinsic is supported as a terminating trap; the Wasm backend discards its
  message.

Local bindings are converted to doof-- SSA values in one structured region
body. Definitions remain visible wherever they dominate their uses, including
receivers and arguments evaluated before a later operand creates branches.
Immutable locals need no forwarding copies; mutable versions use explicit merge
and loop parameters. Scope and loop labels emit direct Wasm control flow.

Before emission, the backend simplifies scalar expressions and prunes
unreachable functions and blocks. It reuses scalar locals, keeps adjacent
single-use values on the Wasm stack, and borrows reference parameters during
calls. Owned references retain their cleanup semantics; custom destructors
restrict alias elimination. Immutable field and boxed payload reads, copies,
and branch/loop arguments can borrow when all their ownership paths have a
root that survives the call. Mutable field reads and array element reads also
borrow when no instruction before their last use can write shared storage,
according to a module-wide effect summary; borrowed element reads use a
non-retaining helper. An owned reference whose only use is a block argument
moves into the parameter without a retain. Other mutable snapshots and
escaping ownership remain retained. Calls to single-block leaf wrappers
(field loads feeding one storage helper or pure call) are emitted inline.
String `==` uses a dedicated equality helper that checks identity and length
first. Chains of three or more string concatenations, including interpolated
strings, are built with one allocation. Class and interface values stored in `any` are the objects themselves;
`none` is the zero pointer, and only primitives and enums are boxed. After lowering, the compiler
clears the checker's declaration back-references, so the checked program is
freed rather than retained by reference cycles. Function bodies and Wasm signatures are shared
when their complete implementations and carriers match.

String comparison resolves storage once per chunk and compares eight bytes
at a time with `i64.load`. On a mismatch, XOR and a trailing-zero count locate
the first differing byte, which is compared unsigned; the tail uses byte loads
without reading beyond the logical end. Concatenation, substring, and byte
snapshots use chunk-wise `memory.copy`; array block initialization uses
`memory.fill`. Array growth transfers compact payloads with `memory.copy`.
Generated modules therefore require bulk memory instructions, but these paths
do not require SIMD. Substring clamps negative starts to zero and oversized
ends to the string length, returning empty for a reversed or empty range,
matching the native runtime.

## Not supported yet

Generics, string-backed enums, arrays whose
element type is unsupported by doof--, loop-then
clauses, for-of destructuring, map/set/stream iteration, static fields, weak references,
multiple case patterns with named type captures,
async code outside the opt-in self-hosting mode, actors, nested lexical blocks, arbitrary module initializers,
fallible declaration-else handlers that continue, try destructuring/else handlers, and other
source expressions. Named method values remain unsupported; named free-function
values and lambdas use the supported closure ABI. The doof-- backend
already supports more control flow and runtime operations; the source lowering
will grow to cover those as the subset is developed.

See [the implementation gap inventory](implementation-gaps.md) for the comparison
with doof-lang and the remaining work.

The compiler uses the existing Doof front end for parsing and type checking.
The complete portable compiler graph now bootstraps into Wasm and compiles
source fixtures there with opt-in self-hosting compatibility. The frozen source
bundle now reproduces identical Wasm and binding artifacts through the native
bootstrap and stages 2/3, and each full self-compile returns the heap to its
baseline.

## Self-hosting compatibility options

`WasmLoweringOptions` is an optional trailing parameter on the source lowering
and compilation APIs. `boxImmutableStructs` boxes immutable structs using class
storage and rejects mutable struct fields. `synchronousAsync` executes async
calls/blocks eagerly, boxes settled Results as Promises, supports repeatable
`.get()` and FIFO promise-array `.takeFirstCompleted()`, and captures language
panics in async jobs and inline `catchPanic` lambdas. Actors remain unsupported.
Both options default to false; the CLI's `--self-hosting` enables both. This mode
requires Wasm exception handling. See [self-hosting notes](self-hosting.md) for
panic ownership and remaining limitations.
