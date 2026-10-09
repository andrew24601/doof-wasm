# Implementation gaps compared with doof-lang

This inventory compares the checked language in `../doof-lang/spec/` and its
native emitter with doof-wasm's source lowering. The main boundary is
`src/doof-lowering-functions.do`, `src/doof-lowering.do`, and the carrier mapping
in `src/doof-lowering-support.do`; unsupported syntax frequently has the
necessary underlying doof-- operations already.

## Straightforward gaps filled

| Feature | Previous gap | Implemented behavior |
| --- | --- | --- |
| Labeled loops and exits | Labels were rejected during source lowering. | `while`, C-style `for`, and array/range `for-of` support labels; nested `break label` and `continue label` carry values to the selected loop using declaration identity, even across shadowing. Continue runs that loop's update. |
| Optional indexing | All `?[]` reads were rejected. | Nullable arrays and strings return `none` on absence, evaluate the receiver once, and skip index evaluation. Present receivers retain bounds checking. |
| Scalar case statements | Only boxed union subjects, type patterns, `none`, and wildcards were accepted. | Supported scalar subjects, value patterns, integer ranges including open bounds, and short-circuit alternative patterns now lower through existing comparisons and branches. Named type captures remain limited to single-pattern arms. |
| Case expressions and yielding blocks | Only statement cases and value `if` were supported. | Case expressions join checked arm values and mutable locals; block arms and local `<-` blocks use scoped yield targets, including nested cases, loops, and terminating arms. |
| Mixed numeric comparisons | Operands with different Wasm widths could reach emission without promotion. | Numeric primitive comparisons promote both operands to a common width, including mixed-width case range bounds. Boxed union comparisons retain nominal tags. |
| Scoped `with` bindings | Scoped bindings were rejected. | Sequential immutable bindings and retained `_` discards support annotations, nesting, shadowing, captures, and escaping references. Scoped roots release on normal completion, loop exits, and yields; returns use the function cleanup epilogue. |

Execution tests cover nested loop exits, array increments, index side effects,
reference/union elements, bounds traps, string/enum/bool case values, integer
boundaries, pattern side effects, partial case fallthrough, expression result coercions, type
captures, nested yields, terminating arms, and repeated-call
heap cleanup.

## Remaining work

| Area supported by doof-lang | Current doof-wasm boundary | Work needed |
| --- | --- | --- |
| Loop `then` | The frontend accepts it, but doof-wasm rejects it. The native loop emitter also omits this clause. | Establish native behavior and add a distinct normal-completion edge that bypasses `then` on breaks and non-local exits. |
| Destructuring | Tuples and general destructuring are unsupported, including `for-of` and `try` patterns. | Add carriers and binding lowering, preserving evaluation order and checked failure behavior. |
| Collections | Arrays and a narrow `Map<string, bool>` implementation exist. | Generalize map carriers and methods; add sets, tuples, streams, and their iteration protocols. |
| Class features | Ordinary fields, methods, and construction work; static/weak/multiple-name fields, construction spreads, constructor factories, and general method values do not. | Expand checked construction/member lowering and add lifetime support for weak references. |
| Union methods | Shared field reads and writes dispatch by tag; general method dispatch does not. | Dispatch checked shared methods by concrete receiver tag with correct argument/result coercion. |
| Generics | Generic source functions, classes, and interfaces are rejected. | Instantiate checked generic uses before carrier and function lowering. |
| Enums and formatting | Integer enums and scalar interpolation work; string enums and collection/union interpolation do not. | Add enum carriers and recursive checked formatting. |
| Module state | Scalar constants and immutable array literal trees work. | Lower mutable globals and executable initialization with module ordering and owned roots. |
| Structs and concurrency | Compatibility options box immutable structs and execute async eagerly. | General structs need value-copy semantics; full async and actors need a scheduler and isolation/runtime support. |
| Fallible control flow | Statement `try` declarations/assignments, layered Result/none unwraps, optional access, and declaration-else (including continuing discard handlers) work. | Add `??=`, Result statement-else, try destructuring/else, and remaining checked catch and `as` flows. |

These are source/backend observations, not claims that every frontend-supported
combination already has correct native emission. Loop `then` is one concrete
example where parser/checker acceptance exceeds native emission behavior.
