// Node host adapter for a prebuilt portable compiler. Native builds and source
// bundling remain separate from this explicit integration gate.
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const wasmPath = resolve(process.argv[2] ?? 'build/selfhost-compiler.wasm');
const bindingsPath = resolve(process.argv[3] ?? wasmPath.replace(/\.wasm$/, '.js'));
const stdlibRoot = resolve(process.argv[4] ?? fileURLToPath(new URL('../std/wasm', import.meta.url)));
const referencePath = process.argv[5] && resolve(process.argv[5]);
const behaviorOnly = process.env.DOOF_SMOKE_BEHAVIOR_ONLY === '1';
const loadBindings = text => import('data:text/javascript;base64,' + Buffer.from(text).toString('base64'));
const ffi = await loadBindings(readFileSync(bindingsPath, 'utf8'));
const bytes = readFileSync(wasmPath);
const module = await WebAssembly.compile(bytes);
console.log('compiler validates:', bytes.length, 'bytes');

const sources = new Map(), failures = new Map();
let lastSource = '', published, publications = 0, clockReads = 0;
const host = ffi.createDoofStdHost({
  sha256HexString: text => createHash('sha256').update(text, 'latin1').digest('hex'),
  monotonicNanos: () => { clockReads++; return process.hrtime.bigint(); },
});
host['doof_runtime.hpp'] = { 'doof::char_from_utf8': value => value.charCodeAt(0) };
host.sourceStatus = path => {
  if (failures.has(path)) { lastSource = failures.get(path); return 2; }
  if (sources.has(path)) { lastSource = sources.get(path); return 1; }
  if (path.startsWith('/std/') && !path.split('/').includes('..')) {
    const diskPath = join(stdlibRoot, path.slice('/std/'.length));
    if (existsSync(diskPath)) { lastSource = readFileSync(diskPath, 'utf8'); return 1; }
  }
  lastSource = '';
  return 0;
};
host.sourceValue = () => lastSource;
host.compilerOutput = (hex, bindings) => {
  assert.match(hex, /^(?:[0-9a-f]{2})+$/);
  assert.equal(publications++, 0, 'publish each successful compilation once');
  published = { bytes: Buffer.from(hex, 'hex'), bindings };
};
const bridge = ffi.createDoofImports(host);
const instance = await WebAssembly.instantiate(module, bridge.imports);
bridge.attach(instance);
const api = ffi.createDoofModule(instance);
const heap = typeof ffi.createDoofHeapInspector === 'function' ? ffi.createDoofHeapInspector(instance) : null;
const live = () => heap?.dumpHeap().filter(block => block.kind !== 'free').map(block => [block.address, block.kind, block.refCount]);
const baseline = live();
const compilerMemory = instance.exports.__doof_ffi_memory ?? instance.exports.memory;
const initialMemoryBytes = compilerMemory.buffer.byteLength;

async function compile(source, files = []) {
  sources.clear(); failures.clear(); published = undefined; publications = 0;
  for (const [path, text] of files) sources.set(path, text);
  const diagnostic = api.compile(source, '/main.do', true);
  assert.equal(diagnostic, '', diagnostic);
  assert.equal(publications, 1);
  const outputFfi = await loadBindings(published.bindings);
  const imports = outputFfi.createDoofImports(outputFfi.createDoofStdHost());
  const output = await WebAssembly.instantiate(published.bytes, imports.imports);
  imports.attach(output.instance);
  if (heap) assert.deepEqual(live(), baseline, 'successful compilation releases compiler temporaries');
  return outputFfi.createDoofModule(output.instance);
}

const arithmetic = await compile('export function answer(): int => 40 + 2');
assert.equal(arithmetic.answer(), 42);
console.log('in-memory compilation executes');

const imported = await compile('import { add } from "./math"\nexport function answer(): int => add(40, 2)', [
  ['/math.do', 'export function add(left: int, right: int): int => left + right'],
]);
assert.equal(imported.answer(), 42);
console.log('caller-owned module loading executes');

