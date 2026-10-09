import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

function checkSource(source: string, name: string, script: string, setup: string = "", otherSources: SourceFile[] = []): none {
  sources := [SourceFile { path: "/main.do", source }]
  for other of otherSources { sources.push(other) }
  module_ := lowerDoofWasmSources(sources, "/main.do")!
  wasmPath := "/tmp/doof-control-" + string(pid()) + "-" + name + ".wasm"
  jsPath := "/tmp/doof-control-" + string(pid()) + "-" + name + ".mjs"
  writeBlob(wasmPath, (encodeDoofMinus(module_, true)!).cloneReadonly())!
  writeText(jsPath, renderDoofJs(module_, true))!
  execution := run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const imports = {};
  ${setup}
  const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[1]), imports);
  const api = ffi.createDoofModule(instance), e = instance.exports;
  const heap = ffi.createDoofHeapInspector(instance);
  const live = () => heap.dumpHeap().filter(b => b.kind !== 'free').map(b => [b.address, b.kind, b.refCount]);
  const baseline = live();
  for (let repeat = 0; repeat < 20; repeat++) {
    ${script}
    assert.deepStrictEqual(live(), baseline, 'temporary references must be released');
  }
})().catch(error => { console.error(error); process.exit(1); });
`, wasmPath, jsPath], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })!
  remove(wasmPath)!
  remove(jsPath)!
  if execution.exitCode != 0 { println(BlobReader(execution.stdout).readString(long(execution.stdout.length))) }
  Assert.equal(execution.exitCode, 0)
}

export function testLabeledExitsAcrossNestedLoopKinds(): none {
  checkSource(`
export function breaks(): int {
  let total = 0
  outer: while true {
    for let i = 0; i < 3; i += 1 {
      for item of [10, 20] { total += item; break outer }
    }
  }
  return total
}
export function continues(): int {
  let total = 0
  outer: for let i = 0; i < 4; i += 1 {
    while true { total += i; continue outer }
  }
  return total
}
export function arrayContinues(): int {
  let total = 0
  outer: for text of ["a", "bb", "ccc"] {
    for i of 0..<3 { total += text.length; continue outer }
  }
  return total
}
export function rangeBreaks(): int {
  let total = 0
  outer: for i of 1..3 {
    inner: while true { total += i; break inner }
    if i == 2 { break outer }
  }
  return total
}
export function shadowedContinue(): int {
  let total = 0
  outer: for let i = 0; i < 3; i += 1 {
    total += 1
    for _ of [1] { let i = 100; continue outer }
  }
  return total
}
`, "labels", `
assert.strictEqual(api.breaks(), 10);
assert.strictEqual(api.continues(), 6);
assert.strictEqual(api.arrayContinues(), 6);
assert.strictEqual(api.rangeBreaks(), 3);
assert.strictEqual(api.shadowedContinue(), 3);
`)
}

export function testOptionalIndexShortCircuitsAndKeepsElementTypes(): none {
  checkSource(`
