# doof-wasm

A WebAssembly compiler for a subset of [Doof](../doof-lang), written in Doof.

The Doof front end (parser, resolver, checker) comes from the full Doof compiler, declared as a local dependency in [doof.json](doof.json) (`../doof-lang`). The compiler has also been bootstrapped: the source-compiler entry compiles itself to Wasm and reaches a verified native/stage-2/stage-3 fixed point. See [docs/self-hosting.md](docs/self-hosting.md).

## Requirements

- The `doof` CLI, with the Doof checkout at `../doof-lang`.
- Node.js, for the Wasm execution tests and the self-hosting tools.
- A Wasm runtime with exception handling. Self-hosting mode requires it.

## Compile a Doof program

```sh
doof run src/doof-cli.do -- [--self-hosting] [--debug-heap] input.do output
```

This writes `output.wasm` and a companion `output.js`. The companion exports `createDoofModule`, which wraps the exported Doof functions and marshals strings to and from JavaScript strings. The runtime represents strings as byte-valued characters (0–255).

| Flag | Effect |
| --- | --- |
| `--debug-heap` | Adds `createDoofHeapInspector` to the companion module. |
| `--self-hosting` | Boxes immutable structs and runs async code eagerly and synchronously, as the compiler's own bootstrap needs. |

Host functions declared with `import function name(...): type` are supplied at instantiation:

```js
const bridge = createDoofImports({ println: console.log });
const { instance } = await WebAssembly.instantiate(wasmBytes, bridge.imports);
bridge.attach(instance);
const doof = createDoofModule(instance);
```

The Wasm standard library subset (`std/fs`, `std/path`, `std/parse`, `std/blob`, `std/crypto`, `std/time`) lives in [std/wasm](std/wasm). Its numeric and file primitives are provided by `createDoofStdHost(io)`. See [docs/wasm-stdlib.md](docs/wasm-stdlib.md).

Runnable programs are in [examples/doof-wasm](examples/doof-wasm). [docs/doof-wasm-examples.md](docs/doof-wasm-examples.md) walks through them, including host imports.

## Library API

From `src/doof-compiler.do`:

- `compileDoofWasm(source, debugHeap, options)` and `lowerDoofWasmSource(source, options)` for a single in-memory source
- `compileDoofWasmSources(sources, entry, loader)` and `lowerDoofWasmSources(sources, entry, loader)` for module graphs, using a `SourceLoader` callback
- `compileDoofWasmSourcesWithBindings`, which returns the bytes and the JS bindings from a single analysis
- `WasmLoweringOptions` with the independent `boxImmutableStructs` and `synchronousAsync` flags, both false by default

## Language subset

The supported types are `none`, `bool`, `char`, `byte`, `int`, `long`, `float`, `double`, `string`, integer-backed enums, classes, interfaces, unions, `Result`, and arrays and maps of those. The supported constructs include functions, methods, lambdas and captures, `if`/`while`/`for`/`for-of`, `??` and `?.`, `try`, and string and array methods. Class instances and unions use compiler-inserted reference counting.

Generics, string-backed enums, loop labels, loop `else`, and multi-class union method dispatch are not supported yet. [docs/doof-wasm-spec.md](docs/doof-wasm-spec.md) is the authoritative list.

The 2026-09-29 self-compilation baseline is 1.20 MiB of Wasm. It rebuilds the 79-module compiler in 3.3 seconds (three-run median) and uses 116.8 MiB of linear memory.

## Tests

```sh
doof test src
```

This runs the compiler tests, including Wasm execution through Node.js.

The self-hosting gate is documented in [docs/selfhost-compiler.md](docs/selfhost-compiler.md). It uses the scripts in [tools](tools): build the portable compiler entry, generate native reference outputs, then run `tools/selfhost-smoke.mjs` and `tools/selfhost-fixed-point.mjs`.

## Layout

| Path | Contents |
| --- | --- |
| `src/` | Compiler, backend, CLI, and tests (`*.test.do`) |
| `std/wasm/` | Standard library subset for Wasm builds |
| `examples/` | Example programs and the portable self-hosting entries |
| `tools/` | Self-hosting bundle, fixture, smoke, and fixed-point tools |
| `docs/` | Specifications and design notes |

## Documentation

- [Doof source subset](docs/doof-wasm-spec.md)
- [Memory layout and ownership](docs/memory-layout.md)
- [Source environment and stdlib](docs/wasm-stdlib.md)
- [Portable source-compiler entry](docs/selfhost-compiler.md)
- [Self-hosting plan](docs/self-hosting.md)
