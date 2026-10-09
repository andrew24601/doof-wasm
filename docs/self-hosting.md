# doof-wasm self-hosting plan

The bridge and string literal pool support strings larger than 1024 characters
using the runtime's chunked character-array layout. Export arguments/results and
host import arguments/results share the same marshalling implementation.
Characters remain in the range 0–255; available memory, host string limits, and
the signed 32-bit array length bound still apply.

Literal object graphs now initialize directly from an active Wasm data segment,
including the compact/chunked character storage, wrappers, and reference counts.
The encoder reuses one literal pool throughout each encoding call. The original
25 MB source-compiler probe exceeded V8's function-size limit in its pooled-string
initializer; literals now require no startup code or bulk memory instructions.
Fixtures verify encoding above 262 KB, NUL bytes, large pools, pooled identity,
global initialization order, dynamic allocation after the static heap prefix,
and independent instances.

The regression suite covers string round trips at 1024/1025
characters and 262144/262145 characters, long literals, chunk-crossing substring
copies, memory growth, repeated allocation/release, and invalid input.

The six observed language blockers below are now implemented. The existing
`minus-parse.do`, `minus-render.do`, and `minus-ir.do` modules compile together
through the source backend and execute in Wasm. The integration test exercises
successful parsing, malformed-input diagnostics, rendering, and repeated
parse/render cycles. The portable compiler now has a verified artifact fixed
point through native stage 1 and Wasm stages 2 and 3.

The existing doof-minus parser, validator, and encoder now run together in Wasm
with injected `std/parse`, `std/blob`, `std/fs`, and `std/path` subsets. Integration
tests compare emitted bytes against the native encoder for int, long, float, and
double fixtures and execute the resulting modules. The compiler output protocol
uses the generated `createDoofStdHost(io)` helper. See
[the source environment and stdlib notes](wasm-stdlib.md) for configuration and
the exact supported surface.

The complete source-compiler entry now compiles through the native bootstrap
and executes in Wasm, including the existing analyzer, resolver, and checker.
The maintained smoke gate compiles and runs in-memory and caller-loaded projects,
checks syntax/type/import diagnostics and loader failures, and verifies recovery
and heap cleanup. Native reference fixtures compare Wasm bytes, generated
bindings, diagnostics, and behavior, including a 262,145-character literal and
memory growth. The new frozen 79-module bundle produces identical 1,256,499-byte
Wasm and bindings through the native bootstrap and two successive Wasm compiler
builds. Both Wasm stages pass full-graph heap cleanup. Its three-run self-build
median is 3.300 seconds.

The maintained `examples/selfhost-compiler.do` entry now defines a synchronous
source-loading and artifact-publication ABI. Its native dependency audit finds
70 modules with all dependencies resolved; the bootstrap probe now passes
`JsonEligibilityCache`'s `Map<string, bool>` fields and operations, shared field
reads through nullable class unions, and nullable/concrete equality. Ordinary
field reads through a single nullable class now dispatch on its boxed tag,
passing the `checker-async.do:118` `.reason` blocker. Shared union field writes
also dispatch on concrete tags, passing `checker-annotations.do:39`'s
`.resolvedType` assignment. Focused runtime fixtures cover imported aliases,
different field layouts, simple/compound assignments, mutable captures,
replaced references, single evaluation, and heap/panic cleanup.
Instruction validation errors now preserve their source paths. The injected
`std/crypto.sha256HexString` now executes through a synchronous host primitive,
with native/Wasm digest parity and repeated-call heap checks. See
[the entry protocol and blocker inventory](selfhost-compiler.md).
Array `.pop()` and `.reserve()` now execute in Wasm, including Result failures,
interface/union ownership, reserved-capacity reuse, and heap cleanup.
The injected `std/time` subset runs the real `PhaseTimings` implementation in
Wasm. Disabled timings read no clock; enabled timings accumulate and render
durations through a validated synchronous monotonic host clock. Direct static
methods, implicit instance fields/methods (including closure captures), and
float/double string conversion now execute in Wasm too.
Named free-function values now share the closure ABI, including imported aliases,
host callbacks, Result/reference returns, and panic cleanup. Union type patterns
also execute in Wasm, preserving boxed tags for nested narrowing. The probe now
passes `loadSource` and the `Expression` pattern in `checker-isolation.do`.
Top-level immutable/readonly array literal trees now initialize once per Wasm
instance, with imported access, nested arrays, shared identity, and retained
module roots. Checked code after terminating branches is omitted, and
constant-true loops without a reachable break have no fallthrough. The probe
passes `BUILTIN_TYPES`, the analyzer's redundant fallback return, and the
parser's `looksLikeParenthesizedLambda` loop. Focused fixtures verify runtime
behavior and heap cleanup. String/bool maps now execute empty and populated
construction, `.has`, Result-returning `.get`, `.set`, and `.size`, including
content-based key matching, aliases, imported fields, readonly checks, nested
arrays, captured/nullable maps, chunk growth, and panic cleanup. Lookup is linear;
other map types and operations remain outside this verified subset. The full
frontend now executes through the portable entry acceptance gate.