class Item { name: string }
export function number(present: bool): int {
  let calls = 0
  index := (): int => { calls += 1; return 0 }
  values: int[] | none := if present then [42] else none
  result := values?[index()] ?? 7
  return result + calls * 100
}
export function text(present: bool): string {
  values: string[] | none := if present then ["ready" + string(1)] else none
  return values?[0] ?? "missing"
}
export function character(present: bool): int {
  value: string | none := if present then "AZ" else none
  letter: char := value?[1] ?? 'X'
  return int(letter)
}
export function object(present: bool): string {
  values: Item[] | none := if present then [Item { name: "item" }] else none
  item := values?[0] else { return "missing" }
  return item.name
}
export function unionElement(): int {
  values: (int | string)[] | none := [42, "x"]
  selected := values?[0]
  case selected { n: int -> { return n }, _ -> { return -1 } }
}
export function skippedTrap(): int {
  values: int[] | none := none
  return values?[trapIndex()] ?? 9
}
function trapIndex(): int { panic("index must be skipped") }
export function receiverOnce(present: bool): int {
  let calls = 0
  receiver := (): int[] | none => { calls += 1; return if present then [42] else none }
  value := receiver()?[0] ?? 7
  return calls * 100 + value
}
export function bounds(present: bool, index: int): int {
  values: int[] | none := if present then [42] else none
  return values?[index] ?? 7
}
`, "optional-index", `
assert.strictEqual(api.number(false), 7); assert.strictEqual(api.number(true), 142);
assert.strictEqual(api.text(false), 'missing'); assert.strictEqual(api.text(true), 'ready1');
assert.strictEqual(api.character(false), 88); assert.strictEqual(api.character(true), 90);
assert.strictEqual(api.object(false), 'missing'); assert.strictEqual(api.object(true), 'item');
assert.strictEqual(api.unionElement(), 42); assert.strictEqual(api.skippedTrap(), 9);
assert.strictEqual(api.receiverOnce(false), 107); assert.strictEqual(api.receiverOnce(true), 142);
assert.strictEqual(api.bounds(false, -1), 7); assert.strictEqual(api.bounds(false, 1), 7);
const isolated = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])));
assert.throws(() => isolated.exports.bounds(1, 1), WebAssembly.RuntimeError);
assert.throws(() => isolated.exports.bounds(1, -1), WebAssembly.RuntimeError);
`)
}

export function testScalarCaseValuesRangesAndAlternatives(): none {
  checkSource(`
enum Mode { One, Two, Three }
export function classify(value: int): int {
  case value {
    ..<0 -> { return -1 }
    0 | 2 | 4 -> { return 10 }
    1..3 -> { return 20 }
    5..<8 -> { return 30 }
    8.. -> { return 40 }
  }
}
export function wide(value: long): int {
  case value { ..<0 -> { return -1 }, 0..4294967296L -> { return 1 }, _ -> { return 2 } }
}
export function text(value: string): int {
  case value { "yes" | "y" -> { return 1 }, "no" -> { return 2 }, _ -> { return 0 } }
}
export function boolean(value: bool): int {
  case value { true -> { return 1 }, false -> { return 0 } }
}
export function enumCase(value: int): int {
  mode := if value == 0 then Mode.One else if value == 1 then Mode.Two else Mode.Three
  case mode { .One | .Three -> { return 10 }, .Two -> { return 20 } }
}
export function fallthrough(value: int): int {
  let total = 1
  case value { 2 | 3 -> { total += 10 } }
  return total
}
`, "case-values", `
for (const [input, expected] of [[-2147483648,-1],[-1,-1],[0,10],[1,20],[2,10],[3,20],[4,10],[5,30],[7,30],[8,40],[2147483647,40]]) assert.strictEqual(api.classify(input), expected);
assert.strictEqual(api.wide(-1n), -1); assert.strictEqual(api.wide(4294967296n), 1); assert.strictEqual(api.wide(4294967297n), 2);
assert.strictEqual(api.text('yes'), 1); assert.strictEqual(api.text('y'), 1); assert.strictEqual(api.text('no'), 2); assert.strictEqual(api.text('maybe'), 0);
assert.strictEqual(api.boolean(true), 1); assert.strictEqual(api.boolean(false), 0);
assert.strictEqual(api.enumCase(0), 10); assert.strictEqual(api.enumCase(1), 20); assert.strictEqual(api.enumCase(2), 10);
assert.strictEqual(api.fallthrough(1), 1); assert.strictEqual(api.fallthrough(2), 11);
`)
}

export function testCaseSubjectAndAlternativePatternsEvaluateOnceInOrder(): none {
  checkSource(`
