# doof-- to WebAssembly

This package compiles **doof--**, a small textual, typed block language, to executable WebAssembly. The compiler and CLI are written in Doof. Its first supported types are `none`, `bool`, `char`, `byte`, `int`, `long`, `float`, `double`, concrete classes, explicit interfaces, and tagged `any`. Class instances and `any` boxes use compiler-inserted reference counting.

Function bodies use nested scope and loop regions that emit direct Wasm control
flow. Dominating values remain visible across blocks; only merges and changing
loop values need parameters. The structured body is the sole IR representation,
with no program-counter dispatcher or flat-body compatibility path.

The backend removes unreachable implementations, simplifies scalar expressions,
reuses scalar locals, and emits adjacent single-use values on the Wasm stack.
It also borrows call parameters and shares identical function bodies and
signatures while preserving reference cleanup and indirect-call identities.
Literal and global reads borrow their permanent roots. A structured Wasm
instruction stream keeps logical operands until encoding. Its peephole pass
fuses adjacent local stores/reloads and removes redundant exit branches while
preserving loop back edges and typed control flow. Frequently accessed locals
and surviving functions receive smaller indexes, with parameters and method
table slots kept stable.

The `doof-wasm` source compiler is the first Doof-facing layer over this IR.
It accepts a checked Doof module graph and lowers its supported scalar,
function, class, and interface subset to one doof-- module before using the same
Wasm backend. Declarations receive module-qualified names when flattened, and
source paths remain attached to lowered declarations and instructions for
diagnostics. Named free-function values (including imported aliases and host
imports) and lambdas lower to generated interfaces and classes; immutable
local captures are copied into the generated class, while mutable captures use
a shared mutable cell so writes from either side remain visible. The CLI resolves imports relative to their importing file. It currently
  supports local bindings, returns, `if`/`else` branches,
  `while` and C-style `for` loops, `for-of` over arrays and integer ranges,
  value `if` expressions, `?.` member and method access on nullable receivers,
  `??` coalescing, arithmetic and comparisons, calls, fields, class construction,
  interface conversion, integer-backed enums (including distinct enum tags in
  `any` unions), numeric casts, arrays of all supported primitive types and
  enums, arrays of class and interface references (including strings, nested
  arrays, and `any` unions), and type aliases
  whose resolved types are supported by the backend. Supported arrays have
  literals, `.length`, indexed reads and writes, `.push(value)`, `.reserve(capacity)`,
  and `.pop()` on mutable arrays, and `.contains(value)`. Pop returns a Result;
  reserve preserves length and contents. Small arrays use compact blocks; larger arrays
  grow in 1024-byte chunks. Basic strings are represented by an injected string class over a
  read-only `char[]` wrapper. Distinct string literals and their object graphs
  initialize directly from an active Wasm data segment and are shared; `.length`, indexed character reads,
  content-based comparison operators, `.compare(other)`, `.indexOf(search)`,
  `.contains(search)`, `.startsWith(prefix)`, `.endsWith(suffix)`,
  `.substring(start[, end])`, `.split(separator)`, `.replaceAll(search, replacement)`,
  `.trim()`, `.trimStart()`, `.trimEnd([suffix])`, string concatenation, and
  `string(value)` for `int`, `long`, `byte`, `bool`, `char`, `float`, `double`, strings,
  and integer-backed enums, plus primitive/string/enum interpolation, are
  supported. Collection/boxed-union interpolation and other string methods remain
  unsupported. Other collection values are not supported by lowering yet.
Direct static method calls and implicit instance-member access are supported.
Shared field reads through class unions support ordinary, forced, and optional
access, including imported aliases and different field layouts. Presence
assertions preserve multi-type union tags, and equality can compare boxed unions
with concrete values. Shared field writes dispatch by concrete tag and support
simple and compound assignments when every class has a mutable field of the
same checked type. Multi-class union method dispatch remains unsupported.
Scalar top-level constants and type aliases, compound arithmetic assignments,
short-circuit `&&`/`||`, integer division and remainder, unlabeled `break` and
`continue`, and plain `try` Result propagation are supported. Generics,
string-backed enums, loop labels, and loop `else` clauses are not supported yet.
Top-level immutable/readonly array literal trees of primitive values, strings,
and nested arrays initialize once per Wasm instance, preserving shared reference
ownership and mutable interiors on shallow immutable bindings. Checked dead
statements are omitted, and constant-true loops
without a reachable break have no fallthrough.

