// Wasm integration gate. Each compiler receives the same frozen byte-character
// source graph, logical entry, and options in a fresh worker/instance.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const loadBindings = text => import('data:text/javascript;base64,' + Buffer.from(text).toString('base64'));

function heapHeaders(instance, baseline) {
  const memory = instance.exports.__doof_ffi_memory;
  const end = instance.exports.__doof_debug_heap_end.value >>> 0;
  const view = new DataView(memory.buffer), live = [];
  let liveCount = 0, unexpectedCount = 0;
  const changed = [], unexpected = [], observed = new Set();
  // Full compilation leaves millions of reusable free blocks. Scan their
  // headers without constructing objects or decoding any payloads.
  for (let address = 1024; address < end;) {
    const tag = view.getUint16(address, true), size = view.getUint16(address + 2, true);
    if (size < 8 || address + size > end) throw new Error('invalid heap block at ' + address);
    if (tag !== 0) {
      const ownership = view.getUint32(address + 4, true);
      liveCount++;
      if (!baseline) live.push([address, tag, ownership]);
      else if (baseline.has(address)) {
        observed.add(address);
        if (tag !== baseline.get(address)[1] || ownership !== baseline.get(address)[2]) changed.push([address, tag, ownership]);
      } else {
        unexpectedCount++;
        if (unexpected.length < 20) unexpected.push([address, tag, ownership]);
      }
    }
    address += size;
  }
  if (!baseline) return live;
  const missing = [...baseline.keys()].filter(address => !observed.has(address));
  return { clean: unexpectedCount === 0 && changed.length === 0 && missing.length === 0,
    liveCount, baselineCount: baseline.size, unexpectedCount, unexpected, changed, missing };
}