export function check(value: int): int {
  let calls = 0
  subject := (): int => { calls += 100; return value }
  pattern := (candidate: int): int => { calls += 1; return candidate }
  let matched = 0
  case subject() {
    pattern(1) | pattern(2) -> { matched = 10 }
    pattern(3)..pattern(4) -> { matched = 20 }
    _ -> { matched = 30 }
  }
  return calls * 100 + matched
}
function union(value: int | string | none): int {
  case value { 1 | 2 -> { return 10 }, "yes" | "y" -> { return 20 }, none -> { return 30 }, _ -> { return 40 } }
}
export function unionCalls(): int => union(2) + union("y") + union(none) + union(9)
export function localPatterns(value: int): int {
  let count = 0
  case value { (count += 1) | (count += 1) -> { count += 10 }, _ -> { count += 20 } }
  return count
}
`, "case-evaluation", `
assert.strictEqual(api.check(1), 10110); assert.strictEqual(api.check(2), 10210);
assert.strictEqual(api.check(0), 10330); assert.strictEqual(api.check(3), 10420);
assert.strictEqual(api.unionCalls(), 100);
assert.strictEqual(api.localPatterns(1), 11); assert.strictEqual(api.localPatterns(2), 12); assert.strictEqual(api.localPatterns(3), 22);
`)
}

export function testMixedWidthComparisonsAndRangeBounds(): none {
  checkSource(`
function threshold(): int => 5
export function range(value: long): int {
  case value { ..<threshold() -> { return 1 }, threshold()..2147483648L -> { return 2 }, _ -> { return 3 } }
}
export function compare(): bool {
  small: byte := 255
  return small == 255 && 2147483647 < 2147483648L && 5L == 5 && 6L > 5 &&
    4 <= 4L && 5L >= 5 && 5 != 6L && float(1.25) < 1.5 && 2 == 2.0
}
`, "numeric-comparisons", `
assert.strictEqual(api.range(-9223372036854775808n), 1); assert.strictEqual(api.range(4n), 1);
assert.strictEqual(api.range(5n), 2); assert.strictEqual(api.range(2147483648n), 2);
assert.strictEqual(api.range(2147483649n), 3); assert.strictEqual(api.compare(), true);
`)
}

export function testUnsupportedLoopThenAndInvalidLabelsKeepDiagnostics(): none {
  for source of [
    "export function check(): none { while false {} then {} }",
    "export function check(): none { for i of 0..<3 { break missing } }",
    "export function check(): none { values: int[] | none := none; values?[0] = 1 }",
  ] {
    result := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
    case result {
      failure: Failure<string> -> { Assert.stringContains(failure.error, "/main.do:") }
      _ -> { Assert.fail("Expected a source diagnostic") }
    }
  }
}

export function testCaseExpressionsWithScalarPatternsAndValueCoercions(): none {
  checkSource(`
enum Mode { One, Two, Three }
export function classify(value: int): string => case value {
  ..<0 -> "negative", 0 | 2 -> "even", 1..3 -> "small", 4.. -> "large"
}
export function boolean(value: bool): int => case value { true -> 42, false -> 7 }
export function text(value: string): int => case value { "y" | "yes" -> 1, _ -> 0 }
export function enumCase(value: int): int {
  mode := if value == 0 then Mode.One else if value == 1 then Mode.Two else Mode.Three
  return case mode { .One -> 10, .Two | .Three -> 20 }
}
export function numeric(value: bool): double => case value { true -> 42, false -> 1.5 }
export function inline(value: int): int => 10 + (case value { 0 -> 1, _ -> 2 })
export function optional(value: bool): string {
  text: string | none := case value { true -> "present" + "!", false -> none }
  return text ?? "missing"
}
`, "case-expression-values", `
assert.strictEqual(api.classify(-1), 'negative'); assert.strictEqual(api.classify(0), 'even');
assert.strictEqual(api.classify(2), 'even'); assert.strictEqual(api.classify(3), 'small'); assert.strictEqual(api.classify(4), 'large');
assert.strictEqual(api.boolean(true), 42); assert.strictEqual(api.boolean(false), 7);
assert.strictEqual(api.text('yes'), 1); assert.strictEqual(api.text('n'), 0);
assert.strictEqual(api.enumCase(0), 10); assert.strictEqual(api.enumCase(1), 20); assert.strictEqual(api.enumCase(2), 20);
assert.strictEqual(api.numeric(true), 42); assert.strictEqual(api.numeric(false), 1.5);
assert.strictEqual(api.inline(0), 11); assert.strictEqual(api.inline(1), 12);
assert.strictEqual(api.optional(true), 'present!'); assert.strictEqual(api.optional(false), 'missing');
`)
}

export function testCaseExpressionCapturesAndOwnedResults(): none {
  checkSource(`
