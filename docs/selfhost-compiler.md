# Portable source-compiler entry

`examples/selfhost-compiler.do` is the maintained library entry for the full
source compiler. It uses `compileDoofWasmSourcesWithBindings`, which analyzes and
lowers once and returns bytes and JavaScript bindings from that same module.
The byte-only `compileDoofWasmSources` API remains available.

**Bootstrap status:** the complete 79-module entry graph compiles to Wasm and
executes through its generated host API. The analyzer, resolver, checker,
lowerer, encoder, and binding renderer compile in-memory and caller-loaded
projects. The maintained acceptance gate compares 12 native/Wasm reference
cases, including exact bytes and bindings, diagnostics, imported enum
interpolation, a large literal, and execution of generated programs. Repeated
success/failure calls in that corpus preserve compiler heap roots and exercise
memory growth.
The frozen compiler source graph now has a verified native/stage-2/stage-3
artifact fixed point. The 2026-09-29 baseline is 1,256,499 bytes, rebuilds
itself in 3.300 seconds (three-run median), and passes full-graph heap cleanup
and the 12-case corpus.

## Host protocol

The generated export is `compile(source, entry, debugHeap): string`.
`source` is the entry module's contents; `entry` is its absolute logical path,
including `.do`. Other source files are supplied by the host loader. The entry
always enables both self-hosting options (`boxImmutableStructs` and
`synchronousAsync`); `debugHeap` controls heap inspection in both emitted
artifacts. Normal frontend checks still apply to the program being compiled.

The host implements three imports:

| Import | Contract |
| --- | --- |
| `sourceStatus(path): int` | Synchronously acquire a source snapshot. Return 0 for absent, 1 for found, or 2 for an acquisition failure. |
| `sourceValue(): string` | Return the source text or error message saved by the immediately preceding `sourceStatus` call. Called only for status 1 or 2. |
| `compilerOutput(wasmHex, bindings): none` | Receive both artifacts after successful compilation. Decode lowercase hex into bytes; `bindings` is the generated ES module, containing import/export bridge metadata. |

A successful call publishes exactly once and returns the empty string. A
compiler or loader failure returns a diagnostic string and publishes nothing.
Unknown status codes produce `invalid sourceStatus response`. Missing candidates
remain `Success(none)` internally, allowing the resolver's `.do`/`index.do`
fallback. Acquisition failures remain `Failure<Diagnostic>` internally. Hosts
must supply consistent sources for the duration of a call, including the
compiler/dependency sources and `/std` sources when compiling the compiler itself.
There is no native stdlib fallback or package acquisition in this entry.

All bridge strings contain character codes 0–255, matching the current Wasm
string runtime. This is a byte-character source interface, not automatic UTF-8
decoding. Reject unsupported characters before acquisition or publication.
Wasm bytes use two ASCII hexadecimal characters per byte; metadata and diagnostic
strings use the same character encoding as source text. This initial protocol
avoids crossing the ABI with arrays, Results, or heap handles. Hex conversion
uses bounded 256-byte leaves and balanced concatenation, with O(n log n) copied
characters. It still materializes the complete hex string before publication;
streaming publication is a possible later protocol revision.

`createDoofImports` copies source strings into Wasm and releases temporary
arguments/results; host strings remain host-owned. `compilerOutput` receives
host-owned copies; retain them if needed after it returns. No host handles
survive a completed acquisition. Each compile call owns its internal arrays,
Results, and artifacts. Publication is synchronous: a host that needs atomic
storage should commit both artifacts together. Thrown host exceptions propagate
outside compiler diagnostic/panic recovery; use status 2 for expected acquisition
failures. Self-hosting mode requires Wasm exception handling support.

Instantiate the bootstrapped entry using its generated
`createDoofImports` and `createDoofModule` helpers, with `createDoofStdHost` for
the required numeric primitives, plus the three callbacks above. Filesystem or
process callbacks are not needed by the portable entry. Provide the synchronous
`sha256HexString` callback documented in [the stdlib host contract](wasm-stdlib.md).
If timings are enabled, also supply the synchronous `monotonicNanos` callback
documented there. Disabled timings read no clock.

## Execution and native-parity gate

After building the compiler with `--debug-heap`, run:

```sh
doof run tools/selfhost-fixtures.do -- build/selfhost-references.json
node tools/selfhost-smoke.mjs build/selfhost-compiler.wasm build/selfhost-compiler.js std/wasm build/selfhost-references.json
```

