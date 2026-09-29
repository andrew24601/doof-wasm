// Synchronous SHA-256 primitive used by the frontend's source cache.
// Strings contain raw byte characters, matching the native string storage.
import function doofStdSha256HexString(text: string): string

export function sha256HexString(text: string): string => doofStdSha256HexString(text)