interface Named { name: string }
class Item implements Named { name: string }
function describe(value: int | string | Item | none): string => case value {
  number: int -> string(number), text: string -> text + "!", item: Item -> item.name, none -> "empty"
}
function fallible(ok: bool): Result<string, string> => if ok then Success { value: "ok" + "!" } else Failure { error: "bad" + "!" }
export function resultCase(ok: bool): string => case fallible(ok) {
  success: Success<string> -> success.value, failure: Failure<string> -> failure.error
}
export function captures(): string => describe(42) + describe("s") + describe(Item { name: "item" }) + describe(none)
export function callbacks(value: bool): int {
  let count = 0
  callback: (): int := case value { true -> (): int => { count += 1; return count }, false -> (): int => { count += 2; return count } }
  return callback() + callback() + count
}
export function references(value: bool): string {
  selected: Named := case value { true -> Item { name: "one" }, false -> Item { name: "two" } }
  items := case value { true -> [selected.name, "x"], false -> ["y", selected.name] }
  return items[0] + items[1]
}
function grouped(value: int | string | none): int => case value { present: int | string -> case present { n: int -> n, s: string -> s.length }, _ -> 0 }
export function unionCapture(): int => grouped(42) + grouped("abc") + grouped(none)
`, "case-expression-captures", `
assert.strictEqual(api.resultCase(true), 'ok!'); assert.strictEqual(api.resultCase(false), 'bad!');
assert.strictEqual(api.captures(), '42s!itemempty');
assert.strictEqual(api.references(true), 'onex'); assert.strictEqual(api.references(false), 'ytwo');
assert.strictEqual(api.unionCapture(), 45);
assert.strictEqual(api.callbacks(true), 5); assert.strictEqual(api.callbacks(false), 10);
`)
}

export function testCaseExpressionYieldTargetsAndEvaluationOrder(): none {
  checkSource(`
export function evaluation(value: int): int {
  let calls = 0
  subject := (): int => { calls += 100; return value }
  pattern := (candidate: int): int => { calls += 1; return candidate }
  result := case subject() { pattern(1) | pattern(2) -> { calls += 10; yield 1 }, _ -> { calls += 20; yield 2 } }
  return calls * 100 + result
}
export function nested(value: int): int {
  let total = 1
  result := case value {
    0 -> { total += 10; if value == 0 { yield case true { true -> 2, false -> 3 } } yield 4 }
    _ -> {
      let inner <- { if value == 1 { total += 20; yield 5 } yield 6 }
      inner <- { yield inner + 1 }
      case value { 1 -> { total += inner; yield 7 }, _ -> { total += 30 } }
      for i of 0..<3 { total += i; if i == 1 { yield inner } }
      yield 9
    }
  }
  return total * 100 + result
}
export function shadows(): int {
  let total = 1
  result := case true { true -> { let total = 9; yield total }, false -> 0 }
  return total * 100 + result
}
export function capturedAssignment(): int {
  let value = 1
  read := (): int => value
  value <- { yield case true { true -> 42, false -> 7 } }
  return read()
}
`, "case-expression-yields", `
assert.strictEqual(api.evaluation(1), 11101); assert.strictEqual(api.evaluation(2), 11201); assert.strictEqual(api.evaluation(3), 12202);
assert.strictEqual(api.nested(0), 1102); assert.strictEqual(api.nested(1), 2707); assert.strictEqual(api.nested(2), 3207);
assert.strictEqual(api.shadows(), 109); assert.strictEqual(api.capturedAssignment(), 42);
`)
}

export function testCaseExpressionTerminationAndDiagnostics(): none {
  checkSource(`
