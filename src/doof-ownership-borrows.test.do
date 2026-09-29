import { Assert } from "std/assert"
import { BlobReader } from "std/blob"
import { remove, writeBlob, writeText } from "std/fs"
import { ExecOptions, pid, run } from "std/os"
import { SourceFile } from "doof/src/semantic"
import { lowerDoofWasmSources } from "./doof-compiler"
import { encodeDoofMinus } from "./minus-wasm"
import { renderDoofJs } from "./minus-js"

// Short-lived borrows, ownership moves, and inlined wrappers must keep values
// alive across every kind of write that could drop their owning slot, and must
// leave the heap exactly as it was after repeated calls. Unions mix boxed
// scalars with class values that `any` holds directly.
export function testShortBorrowsAndOwnershipMovesSurviveMutationAndCleanUp(): none {
  source := `
class Item { name: string; next: Item | none = none }
class Box { let items: Item[]; let label: string }
interface Mutator { apply(box: Box): none }
class Replacer implements Mutator {
  apply(box: Box): none { box.items[0] = Item { name: "replaced" + string(box.items.length) } }
}

function clobber(box: Box): none { box.items = [Item { name: "fresh" }] }

// Element read, then the slot is overwritten through an array method.
export function slotOverwrite(): string {
  box := Box { items: [Item { name: "a" + string(1) }, Item { name: "b" }], label: "x" }
  first := box.items[0]
  box.items[0] = Item { name: "c" }
  return first.name + box.items[0].name
}

// Field read, then the field is replaced.
export function fieldReplace(): string {
  box := Box { items: [], label: "one" + string(1) }
  label := box.label
  box.label = "two"
  return label + box.label
}

// Element read, then a mutating call drops the whole array.
export function containerDropped(): string {
  box := Box { items: [Item { name: "keep" + string(7) }], label: "l" }
  held := box.items[0]
  clobber(box)
  return held.name + box.items[0].name
}

// Element read, then interface dispatch mutates the container.
export function dynamicMutation(): string {
  box := Box { items: [Item { name: "orig" + string(3) }], label: "l" }
  held := box.items[0]
  m: Mutator := Replacer {}
  m.apply(box)
  return held.name + box.items[0].name
}

// Closure mutation inside the borrow window.
export function closureMutation(): string {
  box := Box { items: [Item { name: "z" + string(9) }], label: "l" }
  held := box.items[0]
  wipe := (): none => { _ := box.items.pop() }
  wipe()
  return held.name + string(box.items.length)
}

// Lookup loop: borrowed element and field, returned through a Result.
function find(items: Item[], name: string): Result<Item, string> {
  for item of items { if item.name == name { return Success(item) } }
  return Failure("missing " + name)
}
function has(items: Item[], name: string): bool {
  for item of items { if item.name == name { return true } }
  return false
}
export function lookups(): int {
  let items: Item[] = []
  for index of 0..<50 { items.push(Item { name: "n" + string(index) }) }
  let total = 0
  for round of 0..<20 {
    for index of 0..<50 {
      found := find(items, "n" + string(index)) else { return -1 }
      if found.name.length > 0 { total += 1 }
    }
    if has(items, "none") { return -2 }
  }
  return total
}

// Owned values carried through joins and loops (ownership moves on edges).
export function carried(flag: bool): string {
  let current: Item | none = none
  let text = ""
  for index of 0..<10 {
    next := Item { name: "i" + string(index), next: current }
    if flag && index % 2 == 0 { current = next } else if index % 3 == 0 { current = none } else { current = next }
    text = text + (if current == none then "-" else "+")
  }
  let count = 0
  let walk = current
  while walk != none { count += 1; walk = walk!.next }
  return text + string(count)
}

// Borrowed read across a mutation of a different array of the same type.
export function otherArray(): string {
  left := [Item { name: "L" + string(1) }]
  right := [Item { name: "R" }]
  held := left[0]
  right[0] = Item { name: "S" }
  return held.name + right[0].name
}

// String equality edge cases.
export function equality(): int {
  let score = 0
  a := "abcdefgh" + "ij"
  b := "abcdefghij"
  if a == b { score += 1 }
  if a != "abcdefghik" { score += 2 }
  if "" == "" + "" { score += 4 }
  if a != "abcdefgh" { score += 8 }
  let big = ""
  for index of 0..<1100 { big = big + "x" }
  let big2 = ""
  for index of 0..<1100 { big2 = big2 + "x" }
  if big == big2 { score += 16 }
  big3 := big2 + "y"
  if big != big3 { score += 32 }
  names := ["p", "q", "r" + string(5)]
  if names.contains("r5") { score += 64 }
  if !names.contains("r6") { score += 128 }
  return score
}

enum Colour { red, green }
function describe(value: int | string | Item | Colour | none): string {
  case value {
    n: int -> { return "i" + string(n) }
    s: string -> { return "s" + s }
    item: Item -> { return "o" + item.name }
    c: Colour -> { return if c == Colour.red then "r" else "g" }
    _ -> { return "n" }
  }
}

// Unions mix boxed scalars with class, interface, enum and none values.
export function unions(): string {
  shared := Item { name: "x" + string(1) }
  values: (int | string | Item | Colour | none)[] := [7, "t" + string(2), shared, Colour.green, none]
  let text = ""
  for value of values { text = text + describe(value) }
  let score = 0
  if values.contains(7) { score += 1 }
  if values.contains("t2") { score += 2 }
  if values.contains(shared) { score += 4 }
  if !values.contains(Item { name: "x1" }) { score += 8 }
  if values.contains(Colour.green) { score += 16 }
  if !values.contains(Colour.red) { score += 32 }
  if values.contains(none) { score += 64 }
  if !values.contains(8) { score += 128 }
  return text + string(score)
}

// Interface values travel through Result's any payload.
function pick(flag: bool): Result<Mutator, string> {
  if flag { return Success(Replacer {}) }
  return Failure("no" + string(0))
}
export function interfaces(): string {
  m := pick(true) else { return "fail" }
  box := Box { items: [Item { name: "a" }], label: "l" }
  m.apply(box)
  _ := pick(false) else { return box.items[0].name }
  return "bad"
}

// Concatenation chains: flattened groups, shared intermediates, empty parts,
// interpolation, and chains longer than one group.
export function concats(): string {
  a := "a" + string(1)
  empty := ""
  shared := a + "-" + a
  both := shared + "|" + shared
  long := "0" + "1" + "2" + "3" + "4" + "5" + "6" + "7" + "8" + "9" + "A" + "B" + "C" + "D" + "E" + "F" + "G" + "H" + "I"
  let loop = ""
  for index of 0..<5 { loop = loop + "[" + string(index) + "]" + empty }
  text := "\${a}:\${empty}:\${long.length}:\${both}"
  return both + empty + long + loop + text + empty
}
`
  module_ := try! lowerDoofWasmSources([SourceFile { path: "/main.do", source }], "/main.do")
  bytes := try! encodeDoofMinus(module_, true)
  path := "/tmp/doof-ownership-borrows-" + string(pid())
  try! writeBlob(path + ".wasm", bytes.cloneReadonly())
  try! writeText(path + ".mjs", renderDoofJs(module_, true))
  result := try! run("node", ["-e", `
const fs = require('fs'), assert = require('assert'), {pathToFileURL} = require('url');
(async () => {
  const ffi = await import(pathToFileURL(process.argv[2]).href);
  const bridge = ffi.createDoofImports({});
  const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[1]), bridge.imports); bridge.attach(instance);
  const m = ffi.createDoofModule(instance), heap = ffi.createDoofHeapInspector(instance);
  const live = () => heap.dumpHeap().filter(block => block.kind !== 'free').map(block => [block.address, block.kind, block.refCount]);
  const baseline = live();
  for (let round = 0; round < 3; round++) {
    assert.strictEqual(m.slotOverwrite(), 'a1c');
    assert.strictEqual(m.fieldReplace(), 'one1two');
    assert.strictEqual(m.containerDropped(), 'keep7fresh');
    assert.strictEqual(m.dynamicMutation(), 'orig3replaced1');
    assert.strictEqual(m.closureMutation(), 'z90');
    assert.strictEqual(m.lookups(), 1000);
    assert.strictEqual(m.carried(true), '+++-+++++-0');
    assert.strictEqual(m.carried(false), '-++-++-++-0');
    assert.strictEqual(m.otherArray(), 'L1S');
    assert.strictEqual(m.equality(), 255);
    assert.strictEqual(m.unions(), 'i7st2ox1gn255');
    assert.strictEqual(m.interfaces(), 'replaced1');
    assert.strictEqual(m.concats(), 'a1-a1|a1-a1' + '0123456789ABCDEFGHI' + '[0][1][2][3][4]' + 'a1::19:a1-a1|a1-a1');
    assert.deepStrictEqual(live(), baseline, 'heap returns to baseline');
  }
})().catch(error => { console.error(error); process.exit(1); });
`, path + ".wasm", path + ".mjs"], ExecOptions { withStdin: false, mergeStderrIntoStdout: true })
  try! remove(path + ".wasm")
  try! remove(path + ".mjs")
  if result.exitCode != 0 { println(BlobReader(result.stdout).readString(long(result.stdout.length))) }
  Assert.equal(result.exitCode, 0)
}