String `.replaceAll()`, `.trim()`, `.trimStart()`, and `.trimEnd([suffix])` now
execute in Wasm with native parity, chunk-boundary, repeated-call, and heap
fixtures. Replacement uses non-overlapping matches, leaves empty searches
unchanged, and allocates once with a checked 64-bit output-size calculation.
Overflow panics are captured in self-hosting mode and release their inputs.
Trimming uses the native ASCII whitespace set; explicit suffixes include NUL.
The real Doof lexer and parser now execute a byte-character fixture corpus in
Wasm. Tests compare token values/spans, parser statement spans, integer literals,
normalized tag text, and malformed-input diagnostics with native results, then
verify repeated-call and panic cleanup. The fixtures supply the lexer's explicit
`doof_runtime.hpp.doof::char_from_utf8` host import for ASCII character decoding;
general Unicode character support remains outside the verified Wasm subset.

Shared field reads dispatch on concrete class tags and use each class's actual
field layout. Fixtures cover joined scalar/reference types, numeric widening,
imported aliases, closures, optional reads, single receiver evaluation, and heap
cleanup. Presence assertions on multi-type unions preserve boxed tags and capture
`none` failures as language panics in self-hosting mode. Mixed boxed/concrete
equality preserves string content equality and reference identity.

## Goal and scope

Produce an embeddable Wasm compiler that accepts Doof source files, an entry
module, and compilation options, and produces Wasm bytes or diagnostics. It
should compile the doof-wasm compiler chain itself using the existing Doof
frontend. Native Doof retains its normal semantics; compiler compatibility
lowering stays opt-in in doof-wasm.

The host may supply source loading and small synchronous primitives. A CLI,
actors, a scheduler, native C++ emission, package downloads, and the full native
stdlib are outside this milestone. Keep filesystem and process tooling out of
the portable compiler entry.

## Implementation checklist

Start with the entry probe, then iterate on language and stdlib gaps before
end-to-end verification and the fixed point. Mark an item complete when its
acceptance check runs; compiling a module alone does not establish that it works in Wasm.
The broader feature audit below is still required. The current 70-module
compiler graph bootstraps and executes the acceptance corpus; unsupported forms
below are candidates for further source-language coverage, not confirmed blockers
for this graph.

### 1. Completed prerequisites

- [x] Add caller-owned source mounts and injectable stdlib resolution, including
  the `doof/src/frontend` dependency namespace.
- [x] Supply the compiler subset of `std/parse`, `std/blob`, `std/fs`, and
  `std/path`, with generated host bindings and error handling.
- [x] Run the existing doof-minus parser, renderer, validator, and encoder in
  Wasm; compare encoder bytes with native output and execute the emitted Wasm.
- [x] Handle large strings, byte snapshots, Result propagation/unwrapping, and
  expression values carried across control flow.
- [x] Add opt-in immutable struct boxing and eager synchronous async lowering,
  including settled Promises, queue consumption, and language panic capture.
- [x] Verify repeated success/failure calls and heap cleanup. The current suite
  passes 119 tests; the `--self-hosting` CLI smoke test also executes emitted Wasm.

### 2. Establish the portable source-compiler entry and blocker inventory

- [x] Add a maintained source-compiler library example alongside
  `examples/selfhost-encoder.do`, calling `compileDoofWasmSourcesWithBindings` with caller
  sources/loading and explicit self-hosting options.
- [x] Define its host protocol for source files, entry path, options, diagnostics,
  output bytes, and generated import/export metadata. Arrays and Results are
  currently internal to Wasm, so choose a concrete bridge representation or
  handle/callback protocol and document ownership and source encoding.
