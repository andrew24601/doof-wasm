import function println(value: string): none
import function echo(value: string): string

export function callHost(value: string): string {
  println(value)
  return echo(value)
}

export function literal(): string => "ready"
