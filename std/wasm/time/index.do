// Compiler timing subset. The host clock returns process-local nanoseconds.
import function doofStdMonotonicNanos(): long

export class Duration {
  nanos: long

  toNanos(): long => nanos
}

export class MonotonicInstant {
  ticksNanos: long

  static now(): MonotonicInstant => MonotonicInstant { ticksNanos: doofStdMonotonicNanos() }

  durationUntil(other: MonotonicInstant): Duration => Duration { nanos: other.ticksNanos - ticksNanos }
}