```sh
doof run src/doof-cli.do -- example.do example.wasm
```

This writes both `example.wasm` and `example.js`. Instantiate the Wasm module,
then pass its instance to `createDoofModule` imported from the companion file.
The generated bindings wrap exported Doof functions and marshal string
arguments and results to and from JavaScript strings. Add `--debug-heap` before
the input path to include `createDoofHeapInspector` in the companion module.

Host functions declared with `import function name(...): type` are supplied
through `createDoofImports(hostFunctions)`. Instantiate with the returned
`.imports`, attach the instance, then create the exported Doof API:

```js
const bridge = createDoofImports({ println: console.log });
const { instance } = await WebAssembly.instantiate(wasmBytes, bridge.imports);
bridge.attach(instance);
const doof = createDoofModule(instance);
```

[The examples](docs/doof-wasm-examples.md) include a runnable host-import module.

Use `--dump-minus` to write the generated doof-- model as readable text while
debugging a lowering:

```sh
doof run src/doof-cli.do -- --dump-minus example.do example.dm
```

The in-memory source APIs are `compileDoofWasm(source, debugHeap = false, options = WasmLoweringOptions {})`
and `lowerDoofWasmSource(source, options = WasmLoweringOptions {})`. For
module graphs, `compileDoofWasmSources(sources, entry, loader)` and
`lowerDoofWasmSources(sources, entry, loader)` accept a `SourceLoader` callback.
The CLI mounts local package dependencies and injects the compiler's Wasm stdlib
subset through a caller-owned source environment. The generated companion exports
`createDoofStdHost(io)` for its numeric and file I/O host primitives. See
[the source environment and stdlib notes](docs/wasm-stdlib.md).
For compiler bootstrapping, `--self-hosting` enables boxed immutable structs and
eager synchronous async execution. Library callers can set the independent
`boxImmutableStructs` and `synchronousAsync` options; both default to false.
See [compatibility mode details](docs/self-hosting.md#opt-in-compiler-compatibility-mode).
`renderDoofMinus(module: MinusModule): string` renders the flattened model;
`renderDoofJs(module: MinusModule, debugHeap: bool = false): string` generates
the matching JavaScript bindings.
The initial parser and type-checking adapter uses the full Doof compiler as a
local build dependency; replacing that adapter with the embedded subset's own
front end is part of making doof-wasm self-hosting. The current
[doof-minus bootstrap attempt](docs/self-hosting.md) records the remaining
source and runtime blockers. See
[the source subset notes](docs/doof-wasm-spec.md) for the current boundary.

See the [language specification](docs/doof-minus-spec.md) for syntax and the [memory layout](docs/memory-layout.md) for the Wasm representation and ownership rules.

## Compile

```sh
doof run src/minus-cli.do -- example.dm example.wasm
```

The Doof API is `compileDoofMinus(source: string): Result<byte[], string>` from `src/index.do`. `parseDoofMinus`, `validateDoofMinus`, and `encodeDoofMinus` expose the individual stages. The existing low-level Wasm module encoder remains available through `encodeModule`.

## Example

```text
class Counter
field let value:int
end

export func answer() -> int
block entry
%start:int = const 40
%counter:Counter = new Counter(%start)
%two:int = const 2
%sum:int = add %start, %two
set %counter.value = %sum
%current:int = get %counter.value
return %current
end
```

Compile this source, then instantiate the resulting `.wasm` file in a Wasm host and call `answer`. Exported functions use primitive values only; class and `any` values stay inside the module.

Run `doof test src` to execute the compiler tests, including Wasm execution tests through Node.js. The low-level encoder tests retain their exact byte fixtures.

The encoder shares identical function implementations and interns Wasm signatures.
Function names, exports, and method-table slots are preserved.

The 2026-09-29 self-compilation baseline is **1.20 MiB**, rebuilds its
79 modules in **3.300 seconds** (three-run median), and uses **116.8 MiB** of
linear memory.

The [portable source-compiler entry](docs/selfhost-compiler.md) now bootstraps into
Wasm and compiles in-memory and caller-loaded projects through the existing
analyzer and checker. The explicit acceptance gate compares native/Wasm bytes,
bindings, diagnostics, and behavior with repeated-call heap checks and a large
literal. The frozen source bundle reproduces identical Wasm and bindings through
the native bootstrap and stages 2/3. The new baseline also passes full-graph
heap cleanup and all 12 native/Wasm parity cases; see
[the self-hosting plan](docs/self-hosting.md).