export function selected(ok: bool): int => case ok { true -> 42, false -> panic("stop") }
export function block(ok: bool): int => case ok { true -> { if ok { yield 7 } panic("stop") }, false -> { panic("stop") } }
export function allTerminate(ok: bool): int {
  result := case ok { true -> panic("first"), false -> { panic("second") } }
  return result
}
export function unit(): int {
  let calls = 0
  action := (): none => { calls += 1 }
  empty := case true { true -> action(), false -> none }
  return calls
}
`, "case-expression-termination", `
assert.strictEqual(api.selected(true), 42); assert.strictEqual(api.block(true), 7); assert.strictEqual(api.unit(), 1);
const trap = name => {
  const isolated = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])));
  assert.throws(() => isolated.exports[name](0), WebAssembly.RuntimeError);
};
trap('selected'); trap('block'); trap('allTerminate');
`)
  for source of [
    "export function invalid(value: bool): int => case value { true -> 1 }",
    "export function invalid(value: bool): int => case value { true -> { return 1 }, false -> 2 }",
    "export function invalid(value: bool): int => case value { true -> { let x = 1 }, false -> 2 }",
  ] {
    checked := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
    case checked { failure: Failure<string> -> { Assert.stringContains(failure.error, "/main.do:") }, _ -> { Assert.fail("Expected a case expression diagnostic") } }
  }
}

export function testWithSequentialBindingsAndLexicalShadowing(): none {
  checkSource(`
export function check(flag: bool): int {
  let value = 2
  let total = 0
  with value := value + 3, next: double := value + 1, _ := (total += 1), _ := (total += 2) {
    if flag { total += value + int(next) } else { total += 20 }
    with value := 7 {
      for i of 0..<2 { total += value + i }
    }
    let value = 100
    if flag { value += 1 } else { value += 2 }
    total += value
  }
  with offset := 4 { value += offset }
  return value * 1000 + total
}
export function immutableShadow(): int {
  value := 3
  with inner := value { value := inner + 4; _ := value }
  return value
}
export function immediate(): int { with value := 42 { return value } }
`, "with-scopes", `
assert.strictEqual(api.check(true), 6130); assert.strictEqual(api.check(false), 6140);
assert.strictEqual(api.immutableShadow(), 3); assert.strictEqual(api.immediate(), 42);
`)
}

export function testWithReferencesEscapeThroughLocalsReturnsClosuresAndYields(): none {
  checkSource(`
interface Valued { let value: int }
class Item implements Valued { let value: int }
function borrow(item: Item): int {
  with held := item { held.value += 1 }
  return item.value
}
export function references(): int {
  let outer = Item { value: 1 }
  with item := Item { value: 42 } { outer = item }
  return borrow(outer)
}
export function throughBranch(flag: bool): int {
  let outer = Item { value: 1 }
  with item := Item { value: 7 } { if flag { outer = item } }
  return outer.value
}
function returned(): Item { with item := Item { value: 13 } { return item } }
export function returns(): int => returned().value
export function yielded(): string {
  let value <- { with item := "a" + string(4) { yield item } }
  return value
}
export function closure(): int {
  let read: (): int = (): int => 0
  with item := Item { value: 17 } { read = (): int => item.value }
  return read()
}
export function interfaceBinding(): int {
  with item: Valued := Item { value: 5 } { return item.value }
}
export function nullable(flag: bool): int {
  with item: Item | none := if flag then Item { value: 23 } else none {
    value := item else { return 0 }
    return value.value
  }
}
`, "with-escapes", `
assert.strictEqual(api.references(), 43); assert.strictEqual(api.returns(), 13);
assert.strictEqual(api.throughBranch(true), 7); assert.strictEqual(api.throughBranch(false), 1);
assert.strictEqual(api.yielded(), 'a4'); assert.strictEqual(api.closure(), 17);
assert.strictEqual(api.interfaceBinding(), 5); assert.strictEqual(api.nullable(true), 23); assert.strictEqual(api.nullable(false), 0);
`)
}

export function testWithRetainedDiscardsLiveUntilScopeExit(): none {
  checkSource(`