The native tool uses the same logical `/main.do`, caller-owned dependency paths,
injected stdlib, and self-hosting/debug options as the Wasm entry. This permits
byte-for-byte comparison of Wasm and bindings. It does not compare artifacts
whose source paths or options differ. Fixture generation is native tooling;
executing the prebuilt compiler requires no installed Doof compiler or native
stdlib. The host harness supplies only the bundled Wasm std sources on demand.

The runtime host needs Wasm32 linear memory with growth, bulk memory, and Wasm
exception handling. In JavaScript use the generated string/import/export bridge,
`createDoofStdHost` for scalar numeric helpers, and a real synchronous
`sha256HexString` implementation. Supply `monotonicNanos` only when timings are
enabled. The real lexer also imports
`doof_runtime.hpp.doof::char_from_utf8`; the verified ASCII corpus uses
`value => value.charCodeAt(0)`. That adapter does not establish general UTF-8 or
Unicode source support. No filesystem, process, actor, or scheduler service is
required by the portable compiler.

The compiled programs remain limited to the documented [source subset](doof-wasm-spec.md).
Interpolation currently supports primitives, strings, `none`, and integer-backed
enums; collection and boxed-union interpolation has an actionable lowering
diagnostic. Nested lexical blocks, generic execution, string-backed enums, and
other unsupported source forms remain outside this milestone.

## Reachable graph and blockers

Run the maintained native audit and the actual lowering probe from the repository
root:

```sh
doof run tools/selfhost-inventory.do -- examples/selfhost-compiler.do
doof build src/doof-cli.do -o build/bootstrap-host
build/bootstrap-host/doof-wasm --self-hosting --debug-heap examples/selfhost-compiler.do build/selfhost-compiler.wasm
```

The audit discovers 70 modules with no unresolved dependencies. Instruction
validation errors preserve source paths.

The previous `/doof/src/checker-async.do: line 118` diagnostic,
`any has no field reason`, is now covered by runtime fixtures. The local still
uses boxed `any` storage; ordinary field reads dispatch on its concrete tag,
including a union with only one non-none class. This reproduction now executes
in Wasm:

```doof
class Violation { reason: string }
function find(ready: bool): Violation | none =>
  if ready then Violation { reason: "unsafe" } else none
export function reason(ready: bool): string {
  violation := find(ready)
  if violation != none { return violation.reason }
  return "safe"
}
```

The previous string blockers now have runtime fixtures for replacement,
whitespace trimming, explicit trimEnd characters, empty searches, overlapping
candidate matches, literal replacement markers, chunk/radix boundaries,
aliases/captures, imported functions, optional-call evaluation, overflow panic
recovery, and heap cleanup. Replacement allocates once and checks the output
length with 64-bit arithmetic. Real lexer/parser fixtures compare token values
and spans, statement spans, integer literals, tag-text normalization, and strict
parser diagnostics with native execution. The byte-character fixtures supply
`doof_runtime.hpp.doof::char_from_utf8` for ASCII decoding; they do not establish
general Unicode character support or complete frontend execution.

The previous shared-field blocker has runtime fixtures for ordinary, forced,
and optional reads through class unions, including imported class aliases,
different field offsets, joined value types, numeric widening, array/reference
fields, and captured receivers. Receiver expressions execute once. Multi-type
presence assertions preserve boxed tags; `none` raises a language panic in
self-hosting mode. Repeated calls, caught panics, and escaping panics release
temporary references. Shared union writes now dispatch on concrete tags when
all classes have a mutable field of the same checked type. Fixtures cover
imported aliases, different field layouts, ordinary/forced receivers,
simple/compound assignments, assignment expression results, boxed union fields,
array/reference replacement, captured receivers, single evaluation, and panic
cleanup. Multi-class union method dispatch remains unsupported.
The subsequent nullable/concrete equality blocker at
`analyzer.do:549` also has runtime fixtures covering string content equality,
reference identity, scalar values, both operand orders, and heap cleanup.

The previous JSON cache blocker is covered by Wasm fixtures for
`Map<string, bool>` empty/populated literals, `.has`, Result-returning `.get`,
`.set`, and `.size`. Keys compare by string content, updates preserve the map's
size, and aliases share storage. The fixtures cover imported cache fields,
readonly checks, captures and nullable maps, nested arrays, long keys, chunk
growth, repeated missing-key Results, failed forced unwraps, and heap cleanup.
This compiler subset uses linear lookup and does not yet support other map
types, indexing, iteration, snapshots, deletion, or module-level map initializers.