- [x] Attempt to compile this entry with the native bootstrap compiler and
  `--self-hosting`; record exact module/line diagnostics and reproduction commands.
- [x] Inventory the reachable frontend and backend module graph, separating
  features used to implement the compiler from features it merely parses or
  checks in user programs. Exclude native drivers and editor/cache tooling unless
  the portable entry actually requires them.

### 3. Close the required language and runtime gaps

- [x] Implement array `.pop()` with Result behavior and correct reference
  ownership; frontend dependency traversal and lexer stacks already use it.
- [x] Implement array `.reserve()` without changing length or contents; the
  lexer uses it to size token storage.
- [x] Support named free-function callbacks, including imported declaration
  identity, host imports, reference/Result ownership, and panic cleanup.
- [x] Support union type patterns such as `expression: Expression`, with
  concrete-tag matching, nested narrowing, branch locals, and heap cleanup.
- [x] Initialize top-level immutable/readonly array literal trees once per
  instance, preserving imported access, shared identity, and reference ownership.
- [x] Omit checked dead statements after terminating branches and support
  constant-true loops without fallthrough; verify returns, breaks, and heap cleanup.
- [x] Implement the JSON cache's `Map<string, bool>` fields, empty/populated
  construction, `.has`, `.get`, `.set`, and `.size`; verify content equality,
  aliases, Results, readonly checks, storage growth, and heap/panic cleanup.
- [x] Support shared field reads through class unions, including forced/optional
  nullable reads, joined field types, imported declarations, closure captures,
  presence assertions, and heap/panic cleanup. Ordinary reads through a single
  nullable class also dispatch, including parameters and captured mutable cells.
- [x] Support shared field writes through class unions with identical checked
  mutable field types, including ordinary/forced receivers, imported aliases,
  compound assignments, assigned expression values, replaced references,
  single evaluation, and heap/panic cleanup. Multi-class union method dispatch
  remains unsupported.
- [x] Support equality between boxed unions and concrete values, including
  nullable strings, content equality, reference identity, and temporary cleanup.
- [ ] Audit and implement the remaining collection/string operations required
  by reachable modules, with focused runtime fixtures for each missing operation.
  String replacement and whitespace trimming now execute in Wasm, passing the
  lexer and parser tag-text normalization blockers. The audited JSON cache map
  operations now execute in Wasm. Other map types,
  indexing, iteration, and methods remain unsupported.
- [x] Implement string `.replaceAll()`, `.trim()`, `.trimStart()`, and
  `.trimEnd([suffix])` with native parity, large/chunked strings, ownership,
  optional-call evaluation, overflow recovery, and repeated-call heap fixtures.
- [x] Support string interpolation and required diagnostic formatting, including
  floating-point/enum formatting where the reachable graph needs it.
  Primitive, string, and integer-enum interpolation uses the same formatting as
  `string(value)`; `none` interpolates as native `"null"`. Fixtures verify native
  formatting, imported enum aliases, evaluation order, nested expressions,
  closures, NUL/chunked strings, terminating interpolations, invalid-enum panics,
  and repeated-call cleanup. Collection and boxed-union interpolation remains
  outside this supported formatting subset.
- [ ] Support nested lexical blocks and any additional control-flow, pattern,
  destructuring, or construction forms exposed by the entry probe.
  Shared `.kind` reads through the nullable `ResolvedType` union now execute in
  focused Wasm fixtures and pass the entry probe. Ordinary single-class nullable
  reads also execute and pass `checker-async.do:118`; shared union writes pass
  `checker-annotations.do:39`. Nested lexical blocks and additional forms still
  require the reachable-graph audit.
- [ ] Audit generic declarations/instantiations, static members, constructor
  factories, `never` results, and module initializers. Implement only the forms
  required by the compiler graph, preserving frontend checks and native behavior.
  Direct static method calls and implicit instance-member access are implemented;
  named function values and array literal module initializers are implemented.
  Other initializer and generic forms still require the reachable-graph audit.
- [x] Run real lexer/parser fixtures in Wasm, including native token/span and
  tag-text parity, malformed input, parser panic recovery, and repeated-call heap
  cleanup for the byte-character corpus.
- [x] Run analyzer/resolver/checker fixtures with imports and type errors.
  The portable entry gate covers successful imports, std imports, malformed
  input, return-type mismatches, unknown names, absent modules, and loader failure.

### 4. Supply the remaining frontend stdlib dependencies