if (!isMainThread) {
  const { bundlePath, wasmPath, bindingsPath, outputPrefix } = workerData;
  const bundle = JSON.parse(readFileSync(bundlePath, 'utf8'));
  const sources = new Map();
  for (const file of bundle.sources) {
    assert(!sources.has(file.path), 'duplicate logical source: ' + file.path);
    const bytes = Buffer.from(file.source, 'utf8');
    assert.equal(digest(bytes), file.sha256, 'source snapshot digest: ' + file.path);
    sources.set(file.path, bytes.toString('latin1'));
  }
  const entry = sources.get(bundle.entry);
  assert.notEqual(entry, undefined, 'entry is present in source bundle');
  const ffi = await loadBindings(readFileSync(bindingsPath, 'utf8'));
  let lastSource = '', publications = 0, result, loads = 0, clockReads = 0;
  const host = ffi.createDoofStdHost({
    sha256HexString: text => digest(Buffer.from(text, 'latin1')),
    monotonicNanos: () => { clockReads++; return process.hrtime.bigint(); },
  });
  const decoder = new TextDecoder('utf-8', { fatal: true });
  host['doof_runtime.hpp'] = { 'doof::char_from_utf8': value => {
    const decoded = decoder.decode(Buffer.from(value, 'latin1'));
    assert.equal([...decoded].length, 1, 'character import consumes one UTF-8 code point');
    return decoded.codePointAt(0);
  } };
  host.sourceStatus = path => {
    if (!sources.has(path)) { lastSource = ''; return 0; }
    lastSource = sources.get(path);
    loads++;
    parentPort.postMessage({ event: 'load', loads, path });
    return 1;
  };
  host.sourceValue = () => lastSource;
  host.compilerOutput = (hex, bindings) => {
    assert.equal(publications++, 0, 'successful compilation publishes once');
    assert.equal(hex.length % 2, 0, 'hex has complete byte pairs');
    assert(!/[^0-9a-f]/.test(hex), 'hex uses lowercase byte digits');
    result = { bytes: Buffer.from(hex, 'hex'), bindings };
  };
  const bridge = ffi.createDoofImports(host);
  const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), bridge.imports);
  bridge.attach(instance);
  const api = ffi.createDoofModule(instance);
  const baseline = new Map(heapHeaders(instance).map(state => [state[0], state]));
  parentPort.postMessage({ event: 'started', sourceCount: sources.size });
  const start = performance.now();
  const diagnostic = api.compile(entry, bundle.entry, bundle.debugHeap);
  assert.equal(diagnostic, '', diagnostic);
  assert.equal(publications, 1, 'compiler artifacts published');
  assert.equal(clockReads, 0, 'timings are disabled');
  parentPort.postMessage({ event: 'compiled', seconds: (performance.now() - start) / 1000, wasmBytes: result.bytes.length });
  writeFileSync(outputPrefix + '.wasm', result.bytes);
  writeFileSync(outputPrefix + '.js', result.bindings);
  const heap = heapHeaders(instance, baseline);
  // Address 0 represents `none` in an `any`; its eight header bytes must stay zero.
  heap.noneHeaderZero = new DataView(instance.exports.__doof_ffi_memory.buffer).getBigUint64(0, true) === 0n;
  if (!heap.noneHeaderZero) heap.clean = false;
  await WebAssembly.compile(result.bytes);
  parentPort.postMessage({ event: 'complete', seconds: (performance.now() - start) / 1000,
    wasmBytes: result.bytes.length, wasmSha256: digest(result.bytes), bindingsSha256: digest(result.bindings),
    memoryBytes: instance.exports.__doof_ffi_memory.buffer.byteLength, sourceLoads: loads, heap });
} else {
  const [bundleArgument, stage1Argument, outputArgument, resumeArgument] = process.argv.slice(2);
  assert(bundleArgument && stage1Argument && outputArgument,
    'usage: node selfhost-fixed-point.mjs sources.json stage1.wasm output-directory [--resume-stage3]');
  assert(!resumeArgument || resumeArgument === '--resume-stage3', 'unknown option: ' + resumeArgument);
  const bundlePath = resolve(bundleArgument), stage1Path = resolve(stage1Argument), output = resolve(outputArgument);
  mkdirSync(output, { recursive: true });
  const stages = [];
  let comparisons = {};
  if (resumeArgument) {
    const bytes = readFileSync(join(output, 'stage2.wasm')), bindings = readFileSync(join(output, 'stage2.js'));
    await WebAssembly.compile(bytes);
    stages.push({ stage: 2, resumed: true, wasmBytes: bytes.length, wasmSha256: digest(bytes), bindingsSha256: digest(bindings) });
  }
  async function compileStage(stage, wasmPath, bindingsPath) {
    console.log(`stage ${stage}: compiling the frozen compiler graph in Wasm`);
    const start = performance.now();
    let loads = 0, lastPath = '';
    const timer = setInterval(() => console.log(`stage ${stage}: running ${(performance.now()-start)/1000|0}s, ${loads} source loads, last ${lastPath}`), 30000);
    try {
      return await new Promise((resolveStage, reject) => {
        const worker = new Worker(fileURLToPath(import.meta.url), {
          workerData: { bundlePath, wasmPath, bindingsPath, outputPrefix: join(output, `stage${stage}`) },
        });
        let completed;
        worker.on('message', message => {
          if (message.event === 'load') { loads = message.loads; lastPath = message.path; }
          if (message.event === 'compiled') console.log(`stage ${stage}: artifacts published, ${message.wasmBytes} bytes in ${message.seconds.toFixed(1)}s; verifying cleanup and validity`);
          if (message.event === 'complete') { completed = message; }
        });
        worker.on('error', reject);
        worker.on('exit', code => code === 0 && completed ? resolveStage({ stage, ...completed }) : reject(new Error(`stage ${stage} exited ${code} without artifacts`)));
      });
    } finally { clearInterval(timer); }
  }
  try {
    for (const stage of resumeArgument ? [3] : [2, 3]) {
      const input = stage === 2 ? stage1Path : join(output, 'stage2.wasm');
      const bindings = input.replace(/\.wasm$/, '.js');
      const result = await compileStage(stage, input, bindings);
      stages.push(result);
      console.log(`stage ${stage}: ${result.wasmBytes} bytes in ${result.seconds.toFixed(1)}s, sha256 ${result.wasmSha256}`);
      writeFileSync(join(output, 'result.json'), JSON.stringify({ bundleSha256: digest(readFileSync(bundlePath)), stages }, null, 2));
    }
    const wasmEqual = readFileSync(join(output, 'stage2.wasm')).equals(readFileSync(join(output, 'stage3.wasm')));
    const bindingsEqual = readFileSync(join(output, 'stage2.js')).equals(readFileSync(join(output, 'stage3.js')));
    const nativeEqual = readFileSync(stage1Path).equals(readFileSync(join(output, 'stage2.wasm')));
    const nativeBindingsEqual = readFileSync(stage1Path.replace(/\.wasm$/, '.js')).equals(readFileSync(join(output, 'stage2.js')));
    comparisons = { wasmEqual, bindingsEqual, nativeEqual, nativeBindingsEqual };
    const result = { bundleSha256: digest(readFileSync(bundlePath)), stages, ...comparisons };
    writeFileSync(join(output, 'result.json'), JSON.stringify(result, null, 2));
    console.log(JSON.stringify({ ...result, stages: stages.map(stage => {
      if (!stage.heap) return stage;
      const { unexpected, changed, missing, ...heap } = stage.heap;
      return { ...stage, heap: { ...heap, changedCount: changed.length, missingCount: missing.length } };
    }) }, null, 2));
    assert(wasmEqual && bindingsEqual, 'stage 2 and stage 3 must match byte-for-byte');
    // Each full self-compile must free everything it allocated.
    for (const stage of stages) assert(!stage.heap || stage.heap.clean, `stage ${stage.stage} compiler heap returns to its baseline`);
    console.log('FIXED POINT: stage 2 and stage 3 Wasm and bindings are identical');
  } catch (error) {
    writeFileSync(join(output, 'result.json'), JSON.stringify({ bundleSha256: digest(readFileSync(bundlePath)), stages, ...comparisons, error: String(error.stack || error) }, null, 2));
    throw error;
  }
}
