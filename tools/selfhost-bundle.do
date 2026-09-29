// Native snapshot/bootstrap boundary. The Wasm stages use only this frozen
// logical source bundle; no compiler checkout or native stdlib loader is needed.
import { readText, writeText, writeBlob, mkdir, isDirectory } from "std/fs"
import { absolute } from "std/path"
import { formatJsonValue } from "std/json"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { createAnalyzerWithLoader } from "doof/src/analyzer"
import { noSourceLoader } from "doof/src/resolver"
import { nativeSourceEnvironment } from "../src/source-environment-native"
import { compileDoofWasmSourcesWithBindings, WasmLoweringOptions } from "../src/doof-compiler"

class BundledSource { path: string; source: string; sha256: string }
class SourceBundle { entry: string; debugHeap: bool; sources: BundledSource[] }

function logicalPath(path: string, root: string): string =>
  if path.startsWith(root + "/") then "/compiler" + path.substring(root.length) else path

function main(arguments: string[]): int {
  if arguments.length != 2 { println("usage: selfhost-bundle entry.do output-directory"); return 2 }
  root := try! absolute(".")
  entry := try! absolute(arguments[0])
  output := try! absolute(arguments[1])
  if !entry.startsWith(root + "/") { println("entry must be inside the repository working directory"); return 2 }
  _ := mkdir(output) else { if !isDirectory(output) { println("could not create " + output); return 1 } }
  source := readText(entry) else { println("could not read " + entry); return 1 }
  environment := nativeSourceEnvironment(entry, "std/wasm") else error { println(error); return 1 }
  analyzer := createAnalyzerWithLoader([SourceFile { path: entry, source }], (path: string): Result<SourceFile | none, Diagnostic> => environment.load(path))
  analyzer.serialParsing = true
  analysis := analyzer.analyze(entry)
  for diagnostic of analysis.diagnostics {
    println(diagnostic.module + ": " + diagnostic.message)
    if diagnostic.severity == "error" { return 1 }
  }
  let bundled: BundledSource[] = []
  let sources: SourceFile[] = []
  for module_ of analysis.modules {
    file := analyzer.resolver.find(module_.path) else { println("missing acquired snapshot: " + module_.path); return 1 }
    path := logicalPath(module_.path, root)
    bundled.push(BundledSource { path, source: file.source, sha256: module_.sourceHash })
    sources.push(SourceFile { path, source: file.source })
  }
  logicalEntry := logicalPath(entry, root)
  bundle := SourceBundle { entry: logicalEntry, debugHeap: true, sources: bundled }
  _ := writeText(output + "/sources.json", formatJsonValue(bundle.toSerialObject())) else { println("could not write source bundle"); return 1 }
  println("frozen source bundle: " + string(sources.length) + " modules")
  options := WasmLoweringOptions { boxImmutableStructs: true, synchronousAsync: true }
  artifacts := compileDoofWasmSourcesWithBindings(sources, logicalEntry, noSourceLoader, true, options) else error { println(error); return 1 }
  _ := writeBlob(output + "/stage1.wasm", artifacts.bytes.cloneReadonly()) else { println("could not write stage 1 Wasm"); return 1 }
  _ := writeText(output + "/stage1.js", artifacts.bindings) else { println("could not write stage 1 bindings"); return 1 }
  println("stage 1: " + string(artifacts.bytes.length) + " bytes")
  return 0
}