import function observe(phase: int): none
class Guard { id: int }
export function check(): int {
  observe(0)
  with _ := Guard { id: 1 }, _ := Guard { id: 2 } {
    observe(2)
    with _ := Guard { id: 3 } { observe(3) }
    observe(2)
    for i of 0..<2 { observe(2) }
  }
  observe(0)
  return 42
}
export function exits(): int {
  let total = 0
  outer: for i of 0..<3 {
    with _ := Guard { id: i } {
      observe(1)
      if i == 0 { continue outer }
      for j of 0..<2 {
        if j == 1 { break outer }
        total += 1
      }
    }
  }
  observe(0)
  return total
}
export function yielding(): int {
  let value <- { with _ := Guard { id: 1 } { observe(1); yield 7 } }
  observe(0)
  return value
}
export function initOrder(): int {
  with _ := Guard { id: 1 }, second := inspected() { observe(2) }
  observe(0)
  return 1
}
function inspected(): Guard { observe(1); return Guard { id: 2 } }
`, "with-retained-discards", `
assert.strictEqual(api.check(), 42); assert.strictEqual(api.exits(), 1);
assert.strictEqual(api.yielding(), 7); assert.strictEqual(api.initOrder(), 1);
`, `imports.doof = { observe: count => assert.strictEqual(heap.dumpHeap().filter(b => b.kind === 'class').length, count, 'scope roots must stay alive until their exit') };`)
}

export function testWithArraysStringsResultsAndNeverInitializers(): none {
  checkSource(`
export function arrays(): string {
  with values := ["a" + string(1), "b"], count := values.length {
    values.push("c")
    return values[0] + string(count) + string(values.length)
  }
}
export function results(): string {
  with result: Result<string, string> := Success { value: "yes" + "!" } {
    value := result else { return "bad" }
    return value
  }
}
export function neverInitializer(): int { with _ := panic("stop") { return 1 } }
`, "with-types", `
assert.strictEqual(api.arrays(), 'a123'); assert.strictEqual(api.results(), 'yes!');
const isolated = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1])));
assert.throws(() => isolated.exports.neverInitializer(), WebAssembly.RuntimeError);
`)
}

export function testWithInvalidBindingsKeepFrontendDiagnostics(): none {
  for source of [
    "export function invalid(): int { with value := 1 {} return value }",
    "export function invalid(): int { with value := 1 { value = 2; return value } }",
    "function acquire(): Result<int, string> => Success { value: 1 }\nexport function invalid(): none { with _ := acquire() {} }",
    "export function invalid(): int { with first := second, second := 1 { return first } }",
    "export function invalid(): none { with value: string := 1 {} }",
  ] {
    result := lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
    case result { failure: Failure<string> -> { Assert.stringContains(failure.error, "/main.do:") }, _ -> { Assert.fail("Expected a with binding diagnostic: " + source) } }
  }
}

export function testWithImportedResourcesAndConditionalInitializers(): none {
  checkSource(`
import { Guard, acquire } from "./guard"
import function observe(phase: int): none
export function check(flag: bool): int {
  with guard := if flag then acquire(7) else Guard { id: 9 } {
    observe(1)
    if flag { observe(1) }
  }
  observe(0)
  return 42
}
`, "with-imports", `
assert.strictEqual(api.check(true), 42); assert.strictEqual(api.check(false), 42);
`, `imports.doof = { observe: count => assert.strictEqual(heap.dumpHeap().filter(b => b.kind === 'class').length, count) };`, [SourceFile { path: "/guard.do", source: `export class Guard { id: int }
export function acquire(id: int): Guard => Guard { id }
` }])
}