- [x] Provide `std/crypto.sha256HexString`, used by the analyzer, with native/Wasm
  digest parity fixtures. A host primitive is acceptable; a placeholder hash is not.
- [x] Provide the `std/time` surface used by `PhaseTimings`, including
  `MonotonicInstant` and duration conversion. Verify disabled timings read no
  clock and enabled timings use the documented host clock contract.
- [x] Extend other stdlib surfaces only as required by the reachable graph;
  verify an absent Wasm module produces a diagnostic rather than native fallback.
  The source compiler executes with the injected blob/parse/crypto/time modules;
  the native-parity corpus verifies `std/unavailable` remains a missing module.
- [x] Bundle the required compiler/dependency/stdlib sources under stable logical
  paths, and demonstrate compilation without an installed Doof source tree or
  native stdlib. Keep host application module loading configurable.
- [x] Compile and execute the complete source-compiler entry. Keep each newly
  discovered blocker reproducible until a regression fixture verifies the fix.

### 5. Verify the embeddable compiler end to end

- [x] Instantiate the compiler through its documented host API and compile an
  in-memory source module; instantiate and execute the resulting Wasm.
- [x] Compile multi-module projects using caller-owned loading, including std
  imports, missing modules, loader failures, and semantic diagnostics.
- [x] Compare native-bootstrap and Wasm-compiler output on a representative
  fixture corpus, checking generated bindings as well as Wasm bytes and behavior.
- [ ] Exercise repeated compilation after both valid and invalid input, large
  modules, memory growth, and heap/host-handle cleanup.
  The 12-case acceptance corpus passes, but a recursive factorial source retains
  230 blocks per compilation (5,780 baseline; 6,010/6,240/6,470 after three calls).
  The full compiler build also records retained blocks. Fix recursive checked-AST
  ownership before treating compiler-instance reuse as fully verified.
- [x] Document the minimum host capabilities, Wasm exception-handling requirement,
  encoding limits, API ownership, and unsupported source features.

### 6. Establish a compiler fixed point

- [x] Build stage 1: use the native bootstrap to compile the portable compiler
  source graph into Wasm with self-hosting options enabled.
- [x] Build stage 2: run stage 1 in Wasm to compile the same compiler graph,
  sources, options, and stdlib mounts into a second Wasm compiler.
- [x] Build stage 3: run stage 2 to repeat that compilation. Compare stage 2 and
  stage 3 Wasm and binding artifacts byte-for-byte, explaining or removing any
  nondeterministic output.
- [x] Run the same compilation/execution fixture corpus through stages 1 and 2,
  and automate the fixed-point check as a maintained regression harness.

## Reproduce the bootstrap attempts

From the repository root:

```sh
doof build src/doof-cli.do -o build/bootstrap-host
build/bootstrap-host/doof-wasm src/minus-cli.do build/selfhost-minus.wasm
```

The CLI attempt now resolves the required std modules but stops on the implicit
`println` builtin in `minus-cli`. CLI argument/startup wiring also remains
separate from the exported-library protocol.

An exported encoder entry avoids those CLI requirements:

```sh
build/bootstrap-host/doof-wasm examples/selfhost-encoder.do build/selfhost-encoder.wasm
```

Instantiate that module using its generated `createDoofStdHost(io)` and
`createDoofImports(host)` helpers, then call `compile(source, outputPath)`. It
returns `"ok"` after writing bytes through the host's `writeBlob` callback, or
returns a compiler/I/O error. The integration test uses this maintained entry.

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
| Loop exits | `break`, `continue`, labeled exits | Supported for while, for, and for-of loops, including exits to enclosing loops |
| String concatenation | `source + "x"` | Supported with a fresh chunk-backed string |
| Splitting source into lines | `source.split("\n")` | Supported, including empty fields and empty separators |
| Formatting diagnostics and names | `string(value)` | Supported for int, long, byte, bool, char, and string |
| LEB128 encoding | `value % 128`, `value \ 128` | Supported with signed int/long and unsigned byte remainder |

Additional requirements exposed by the compiler sources are supported too:
short-circuit boolean operators, scalar top-level constants, array literal module
initializers, and type aliases,
plain `try` propagation, Result constructor calls, discarded bindings,
construction field shorthand, and forced access on strong nullable receivers.
Source and synthesized runtime functions carry expression temporaries explicitly
across branches.

