// Emitted alongside the regular bridge. Hosts supply synchronous text/path/blob
// operations; the helper supplies numeric conversion and scalar handle plumbing.
export function renderWasmStdHost(): string {
  return `
function createDoofStdHost(io = {}) {
  const scratch = new DataView(new ArrayBuffer(8));
  const reads = new Map(), writes = new Map(); let nextHandle = 0;
  let lastMonotonicNanos;
  const errorCode = error => ({ENOENT:0,EACCES:1,EPERM:1,EEXIST:2,EISDIR:3,ENOTDIR:4,ENOSYS:8,EINVAL:9})[error?.code] ?? 7;
  const required = name => { if (typeof io[name] !== 'function') { const error = new Error('missing compiler host operation ' + name); error.code = 'ENOSYS'; throw error; } return io[name]; };
  function floatStatus(text, single) {
    if (text === '') return 3;
    if (!/^[+-]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[eE][+-]?[0-9]+)?$/.test(text)) return 0;
    const value = Number(text), rounded = single ? Math.fround(value) : value;
    if (!Number.isFinite(rounded)) return 1;
    if (rounded === 0 && /[1-9]/.test(text.split(/[eE]/)[0])) return 2;
    return -1;
  }
  // Match the native default stream format: six significant digits (%g),
  // trimmed fractional zeros, and at least two exponent digits.
  function formatFloat(value) {
    if (Number.isNaN(value)) return 'nan';
    if (!Number.isFinite(value)) return value < 0 ? '-inf' : 'inf';
    if (value === 0) return Object.is(value,-0) ? '-0' : '0';
    const sign = value < 0 ? '-' : '';
    value = Math.abs(value);
    // Round the exact binary rational to nearest, ties to even, as native
    // streams do. JS toPrecision rounds exact decimal ties differently.
    scratch.setFloat64(0,value,true);
    const bits = scratch.getBigUint64(0,true);
    const binaryExponent = Number((bits >> 52n) & 2047n);
    const fraction = bits & ((1n << 52n)-1n);
    let numerator = binaryExponent === 0 ? fraction : fraction + (1n << 52n);
    let denominator = 1n;
    const shift = binaryExponent === 0 ? -1074 : binaryExponent-1075;
    if (shift >= 0) numerator <<= BigInt(shift); else denominator <<= BigInt(-shift);
    let exponent = Number(value.toExponential().split('e')[1]);
    const scale = 5-exponent;
    if (scale >= 0) numerator *= 10n ** BigInt(scale); else denominator *= 10n ** BigInt(-scale);
    let rounded = numerator / denominator;
    const remainder = numerator % denominator;
    if (remainder*2n > denominator || (remainder*2n === denominator && rounded%2n !== 0n)) rounded++;
    if (rounded === 1000000n) { rounded = 100000n; exponent++; }
    const digits = String(rounded).padStart(6,'0');
    const trim = text => text.includes('.') ? text.replace(/0+$/,'').replace(/[.]$/,'') : text;
    if (exponent < -4 || exponent >= 6) return sign + trim(digits[0]+'.'+digits.slice(1)) + 'e' + (exponent < 0 ? '-' : '+') + String(Math.abs(exponent)).padStart(2,'0');
    const point = exponent+1;
    return sign + trim(point <= 0 ? '0.'+'0'.repeat(-point)+digits : digits.slice(0,point)+'.'+digits.slice(point));
  }
  return {
    doofStdFloatStatus: floatStatus,
    doofStdParseDouble: text => Number(text),
    doofStdParseFloat: text => Math.fround(Number(text)),
    doofStdFloatBits: value => { scratch.setFloat32(0,value,true); return scratch.getInt32(0,true); },
    doofStdDoubleBits: value => { scratch.setFloat64(0,value,true); return scratch.getBigInt64(0,true); },
    doofStdFormatFloat: value => formatFloat(Math.fround(value)),
    doofStdFormatDouble: formatFloat,
    doofStdMonotonicNanos() {
      const value = required('monotonicNanos')();
      if (typeof value !== 'bigint' || value < 0n || value > 9223372036854775807n) throw new TypeError('monotonicNanos must return a nonnegative signed 64-bit bigint synchronously');
      if (lastMonotonicNanos !== undefined && value < lastMonotonicNanos) throw new RangeError('monotonicNanos must not decrease');
      lastMonotonicNanos = value;
      return value;
    },
    doofStdSha256HexString(text) {
      const digest = required('sha256HexString')(text);
      if (typeof digest !== 'string' || !/^[0-9a-f]{64}$/.test(digest)) throw new TypeError('sha256HexString must return 64 lowercase hexadecimal characters synchronously');
      return digest;
    },
    doofStdReadText(path) { try { const value = required('readText')(path); if (typeof value !== 'string') throw new TypeError('readText must return a string'); const handle = nextHandle++; reads.set(handle,value); return handle; } catch(error) { return -errorCode(error)-1; } },
    doofStdReadTextValue: handle => { if (!reads.has(handle)) throw new Error('invalid read handle'); return reads.get(handle); },
    doofStdCloseRead: handle => { reads.delete(handle); },
    doofStdWriteText(path,text) { try { required('writeText')(path,text); return -1; } catch(error) { return errorCode(error); } },
    doofStdOpenBlob(path) { try { required('writeBlob'); const handle = nextHandle++; writes.set(handle,{path,bytes:[]}); return handle; } catch(error) { return -errorCode(error)-1; } },
    doofStdWriteByte(handle,value) { const write = writes.get(handle); if (!write) return 10; write.bytes.push(value); return -1; },
    doofStdCloseBlob(handle,commit) { const write = writes.get(handle); if (!write) return 10; writes.delete(handle); if (!commit) return -1; try { required('writeBlob')(write.path,Uint8Array.from(write.bytes)); return -1; } catch(error) { return errorCode(error); } },
    doofStdAbsolute(path) { try { const value = required('absolute')(path); return typeof value === 'string' ? value : ''; } catch { return ''; } },
  };
}
export { createDoofStdHost };
`
}
