// Deliberately limited compiler I/O surface. The host owns handles and maps
// failures to IoError ordinals. Arrays never cross the host ABI.
export enum IoError { NotFound = 0, PermissionDenied = 1, AlreadyExists = 2, IsDirectory = 3, NotDirectory = 4, InvalidPath = 5, Interrupted = 6, Other = 7, Unsupported = 8, InvalidArgument = 9, Closed = 10, UnexpectedEof = 11, WouldBlock = 12 }
import function doofStdReadText(path: string): int
import function doofStdReadTextValue(handle: int): string
import function doofStdCloseRead(handle: int): none
import function doofStdWriteText(path: string, content: string): int
import function doofStdOpenBlob(path: string): int
import function doofStdWriteByte(handle: int, value: byte): int
import function doofStdCloseBlob(handle: int, commit: bool): int

function ioError(status: int): IoError {
  if status == 0 { return IoError.NotFound }
  if status == 1 { return IoError.PermissionDenied }
  if status == 2 { return IoError.AlreadyExists }
  if status == 3 { return IoError.IsDirectory }
  if status == 4 { return IoError.NotDirectory }
  if status == 5 { return IoError.InvalidPath }
  if status == 6 { return IoError.Interrupted }
  if status == 8 { return IoError.Unsupported }
  if status == 9 { return IoError.InvalidArgument }
  if status == 10 { return IoError.Closed }
  if status == 11 { return IoError.UnexpectedEof }
  if status == 12 { return IoError.WouldBlock }
  return IoError.Other
}

export function readText(path: string): Result<string, IoError> {
  handle := doofStdReadText(path)
  if handle < 0 { return Failure(ioError(-handle - 1)) }
  value := doofStdReadTextValue(handle)
  doofStdCloseRead(handle)
  return Success(value)
}

export function writeText(path: string, content: string): Result<none, IoError> {
  status := doofStdWriteText(path, content)
  if status >= 0 { return Failure(ioError(status)) }
  return Success(none)
}

export function writeBlob(path: string, data: readonly byte[]): Result<none, IoError> {
  handle := doofStdOpenBlob(path)
  if handle < 0 { return Failure(ioError(-handle - 1)) }
  for value of data {
    status := doofStdWriteByte(handle, value)
    if status >= 0 { _ := doofStdCloseBlob(handle, false); return Failure(ioError(status)) }
  }
  status := doofStdCloseBlob(handle, true)
  if status >= 0 { return Failure(ioError(status)) }
  return Success(none)
}
