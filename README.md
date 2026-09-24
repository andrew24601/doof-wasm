# doof-- to WebAssembly

This package compiles **doof--**, a small textual, typed block language, to executable WebAssembly. The compiler and CLI are written in Doof. Its first supported types are `none`, `bool`, `char`, `byte`, `short`, `int`, `long`, `float`, `double`, concrete classes, explicit interfaces, and tagged `any`. Class instances and `any` boxes use compiler-inserted reference counting.

The `doof-wasm` source compiler is the first Doof-facing layer over this IR.
It accepts a checked, single-file Doof program and lowers its supported scalar,
function, class, and interface subset to doof-- before using the same Wasm
backend. It currently supports local bindings, returns, `if`/`else` branches,
`while` loops, arithmetic and comparisons, calls, fields, class construction,
interface conversion, and numeric casts. Modules, generics, strings, arrays,
and loop labels, `break`, or `continue` are not supported yet.

```sh
doof run src/doof-cli.do -- example.do example.wasm
```

Use `--dump-minus` to write the generated doof-- model as readable text while
debugging a lowering:

```sh
doof run src/doof-cli.do -- --dump-minus example.do example.dm
```

The source APIs are `compileDoofWasm(source: string): Result<byte[], string>`,
`lowerDoofWasmSource(source: string): Result<MinusModule, string>`, and
`renderDoofMinus(module: MinusModule): string`.
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
