# doof-wasm examples

Each file in `examples/doof-wasm/` is a self-contained source module. Compile
one to Wasm with:

```sh
doof run src/doof-cli.do -- examples/doof-wasm/arithmetic.do /tmp/arithmetic.wasm
```

This also writes the companion JavaScript bindings next to the output, here
`/tmp/arithmetic.js`.

Replace the input and output paths for the other examples:

```sh
doof run src/doof-cli.do -- examples/doof-wasm/control-flow.do /tmp/control-flow.wasm
doof run src/doof-cli.do -- examples/doof-wasm/objects.do /tmp/objects.wasm
doof run src/doof-cli.do -- examples/doof-wasm/nullable-branches.do /tmp/nullable-branches.wasm
doof run src/doof-cli.do -- examples/doof-wasm/byte-arrays.do /tmp/byte-arrays.wasm
doof run src/doof-cli.do -- examples/doof-wasm/host-ffi.do /tmp/host-ffi.wasm
```

To inspect the lowered doof-- without compiling Wasm, add `--dump-minus`:

```sh
doof run src/doof-cli.do -- --dump-minus examples/doof-wasm/control-flow.do /tmp/control-flow.dm
```

The exported functions use primitive WebAssembly parameters and results. For
example, `answer` takes no arguments and returns an `int`; `sumTo` demonstrates
a loop-carried local value; and `readAfterIncrement` constructs a class, calls
an instance method, converts it to an interface, and dispatches through that
interface.

`byte-arrays.do` creates a bounded byte array, updates an indexed value, and
returns a sum that includes the array length.

`nullable-branches.do` combines `else if` branches with an `int | none` return
value. A `case` statement checks the boxed tag and captures the integer arm;
`unwrapOrMinusOne` also demonstrates nullable `else` unwrapping.

`host-ffi.do` declares `println` and `echo` as host imports and exports
`callHost` and `literal`, which take and return strings. Supply the imports
through the generated bindings:

```js
import { readFileSync } from 'node:fs';
import { createDoofImports, createDoofModule } from '/tmp/host-ffi.js';

const host = createDoofImports({ println: console.log, echo: value => value + '!' });
const { instance } = await WebAssembly.instantiate(readFileSync('/tmp/host-ffi.wasm'), host.imports);
host.attach(instance);
const api = createDoofModule(instance);
console.log(api.callHost('hello')); // prints "hello", then "hello!"
console.log(api.literal());         // "ready"
```
