// Minimal builder required by the encoder. Bit reinterpretation is a scalar
// host primitive; byte assembly and ownership remain inside Doof.
import function doofStdFloatBits(value: float): int
import function doofStdDoubleBits(value: double): long

export class BlobBuilder {
  bytes: byte[] = []

  writeFloat(value: float): none {
    let bits = long(doofStdFloatBits(value))
    if bits < 0L { bits += 4294967296L }
    for _ of 0..<4 { this.bytes.push(byte(bits % 256L)); bits = bits \ 256L }
  }

  writeDouble(value: double): none {
    let bits = doofStdDoubleBits(value)
    // Arithmetic division needs correction for negative two's-complement bits.
    for _ of 0..<8 {
      let next = bits \ 256L
      if bits < 0L && bits % 256L != 0L { next -= 1L }
      this.bytes.push(byte(bits - next * 256L))
      bits = next
    }
  }

  build(): readonly byte[] => this.bytes.cloneReadonly()
}
