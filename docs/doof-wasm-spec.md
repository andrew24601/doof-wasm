# doof-wasm source subset

doof-wasm accepts a checked, single-file Doof program and lowers it to
doof--. This is an initial embedded-language subset, not a replacement for
the full Doof compiler.

## Supported source constructs

- Free functions and instance methods with explicit parameter and result types.
- Classes with non-static, non-weak fields, plus explicit interface
  implementations.
- Interfaces with fields and method signatures.
- `none`, `bool`, `char`, `byte`, `short`, `int`, `long`, `float`, `double`,
  classes, interfaces, and `SerialValue` (lowered to doof-- `any`).
- Local `let`, `readonly`, and inferred immutable bindings; returns; `if` and
  `if`/`else` branches that rejoin; and `while` loops.
- Arithmetic `+`, `-`, `*`, `/`; comparisons `==`, `!=`, `<`, `>`; unary `-`
  and `!`; direct and instance calls; field reads and writes; named class
  construction; class-to-interface assignment; numeric conversion; and `any`
  boxing/casts.

Local bindings are converted to doof-- SSA values. Values that cross branches
or loop edges are passed as block arguments.

## Not supported yet

Imports and multiple source files, generics, strings, arrays, enums, type
aliases, `else if`, labeled loops, `break`, `continue`, while-else clauses, default arguments or
field values, static members, weak references, closures, pattern matching,
async code, compound assignments, nested lexical blocks, and other source expressions. The doof-- backend
already supports more control flow and runtime operations; the source lowering
will grow to cover those as the subset is developed.

The compiler currently uses the full Doof front end as a bootstrap parser and
type checker. Replacing this adapter with a parser and checker implemented in
the subset is required before the source compiler can compile itself.