const numeric = await compile('import { parseInt } from "std/parse"\nexport function answer(text: string): int => parseInt(text)!');
assert.equal(numeric.answer('42'), 42);
assert.throws(() => numeric.answer('invalid'), /forced unwrap failed/);
console.log('injected stdlib and generated bindings execute');

for (const [source, expected, acquisitionFailure] of [
  ['export function answer(: int => 42', /Expected|Unexpected/, false],
  ['export function answer(): int => "wrong"', /Cannot return string from function returning int/, false],
  ['export function answer(): int => missing', /Unknown identifier/, false],
  ['import { missing } from "./absent"\nexport function answer(): int => 42', /absent|resolve|module/i, false],
  ['import { missing } from "./broken"\nexport function answer(): int => 42', /source acquisition failed/, true],
]) {
  sources.clear(); failures.clear(); published = undefined; publications = 0;
  if (acquisitionFailure) failures.set('/broken.do', 'source acquisition failed');
  assert.match(api.compile(source, '/main.do', true), expected);
  assert.equal(publications, 0);
  if (heap) assert.deepEqual(live(), baseline, 'failed compilation releases compiler temporaries');
  const recovered = await compile('export function answer(): int => 42');
  assert.equal(recovered.answer(), 42);
}
assert.equal(clockReads, 0, 'disabled timings never read the host clock');
console.log(heap ? 'diagnostics, recovery, and repeated-call cleanup pass' : 'diagnostics and recovery pass; compiler heap inspection unavailable');

if (referencePath) {
  const references = JSON.parse(readFileSync(referencePath, 'utf8'));
  assert(references.length > 0, 'native reference corpus is nonempty');
  for (const reference of references) {
    sources.clear(); failures.clear(); published = undefined; publications = 0;
    for (const file of reference.files) sources.set(file.path, file.source);
    const diagnostic = api.compile(reference.source, '/main.do', true);
    assert.equal(diagnostic, reference.diagnostic, reference.name + ': native diagnostic parity');
    if (reference.diagnostic) {
      assert.equal(publications, 0, reference.name + ': no publication after a diagnostic');
    } else {
      assert.equal(publications, 1, reference.name + ': one publication');
      // DOOF_SMOKE_BEHAVIOR_ONLY=1 checks a changed backend against older
      // references: diagnostics, execution and cleanup, but not exact bytes.
      if (!behaviorOnly) {
        assert.equal(published.bytes.toString('hex'), reference.wasmHex, reference.name + ': native Wasm byte parity');
        assert.equal(published.bindings, reference.bindings, reference.name + ': native binding parity');
      }
      const outputFfi = await loadBindings(published.bindings);
      const imports = outputFfi.createDoofImports(outputFfi.createDoofStdHost());
      const output = await WebAssembly.instantiate(published.bytes, imports.imports);
      imports.attach(output.instance);
      const result = outputFfi.createDoofModule(output.instance);
      if (reference.name === 'formatting') {
        assert.equal(result.format(true), 'phase=ready;ready=true;value=42');
        assert.equal(result.format(false), 'phase=cold;ready=false;value=-1');
      } else if (reference.name === 'numeric') {
        assert.equal(result.answer('42'), 42);
        assert.throws(() => result.answer('invalid'), /forced unwrap failed/);
      } else if (reference.name === 'large') {
        assert.equal(result.answer(), 'x'.repeat(262145));
      } else {
        assert.equal(result.answer(), 42, reference.name + ': emitted program executes');
      }
    }
    if (heap) assert.deepEqual(live(), baseline, reference.name + ': compiler heap cleanup');
    console.log('native parity:', reference.name);
  }
  if (heap) assert(compilerMemory.buffer.byteLength > initialMemoryBytes, 'compilation exercises memory growth');
  assert.equal(clockReads, 0, 'native-parity compiles keep timings disabled');
  console.log(behaviorOnly ? 'native diagnostics and behavior match (bytes not compared)' : 'native/Wasm bytes, bindings, diagnostics, and behavior match');
}