Collection/boxed-union interpolation, arbitrary module initializers, and loop
`then` clauses remain unsupported. Primitive and integer-enum
interpolation and enum string formatting now execute in Wasm. Numeric parsing and float-byte
encoding are provided by the injected stdlib subset. Byte snapshots, enum
backing values, Result declaration-else captures, and forced Result unwraps are
supported too. The fixture byte comparison is now in place for the doof-minus
encoder; the complete source compiler now reproduces its Wasm and bindings
through stages 2 and 3 with the frozen source bundle below.

## Portable source-compiler acceptance gate

From the repository root, build stage 1 with heap inspection enabled, generate
native references, and run the maintained host harness:

```sh
doof build src/doof-cli.do -o build/bootstrap-host
build/bootstrap-host/doof-wasm --self-hosting --debug-heap examples/selfhost-compiler.do build/selfhost-compiler.wasm
doof run tools/selfhost-fixtures.do -- build/selfhost-references.json
node tools/selfhost-smoke.mjs build/selfhost-compiler.wasm build/selfhost-compiler.js std/wasm build/selfhost-references.json
```

The 14-reference corpus includes arithmetic, imports, enum interpolation, std
numeric parsing, closures, layered Result/none handling, removed-prefix syntax
diagnostics, a 262,145-character literal, syntax/type/name/import diagnostics,
an absent std module, and successful compilation after failures.
Successful artifacts match native bytes and bindings exactly and execute; failed
calls match native diagnostics and publish nothing. The gate also checks loader
failure, repeated recovery, compiler heap baselines, memory growth, and disabled
timings. Without the optional reference JSON it runs only the original smoke
checks. The separate frozen-source gate below verifies the compiler fixed point.

Hex publication now combines bounded 256-byte leaves in a balanced tree,
copying O(n log n) characters instead of growing one string for every byte.
Runtime/native fixtures cover every byte value, empty input, leaf/chunk boundaries,
large payloads, and repeated-call cleanup. Publication remains synchronous and
retains the original `compilerOutput(wasmHex, bindings)` ABI.

## Compiler artifact fixed point

From the repository root:

```sh
doof run tools/selfhost-bundle.do -- examples/selfhost-compiler.do build/fixed-point
node tools/selfhost-fixed-point.mjs build/fixed-point/sources.json build/fixed-point/stage1.wasm build/fixed-point
doof run tools/selfhost-fixtures.do -- build/selfhost-references.json
node tools/selfhost-smoke.mjs build/fixed-point/stage1.wasm build/fixed-point/stage1.js std/wasm build/selfhost-references.json
node tools/selfhost-smoke.mjs build/fixed-point/stage2.wasm build/fixed-point/stage2.js std/wasm build/selfhost-references.json
```

The native tool snapshots all 70 reachable sources, including the four injected
stdlib modules, under `/compiler`, `/doof`, and `/std`. It builds stage 1 from
these same snapshots with both self-hosting options and heap inspection enabled.
The Wasm host validates each source digest, projects UTF-8 source bytes onto the
byte-character bridge, and loads only from this bundle. No installed Doof source
tree or native stdlib is consulted by stages 2 and 3. Each stage gets a fresh
Wasm instance; timings stay disabled.

Verified on 2026-09-28: native stage 1, Wasm stage 2, and Wasm stage 3 produce
identical 9,649,825-byte Wasm and 118,379-byte JavaScript artifacts.

| Artifact | SHA-256 |
| --- | --- |
| Wasm, all three stages | `4707f891a0a2db8d23c24c2859ca9a3a42737aeddbeec7528d25ec6cdc24aefe` |
| Bindings, all three stages | `b9b9f9fdcaabeae1df2c7968da96420ae4ff3fdc789713adf5f3ec77f720af13` |
| Frozen source bundle | `989624fd0e5cd43a293b39ee7076057dba16d9beeeaca28605185eef3602b399` |

Both stages 1 and 2 pass the 12-case native reference/execution corpus. The
fixed-point host writes `result.json` with comparisons, hashes, timings, memory
size, and bounded heap summaries. Artifact equality is checked independently of
heap cleanup. `--resume-stage3` can check saved stage-2 artifacts with the same
bundle after an interrupted verification.

