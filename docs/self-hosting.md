# doof-minus self-hosting attempt

The bridge and string literal pool support strings larger than 1024 characters
using the runtime's chunked character-array layout. Export arguments/results and
host import arguments/results share the same marshalling implementation.
Characters remain in the range 0–255; available memory, host string limits, and
the signed 32-bit array length bound still apply.

`doof test src` passes all 60 tests, including string round trips at 1024/1025
characters and 262144/262145 characters, long literals, chunk-crossing substring
copies, memory growth, repeated allocation/release, and invalid input.

The six observed language blockers below are now implemented. The existing
`minus-parse.do`, `minus-render.do`, and `minus-ir.do` modules compile together
through the source backend and execute in Wasm. The integration test exercises
successful parsing, malformed-input diagnostics, rendering, and repeated
parse/render cycles. No complete Wasm compiler fixed point has been produced.

The compiler still needs standard-library resolution/runtime replacements,
a compiler output host protocol, and a bootstrap verification harness. The
full Doof source front end still depends on the native compiler's analyzer and
checker.

## Reproduce the bootstrap attempts

From the repository root:

```sh
doof build src/doof-cli.do -o build/bootstrap-host
build/bootstrap-host/doof-wasm src/minus-cli.do build/selfhost-minus.wasm
```

The CLI attempt fails while resolving `/std/fs.do`. Its loader currently reads
logical import paths as filesystem paths; it does not map `std/*` to the bundled
standard library. Compiling the library also requires `std/parse` and `std/blob`.
Mapping those packages alone will not provide native implementations for this
backend.

To probe the parser without the filesystem or binary encoder dependencies, save
this source as `build/selfhost/parser-entry.do`:

```doof
import { parseDoofMinus } from "../../src/minus-parse"
import { MinusModule } from "../../src/minus-ir"

export function parse(source: string): string {
  case parseDoofMinus(source) {
    success: Success<MinusModule> -> { return "ok" }
    failure: Failure<string> -> { return failure.error }
  }
}
```

Then run:

```sh
build/bootstrap-host/doof-wasm build/selfhost/parser-entry.do build/selfhost/parser.wasm
```

This parser entry now compiles. Regression tests also compile the renderer
with it and execute the pair in Node. The original focused probes now have
the following results:

| Existing compiler requirement | Probe | Current result |
| --- | --- | --- |
| Compound assignment | `value += 1` | Supported on locals, fields, and array elements |
| Loop exits | `break`, `continue` | Supported for unlabeled while, for, and for-of loops |
| String concatenation | `source + "x"` | Supported with a fresh chunk-backed string |
| Splitting source into lines | `source.split("\n")` | Supported, including empty fields and empty separators |
| Formatting diagnostics and names | `string(value)` | Supported for int, long, byte, bool, char, and string |
| LEB128 encoding | `value % 128`, `value \ 128` | Supported with signed int/long and unsigned byte remainder |

Additional requirements exposed by the compiler sources are supported too:
short-circuit boolean operators, scalar top-level constants and type aliases,
plain `try` propagation, Result constructor calls, discarded bindings,
construction field shorthand, and forced access on strong nullable receivers.
Source and synthesized runtime functions carry expression temporaries explicitly
across branches.

Floating-point/enum string formatting, arbitrary module initializers, labeled
loop exits, and loop-else remain unsupported. Standard-library resolution and
runtime replacements for numeric parsing and float-byte encoding are still
required to hoist the encoder and CLI. Once the full compiler runs in Wasm, a
bootstrap check should compare its emitted bytes against the native compiler
on fixtures before attempting a compiler fixed point.
