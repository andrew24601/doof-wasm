// Native audit tool, deliberately outside the portable entry's dependency graph.
import { readText } from "std/fs"
import { absolute } from "std/path"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { createAnalyzerWithLoader } from "doof/src/analyzer"
import { nativeSourceEnvironment } from "../src/source-environment-native"

function main(arguments: string[]): int {
  if arguments.length != 1 { println("usage: selfhost-inventory entry.do"); return 2 }
  entry := absolute(arguments[0])!
  source := readText(entry) else { println("could not read " + entry); return 1 }
  environment := nativeSourceEnvironment(entry, "std/wasm") else error { println(error); return 1 }
  analyzer := createAnalyzerWithLoader([SourceFile { path: entry, source }], (path: string): Result<SourceFile | none, Diagnostic> => environment.load(path))
  analyzer.serialParsing = true
  analysis := analyzer.analyze(entry)
  for module_ of analysis.modules { println(module_.path) }
  println("modules: " + string(analysis.modules.length))
  for diagnostic of analysis.diagnostics {
    println(diagnostic.module + ":" + string(diagnostic.span.start.line) + ":" + string(diagnostic.span.start.column) + ": " + diagnostic.message)
  }
  return 0
}
