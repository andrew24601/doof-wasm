import function doofStdAbsolute(path: string): string

export function absolute(path: string): Result<string, string> {
  value := doofStdAbsolute(path)
  if value == "" { return Failure("could not resolve absolute path " + path) }
  return Success(value)
}
