# Wasm compiler source environment

`SourceEnvironment` is a caller-owned set of logical source mounts. It does not
import `std/fs`. Pass its `load` method through a `SourceLoader` callback to
`lowerDoofWasmSources` or `compileDoofWasmSources`. The longest matching namespace
wins; matches require a slash boundary. A selected mount owns missing paths too:
an unavailable Wasm std module cannot silently fall back to a native std module.
In-memory `SourceFile` entries still take precedence in the frontend resolver.

The native CLI uses `nativeSourceEnvironment(entry, stdlibRoot)`. It mounts:

- `/std` at the explicitly supplied directory, or the executable's bundled
  `wasm-stdlib` resource directory.
- `/src` and the root package name at the enclosing project's source/package roots.
- Names declared in that root `doof.json` at their local dependency directories,
  including `/doof/src/frontend.do` in this repository.

Other paths use the disk adapter. Loaded records keep their logical `path` and
record the disk location in `physicalPath`. Missing candidates return
`Success(none)`, allowing `foo.do` to fall through to `foo/index.do`; acquisition
failures remain diagnostics. The adapter does not acquire remote dependencies
or recursively discover dependency manifests.

Other hosts can populate `SourceFile[]` or supply mounts backed by embedded
sources. Neither an installed native stdlib nor a global filesystem replacement
is required for that route.

## Implemented standard-library subset

The sources under `std/wasm` target the compiler graph. They are
injected only into programs compiled by doof-wasm; the native bootstrap compiler
continues using its own stdlib.

| Module | Implemented surface | Execution |
| --- | --- | --- |
| `std/parse` | `ParsingError`, decimal `parseByte`, `parseInt`, `parseLong`, `parseFloat`, `parseDouble` | Signed integer parsing in Doof; correctly rounded floating conversion through host primitives |
| `std/blob` | `BlobBuilder {}`, `writeFloat`, `writeDouble`, `build` | Host IEEE bit reinterpretation; little-endian bytes and independent build snapshots in Doof |
| `std/fs` | `IoError`, `readText`, `writeText`, `writeBlob` | Synchronous host operations with scalar handles and status codes |
| `std/path` | `absolute` | Host path resolution |
| `std/crypto` | `sha256HexString` | Synchronous host SHA-256 over raw byte-character strings |
| `std/time` | `MonotonicInstant.now()`, `.durationUntil(other)`, `Duration.toNanos()` | Synchronous host monotonic nanoseconds; signed duration subtraction in Doof |

Integer parsing rejects empty/malformed inputs and checks signed range limits,
including the minimum 64-bit value. Floating parsing supports decimal and
exponent syntax, rejects whitespace, hexadecimal and nonfinite spellings, and
reports overflow and values rounded to zero as errors. This is a compiler
subset, not a complete replacement for the native packages. Directory APIs,
general blob readers/writers, radix parsing, and other std modules are absent.

## Host setup

The generated JavaScript companion exports `createDoofStdHost(io)` alongside
the existing bridge. It supplies numeric primitives and owns I/O handles.
Provide synchronous `readText(path): string`, `writeText(path, text)`,
`writeBlob(path, Uint8Array)`, and `absolute(path): string` callbacks as needed.
Unprovided operations report `IoError.Unsupported`; Node-style error `code`
properties map to the corresponding `IoError` values.

The source frontend also requires `sha256HexString(text): string`. Supply a real,
synchronous SHA-256 implementation returning exactly 64 lowercase hexadecimal
characters. The helper rejects missing callbacks, invalid return values, and
Promises. Crypto callback exceptions propagate as host exceptions, outside Doof
panic recovery. The native API hashes the bytes stored in the string; bridge
character codes 0–255 represent those bytes directly. Do not UTF-8 encode the
JavaScript string again: in Node, use `Buffer.from(text, 'latin1')`. No crypto
callback is needed for the doof-minus encoder.

For enabled frontend timings, supply `monotonicNanos(): bigint`, for example
`() => process.hrtime.bigint()` in Node. Return a nonnegative signed 64-bit
nanosecond count with an arbitrary process-local origin. Values must never
decrease within one host helper; equal consecutive readings are allowed. The
helper validates type, range, and ordering and rejects Promises. Its state
persists across compiler calls; do not reset the clock between calls. Missing
clocks and invalid readings throw host exceptions outside Doof panic recovery.
Disabled `PhaseTimings` reads no clock. Duration subtraction retains native
signed semantics, including negative results for reversed instants.

The helper also supplies `doofStdFormatFloat` and `doofStdFormatDouble` for
`string(float/double)`: six significant digits, trimmed fractional zeros,
scientific notation below exponent -4 or from exponent 6, and native-style
`nan`, `inf`, and `-0` spellings. No formatting callback is required.

```js
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createDoofImports, createDoofModule, createDoofStdHost } from './compiler.js';

const host = createDoofStdHost({
  readText: name => fs.readFileSync(name, 'utf8'),
  writeText: (name, text) => fs.writeFileSync(name, text),
  writeBlob: (name, bytes) => fs.writeFileSync(name, bytes),
  absolute: name => path.resolve(name),
  sha256HexString: text => createHash('sha256').update(Buffer.from(text, 'latin1')).digest('hex'),
  monotonicNanos: () => process.hrtime.bigint(),
});
const bridge = createDoofImports(host);
const { instance } = await WebAssembly.instantiate(wasmBytes, bridge.imports);
bridge.attach(instance);
const compiler = createDoofModule(instance);
```

`Result` values and Doof arrays stay inside Wasm. Read handles return a string
and are closed by the Doof wrapper. Blob output buffers bytes in the host and
commits them on close; handles are removed on both successful and failed closes.
The underlying host callback determines whether committing a file is atomic.

## Verified self-hosting milestone

`testWasmStdlibSelfHostedEncoderMatchesNativeBytes` compiles the existing
`minus-parse`, `minus-validate`, and `minus-wasm` graph with these replacements,
then runs that compiler in Wasm. Its emitted bytes match the native encoder for
int, long, float, and double fixtures, and the emitted modules execute. Invalid
compiler input produces a diagnostic. Numeric/I/O tests also exercise range
errors, signed zero, IEEE bytes, file errors, repeated calls, and independent
byte snapshots across 1024-byte chunk boundaries with heap checks.

`testWasmStdlibSha256MatchesNative` compares Wasm digests with native Doof for
empty input, standard SHA-256 vectors, all 256 byte values (including NUL and
high bytes), and an 8,193-byte string. Repeated calls preserve the heap baseline;
host-contract fixtures reject missing, malformed, and asynchronous primitives.
`testWasmStdlibPhaseTimingsClockContract` runs the frontend's actual timing class,
verifies no disabled clock reads, enabled aggregation and rendered durations,
repeated-call heap cleanup, and invalid or decreasing host clocks.
Float/double formatting fixtures compare native spellings and check heap cleanup.

The full source frontend now executes in the portable compiler entry with the
blob/parse/crypto/time subsets. The maintained source-compiler gate compares
native/Wasm bytes, bindings, diagnostics, and behavior, including std parsing,
missing std modules, caller-loaded imports, and a large literal. Generic classes
and other unsupported source forms remain outside the compiled-program subset;
the current frontend implementation does not need them to execute this corpus.
The native source acquisition adapter stays outside the portable entry. The
compiler source bundle and artifact fixed point are now verified through `tools/selfhost-bundle.do`
and `tools/selfhost-fixed-point.mjs`. Recursive checked-AST heap cleanup remains
outstanding.
