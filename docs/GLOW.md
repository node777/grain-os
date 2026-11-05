# Glow

Glow is Grain's command language. A line of Glow calls the capabilities a
program holds and works with what comes back. What comes back is typed data
(records of integers, text, bytes and booleans), not text to be parsed, so
there is nothing to `grep` or `awk`: you name the field you want.

The desktop shell speaks it. The language is `grain/lib/glow.zig` (tested on
the host); what a domain holds is reached through `grain/proto/glow_call.zig`.

## A tour

```
kv.put key=7 value=42                  # a call: <capability>.<method> name=value ...
{previous: 0, had: false}

kv.get key=7
{value: 42, found: true}

let r = kv.get key=7; print r.value + 1
43

kumara.whoami | .name                  # a pipe selects a field
"kelp-oryx-lute"

kv.get key=7 | kv.put key=8            # missing arguments come from the left
{previous: 0, had: false}

for i in 0..3 { kv.put key=i value=(i*i) }
if (kv.get key=9).found { print "set" } else { print "not set" }

caps                                   # what this program holds
describe kv                            # a capability's methods and types
help
```

## The language

**Values.** `none`, integers (`42`, `0x2a`, `-3`), `true` and `false`,
text (`"a line\n"`), bytes (shown as `0x…`) and records (`{name: value, …}`).
A statement's value is shown unless it is `none`; `print a b …` shows
values on one line, text without quotes.

**Calls.** `<capability>.<method>` followed by `name=value` arguments. The
capability is the name the program's manifest gives the service (the
shell's `uses kv { … }` makes `kv`). Arguments are checked against the
method's parameters before anything is sent: an integer must fit its
field, text its length, and an enum is given by name. An argument that is
more than a literal, a name or a field goes in parentheses:
`value=(i * i)`. A call with no arguments needs none: `kumara.whoami`.

**Names.** `let x = …` names a value; `x.field` reads a field. Names last
until Glow's memory fills (then they start over).

**Pipes.** `a | b` evaluates `b` with `_` standing for `a`. A stage that
is `.field` selects from it. A stage that is a call takes, for each
parameter it is not given, the field of the same name from `_`: so
`kv.get key=7 | kv.put key=8` copies the value under key 7 to key 8.

**Operators.** `+ - * / %` on integers (`+` also joins text); `== != < <=
> >=`; `and`, `or`, `not`. Conditions must be true or false.

**Control.** `if cond { … } else { … }` (and `else if`), and
`for i in a..b { … }` over the integers from a up to b. Statements are
separated by `;` or new lines; `#` starts a comment.

**Errors say why and where**, in words: `kv.get needs key (u64)`, `this
record has no field 'valu' (it has found, value)`, `column 12: expected a
value`. A script that runs too long (a loop without end) is stopped.

## What it can reach

Exactly what the program holds: Glow adds no authority. In the shell that
is the manifest's `uses` for the shell domain. A method that takes a
capability cannot be called from Glow (there is none to pass), and a
service that is down answers "not reachable".

## Next

- Plans and undo: `plan { … }` to see what a block would do, `apply { … }`
  to run it all-or-nothing through Envoy's plan and undo (§3.5).
- The agent: a `grain_run` tool, so a script is one audited plan.
- grainsh in the web page speaking Glow, from the same code compiled to
  WebAssembly.
- Lists and maps, and functions.