The artifact fixed point is established. Complete compilation cleanup is not:
recursive source functions retain blocks, consistent with strong cycles through
checked AST `CallExpression.resolvedFunction` links. The stage-3 full-graph run
retained 1,547,452 blocks above its 5,780-block initialization baseline. The
harness scans heap headers and stores bounded samples, avoiding full decoded dumps of a large heap.
Fresh instances isolate the fixed-point stages; reusing an instance for recursive
compilations remains an ownership issue to fix.

The subsequent structured IR replacement uses one `MinusFunction.body` region
tree and removes flat function bodies, the expression-carrying pass, and the
program-counter dispatcher. The updated 72-module graph reaches a native/stage-2/
stage-3 fixed point at **2,832,417-byte Wasm** and **121,599-byte bindings**.
All 138 native tests and 12 native/Wasm reference cases pass. Full-graph stages
still retain 1,620,936 unexpected live blocks and change 89 roots, with no missing
roots; source-graph changes mean these counts are not a controlled comparison
with the earlier AST retention count.

The subsequent reachability, scalar simplification, local allocation, and
ownership passes reduce the updated 76-module compiler to 1,628,131-byte Wasm
and 124,599-byte bindings. Native, stage 2, and stage 3 match byte-for-byte;
149 native tests and all 12 native/Wasm comparison cases pass. Rebuilds take
146.51/143.05 seconds and allocate 165,675,008 bytes of linear memory. The
full-graph checked-AST retention issue remains.

## Opt-in compiler compatibility mode

`doof-wasm --self-hosting input.do output.wasm` enables two independent library
options, `WasmLoweringOptions.boxImmutableStructs` and
`WasmLoweringOptions.synchronousAsync`. Both default to false. Pass options as the
last argument to `lowerDoofWasmSource`, `lowerDoofWasmSources`, `compileDoofWasm`,
or `compileDoofWasmSources`. For example:

```doof
options := WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true }
bytes := compileDoofWasm(source, false, options)
```

Immutable structs use the existing reference-counted class representation.
Structs with reassignable fields are rejected: aliasing those boxed values would
change struct copy behavior. The native Doof compiler and its struct semantics
remain unchanged.

Async calls and blocks execute eagerly on the current thread. Each Promise
stores a settled `Result<T, string>`; repeated `.get()` calls return the same
completion. Promise-array `.takeFirstCompleted()` removes the first element,
including through aliases to that array, and returns its completion. An empty
queue returns Failure. There is no scheduler, parallelism, or actor support.
The existing front end still checks async boundaries and isolation contracts.

Language `panic(message)` and failed forced Result unwraps become tagged Wasm
exceptions in this mode. Async execution and inline `catchPanic` lambdas capture
them as Failure while releasing frame-owned references. Escaping panics are
translated to JavaScript Error by `createDoofModule`. This mode requires Wasm
exception handling support. Raw export callers handling `__doof_panic_tag` own
its string payload and must release it through `__doof_ffi_release`. Ordinary
Wasm traps and exceptions thrown by host imports are outside this capture path.

These compatibility primitives now support the compiler artifact fixed point
described above. Broader source coverage still needs work. Checked-AST cycles
are now released after lowering, so full self-compiles leave a clean heap.

## Result/none syntax migration, 2026-10-02

Compiler sources, test fixtures, and native bootstrap tools use postfix `!` and
`?` in place of the removed prefix forms. Result/none lowering follows the
frontend's absence layers, preserves a Result-valued optional access's own
Failure, and supports continuing discarded declaration-else handlers and try
assignment. Intrinsic Result arms compare their payloads by value. Validation
keeps `Success(none)` as a legitimate instruction-without-result outcome by
matching the Result explicitly instead of using declaration-else.

The 84-module frozen graph passes all 192 native tests and 14 native/Wasm
reference cases. Native stage 1 and Wasm stages 2/3 produce identical
**1,523,658-byte Wasm** and identical bindings. Wasm stages rebuild in 3.637 and
3.602 seconds, using 139,984,896 bytes of linear memory. Both retain all 8,908
baseline heap roots, with no unexpected live allocations, changed roots, or
missing roots; the eight-byte none header remains zero.

The Wasm SHA-256 is
`1c6af8fe24e0b77e9be2de03487112c70b6edf1fbfdd2e052d06e3cb8d99b775`;
the bindings SHA-256 is
`20b79cbf1c3a66ec63fbf4eea4caa09ced9ed7a1f0831d41a032eb4567b2798c`.
The maintained source boundary still excludes `??=`, Result statement-else,
try destructuring, and general checked catch/as flows.