The previous named-function callback blocker is covered by runtime fixtures for
local and imported functions, renamed exports, host callbacks, reference/Result
signatures, recursive and escaping callbacks, and panic cleanup. Callbacks use
owned closure interfaces with a capture-free forwarding class per declaration.
Union type patterns, including aliases like `Expression`, match concrete tags
and retain the boxed subject for further narrowing. Both features have repeated
execution and heap-cleanup checks.

The previous `BUILTIN_TYPES` blocker is covered by array literal initializer
fixtures for primitive widths, strings, empty/nested arrays, imported aliases,
scalar constant references, local shadowing, mutable interiors, and independent
instances. Module roots remain live across calls; temporary reads release their
references. The probe also passes `analyzer.do:320` (a fallback return after a
terminating `case`) and `parser-expressions.do:580` (a constant-true scanning loop).
Control-flow fixtures exercise returns, loop exits, and repeated-call heap cleanup.

The inventory uses analyzer dependency discovery with serial parsing. It does
not run the checker or prove that those modules lower or execute in Wasm. Missing
stdlib dependencies are reported separately from discovered modules. Rerun it
after changing compiler dependencies; its output lists every discovered path.

| Reachable source family | Responsibility |
| --- | --- |
| `examples/selfhost-compiler`, `src/doof-compiler` | Host boundary, source compilation, artifact generation |
| `doof/src/frontend`, `analyzer`, `resolver`, `semantic`, `diagnostics`, `phase-timings` | Acquisition, analysis, semantic input, diagnostics, optional timing |
| `doof/src/lexer`, `parser`, `parser-declarations`, `parser-statements`, `parser-expressions`, `parser-types`, `ast`, `ast-walk` | Compiler implementation of lexing/parsing and AST traversal |
| `doof/src/checker` and its reachable checker modules, `json-semantics` | Type checking, generic/isolation/actor validation, metadata checks |
| `src/doof-lowering*` | Source lowering, closures, control flow, synthesized array/string/map/Result/Promise runtime |
| `src/minus-ir`, `minus-parse`, `minus-layout`, `minus-validate`, `minus-optimize`, `minus-wasm`, `minus-render`, `minus-js`, `wasm-std-host` | IR validation, dead block-argument elimination, Wasm lowering, module encoding, debug rendering, generated bindings |
| `src/minus-wasm-instructions`, `minus-wasm-peepholes`, `minus-wasm-ordering` | Backend instruction stream, Wasm peepholes, local/function ordering, operand serialization, and relocation |
| `/std/blob/index`, `/std/parse/index`, `/std/crypto/index` | Existing compiler numeric/byte primitives and analyzer source hashing |
| `/std/time/index` | Optional timing through synchronous host nanoseconds |

The graph excludes `doof/src/compiler`, native emission, native compiler/CLI
drivers, package acquisition, filesystem adapters, and editor/cache drivers.
Some shared analysis/checker modules contain editor/cache or actor checking
branches. Those branches are part of the reachable source modules; hoisting them
does not mean that the Wasm compiler needs an editor, cache service, actors, or
a scheduler. In particular, AST declarations for generics, actors, static
members, and `never` describe accepted user programs; their existence alone does
not establish a need to execute those features in the compiler implementation.

Concrete implementation uses already identified:

| Source location | Requirement | Status |
| --- | --- | --- |
| `doof/src/frontend.do:102`, `analyzer.do:257`, `lexer.do:334–696` | Array stack `.pop()` | Implemented; scalar/reference/union Result and ownership fixtures execute in Wasm |
| `doof/src/lexer.do:289` | Array `.reserve()` | Implemented; capacity, aliases, contents, chunk reuse, and heap fixtures execute in Wasm |
| `doof/src/analyzer.do:153,196` | Real `sha256HexString` | Implemented; synchronous host primitive with native/Wasm parity and heap fixtures |
| `doof/src/phase-timings.do:15,20,41` | `MonotonicInstant.now()`, duration conversion, double formatting | Implemented; the actual PhaseTimings class executes with disabled/enabled timing and heap fixtures |
| `examples/selfhost-compiler.do:25` | Named free-function value `loadSource` | Implemented; callbacks, imports, Result/reference ownership, and panic cleanup execute in Wasm |
| `doof/src/checker-isolation.do:178` | Union type pattern `expression: Expression` | Implemented; tag matching, nested narrowing, branch locals, and heap cleanup execute in Wasm |
| `doof/src/analyzer.do:85` | Top-level readonly array `BUILTIN_TYPES` | Implemented; initializer, import, ownership, and instance fixtures execute in Wasm |
| `doof/src/analyzer.do:320` | Checked fallback return after a terminating branch | Implemented; dead statements after branches and loop exits are omitted |
| `doof/src/parser-expressions.do:580` | Constant-true scanner loop without fallthrough | Implemented; return/break and heap fixtures execute in Wasm |
| `doof/src/json-semantics.do:24` | `Map<string, bool>` fields, empty construction, `.has`, `.get`, `.set` | Implemented; map aliases, Results, key equality, growth, and heap/panic fixtures execute in Wasm |
| `doof/src/checker-validation.do:168` | Shared `.kind` field access through nullable `ResolvedType` union | Implemented; dispatch, joined fields, imports, presence assertions, and heap/panic fixtures execute in Wasm |
| `doof/src/analyzer.do:549` | Nullable string compared with a concrete string | Implemented; boxed/concrete equality and heap fixtures execute in Wasm |
| `doof/src/lexer.do:167` | Numeric literal separator removal with string `.replaceAll()` | Implemented; native parity, chunk/ownership/overflow fixtures, and the real lexer execute in Wasm |
| `doof/src/parser-expressions.do:479–480` | Tag-text normalization with `.trimStart()` and `.trimEnd()` | Implemented; native whitespace/suffix parity and real parser tag-text fixtures execute in Wasm |
| `doof/src/checker-async.do:118` | Ordinary field read through a single nullable class | Implemented; branch, parameter, mutable capture, long-string, and heap/panic fixtures execute in Wasm |
| `doof/src/checker-annotations.do:39` | Shared `.resolvedType` field assignment through `TypeAnnotation` union | Implemented; same-type mutable fields, imported aliases, compound assignments, references, evaluation order, and heap/panic fixtures execute in Wasm |

Broader collection/string operations, lexical blocks, construction forms,
generic instantiations, and initializers still need the feature audit and runtime
fixtures in `self-hosting.md`; they do not block the current compiler graph.
The compiler artifact fixed point is verified; recursive checked-AST ownership
remains an outstanding runtime issue.

## Frozen-source fixed-point gate

```sh
doof run tools/selfhost-bundle.do -- examples/selfhost-compiler.do build/fixed-point
node tools/selfhost-fixed-point.mjs build/fixed-point/sources.json build/fixed-point/stage1.wasm build/fixed-point
```

The bundle contains the compiler, frontend dependency, and injected stdlib source
snapshots under stable `/compiler`, `/doof`, and `/std` logical paths. The native
bootstrap and both Wasm stages use identical source bytes, entry, and options.
The host resolves solely from the snapshot and verifies source hashes before
compilation. Stages run in separate instances and compare both artifacts exactly.

The 2026-09-28 run produced identical 9,649,825-byte Wasm and 118,379-byte bindings
in all three stages. Both stages 1 and 2 also passed the full native reference
corpus. Exact digests and reproduction notes are in [the self-hosting tracker](self-hosting.md#compiler-artifact-fixed-point).
`result.json` distinguishes artifact equality from heap cleanup; recursive checked
ASTs retain allocations even though the emitted artifacts are stable.

The subsequent code-generation improvements also pass this gate: native stage 1
and Wasm stages 2/3 produce identical 4,276,753-byte Wasm and 119,838-byte bindings
from the updated compiler source graph. The 123 native tests and all 12
native-reference cases pass. Static string object graphs initialize through an
active data segment, array machinery uses shared helpers, dispatch uses
`br_table`, and normal/panic exits share cleanup. Full-graph checked-AST retention
remains unchanged.

Dead block-argument elimination also passes this gate. The updated 71-module
compiler graph produces identical 3,760,516-byte Wasm and 120,348-byte bindings
in all three stages. All 132 native tests and 12 native-reference cases pass.
The pass removes unused parameter positions and corresponding edge arguments
while preserving custom-destructor lifetimes. Full-graph checked-AST retention
remains unchanged.

The structured IR replacement also reaches a fixed point. The updated 72-module
graph produces identical **2,832,417-byte Wasm** and **121,599-byte bindings**
through native stage 1 and Wasm stages 2/3. All 138 native tests and all 12
native/Wasm reference cases pass. Function bodies now store one region tree;
scope and loop regions emit direct branches with no program-counter dispatcher
or `br_table` instructions. Dominating values replace immutable forwarding
copies. The Wasm rebuilds take 201.52 and 192.56 seconds. Full-graph heap cleanup
remains outstanding.

The earlier 76-module graph also reaches a native/stage-2/stage-3 fixed point
after reachability pruning, scalar simplification, local reuse, stack emission,
and conservative ownership optimizations. Wasm is 1,628,131 bytes; bindings are
124,599 bytes. All 149 native tests and 12 native/Wasm reference cases pass.
The full-graph checked-AST retention issue remains.
