# doof-- to WebAssembly

This package compiles **doof--**, a small textual, typed block language, to executable WebAssembly. The compiler and CLI are written in Doof. Its first supported types are `none`, `bool`, `char`, `byte`, `short`, `int`, `long`, `float`, `double`, concrete classes, explicit interfaces, and tagged `any`. Class instances and `any` boxes use compiler-inserted reference counting.

The `doof-wasm` source compiler is the first Doof-facing layer over this IR.
It accepts a checked Doof module graph and lowers its supported scalar,
function, class, and interface subset to one doof-- module before using the same
Wasm backend. Declarations receive module-qualified names when flattened, and
source paths remain attached to lowered declarations and instructions for
diagnostics. The CLI resolves imports relative to their importing file. It currently
  supports local bindings, returns, `if`/`else` branches,
  `while` loops, arithmetic and comparisons, calls, fields, class construction,
  interface conversion, numeric casts, byte and char arrays, and type aliases
  whose resolved types are supported by the backend. Both array types support
  literals, `.length`, indexed reads and writes, and are limited to 1024
  elements. Basic strings are represented by an injected string class over a
  read-only `char[]` wrapper. Distinct string literals are built once when the
  Wasm module starts and shared; `.length`, indexed character reads,
  content-based comparison operators, `.compare(other)`, and
  `.indexOf(search)` are supported. String interpolation and other
  string methods are not supported yet. Other collection values are not
  supported by lowering yet.
Generics, enums, and loop labels, `break`, or `continue` are not supported yet.

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

Use `--dump-minus` to write the generated doof-- model as readable text while
debugging a lowering:

```sh
doof run src/doof-cli.do -- --dump-minus example.do example.dm
```

The in-memory source APIs are `compileDoofWasm(source: string, debugHeap: bool = false): Result<byte[], string>`
and `lowerDoofWasmSource(source: string): Result<MinusModule, string>`. For
module graphs, `compileDoofWasmSources(sources, entry, loader)` and
`lowerDoofWasmSources(sources, entry, loader)` accept a `SourceLoader` callback.
`renderDoofMinus(module: MinusModule): string` renders the flattened model;
`renderDoofJs(module: MinusModule, debugHeap: bool = false): string` generates
the matching JavaScript bindings.
The initial parser and type-checking adapter uses the full Doof compiler as a
local build dependency; replacing that adapter with the embedded subset's own
front end is part of making doof-wasm self-hosting. See
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
