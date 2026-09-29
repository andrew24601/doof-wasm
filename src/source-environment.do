// Caller-owned logical source mounts. This module has no filesystem dependency.
import { SourceFile, Diagnostic } from "doof/src/semantic"
import { SourceLoader, noSourceLoader } from "doof/src/resolver"

export class SourceMount {
  prefix: string
  loader: SourceLoader
}

export class SourceEnvironment {
  mounts: SourceMount[] = []
  fallback: SourceLoader = noSourceLoader

  load(path: string): Result<SourceFile | none, Diagnostic> {
    let selected: SourceMount | none = none
    for mount of mounts {
      if path.startsWith(mount.prefix + "/") {
        if selected == none || mount.prefix.length > selected!.prefix.length { selected = mount }
      }
    }
    if selected != none { return selected!.loader(path) }
    return fallback(path)
  }
}
