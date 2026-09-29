import { Assert } from "std/assert"
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { ModuleResolver } from "doof/src/resolver"
import { SourceEnvironment, SourceMount } from "./source-environment"
import { diskSourceMount, loadDiskSource, nativeSourceEnvironment } from "./source-environment-native"

export function testSourceEnvironmentMountsAndBarrelFallback(): none {
  let probes: string[] = []
  environment := SourceEnvironment { mounts: [SourceMount {
    prefix: "/std",
    loader: (path: string): Result<SourceFile | none, Diagnostic> => {
      probes.push(path)
      if path == "/std/demo/index.do" { return Success(SourceFile { path, source: "export readonly VALUE = 42" }) }
      return Success(none)
    },
  }] }
  resolver := ModuleResolver { sources: [], loader: (path: string): Result<SourceFile | none, Diagnostic> => environment.load(path) }
  Assert.equal(resolver.resolve("/main.do", "std/demo"), "/std/demo/index.do")
  Assert.equal(probes.length, 2)
  _ := resolver.find("/std/demo.do")
  Assert.equal(probes.length, 2)
  Assert.equal(environment.load("/stdlib/demo.do")!, none)
  environment.mounts.push(SourceMount { prefix: "/std/demo", loader: (path: string): Result<SourceFile | none, Diagnostic> => Success(SourceFile { path, source: "specific" }) })
  Assert.equal(environment.load("/std/demo/index.do")!!.source, "specific")
  Assert.equal(environment.load("/std/unknown/index.do")!, none)
}

export function testSourceEnvironmentNativeStdAndDependencyMappings(): none {
  environment := try! nativeSourceEnvironment("src/doof-cli.do", "std/wasm")
  stdSource := environment.load("/std/parse/index.do")!!
  Assert.equal(stdSource.path, "/std/parse/index.do")
  Assert.stringContains(stdSource.physicalPath, "/std/wasm/parse/index.do")
  Assert.stringContains(stdSource.source, "function parseLong")
  compilerSource := environment.load("/doof/src/frontend.do")!!
  Assert.equal(compilerSource.path, "/doof/src/frontend.do")
  Assert.stringContains(compilerSource.source, "function analyzeWithLoader")
  Assert.equal(environment.load("/std/parse.do")!, none)
  Assert.equal(loadDiskSource("/missing.do", "/tmp/doof-wasm-missing-source.do")!, none)
  // A directory exists but cannot be read as source: preserve the I/O error.
  case loadDiskSource("/directory.do", "src") {
    failure: Failure<Diagnostic> -> { Assert.stringContains(failure.error.message, "could not read imported module") }
    _ -> { Assert.fail("Expected a source acquisition diagnostic") }
  }
}
