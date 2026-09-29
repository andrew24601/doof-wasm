// Native acquisition adapter; keep this outside the compiler's portable core.
import { exists, readText } from "std/fs"
import { absolute, dirname, resourcePath } from "std/path"
import { parsePackageManifest } from "doof/src/package-manifest"
import { SourceFile, Diagnostic, SemanticLocation, SemanticSpan } from "doof/src/semantic"
import { SourceEnvironment, SourceMount } from "./source-environment"

function sourceError(path: string, message: string): Diagnostic {
  location := SemanticLocation { line: 0, column: 0, offset: 0 }
  return Diagnostic { severity: "error", message, module: path, span: SemanticSpan { start: location, end: location } }
}

export function loadDiskSource(path: string, diskPath: string): Result<SourceFile | none, Diagnostic> {
  if !exists(diskPath) { return Success(none) }
  source := readText(diskPath) else { return Failure(sourceError(path, "could not read imported module " + diskPath)) }
  return Success(SourceFile { path, physicalPath: diskPath, source })
}

export function diskSourceMount(prefix: string, root: string): SourceMount {
  return SourceMount { prefix, loader: (path: string): Result<SourceFile | none, Diagnostic> => loadDiskSource(path, root + path.substring(prefix.length, path.length)) }
}

/** Explicit stdlib root is useful for tests and embedding; installed CLIs use resources. */
export function nativeSourceEnvironment(entry: string, stdlibRoot: string = ""): Result<SourceEnvironment, string> {
  try root := if stdlibRoot == "" then resourcePath("wasm-stdlib") else absolute(stdlibRoot)
  if !exists(root) { return Failure("missing doof-wasm standard library at " + root) }
  environment := SourceEnvironment { fallback: (path: string): Result<SourceFile | none, Diagnostic> => loadDiskSource(path, path) }
  environment.mounts.push(diskSourceMount("/std", root))
  try entryPath := absolute(entry)
  let directory = dirname(entryPath)
  while true {
    manifestPath := directory + "/doof.json"
    if exists(manifestPath) {
      manifestSource := readText(manifestPath) else { return Failure("could not read " + manifestPath) }
      try manifest := parsePackageManifest(manifestSource, manifestPath, directory, "", "wasm")
      environment.mounts.push(diskSourceMount("/src", directory + "/src"))
      for dependency of manifest.dependencies {
        if !dependency.name.startsWith("std/") { environment.mounts.push(diskSourceMount("/" + dependency.name, dependency.path)) }
      }
      if manifest.name != "" { environment.mounts.push(diskSourceMount("/" + manifest.name, directory)) }
      return Success(environment)
    }
    next := dirname(directory)
    if next == directory { return Success(environment) }
    directory = next
  }
}
