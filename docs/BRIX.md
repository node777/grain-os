# Brix

Brix is Grain's declaring language. A `.brix` file says what a system is
made of and how the parts fit; it evaluates to plain data, and the manifest
check then proves the data holds together. You declare the shape; the check
says whether it holds.

`system/dev.brix`, `system/tests/faults.brix` and `system/tests/miswired.brix`
are the manifests the build uses. The language is in `grain/brix/brix.zig`;
the command is `tools/brix`.

```sh
zig build check-manifest                         # the default system (system/dev.brix)
zig build check-manifest -Dsystem=system/my.brix
zig-out/bin/brix --check system/my.brix          # the same check, directly
zig-out/bin/brix --print system/my.brix          # the plain data it evaluates to (ZON)
```

## A whole system

```brix
name = grain-dev
halt_when_tasks_finish

template driver {
    priority = 200
    budget = 1ms
    period = 10ms
    debug_console
}

domain console like driver {
    program = virtio_console
    restart = on_fault
    device port { virtio = 3 }
    provides console { protocol = console.v1 }
}

domain hello {
    program = hello
    kind = task
    uses console { from = console.console, protocol = console.v1 }
}

# The agent's door: skipped when no agent port is attached.
domain envoy {
    program = envoy
    kind = task
    device port { virtio = 3, instance = 1, optional }
}

agent {
    envoy = envoy
    grant console { from = console.console, protocol = console.v1, uses = 20 }
}
```

## The rules

That is the whole language:

| You write | It means |
|---|---|
| `key = value` | Set a field. |
| `key` alone on a line | Set a true/false field to true (`debug_console`). |
| `200`, `1_000`, `0x10` | Numbers. |
| `1ms`, `4s`, `250us`, `128KiB`, `2MiB`, `512B` | Numbers with a unit. |
| `"text"` or a bare word | Text, or one of a field's choices: `on_fault`, `console.v1`, `grain-dev`. Quotes are only needed for spaces or symbols. |
| `[a, b, c]` | A list. |
| `{ k = v, k = v }` | A record, written inline. |
| `word label { ... }` | A **block**. If the record has a list `words` (or `word`), it adds one element named `label`: `device port { }` adds to `devices`, `uses console { }` to `uses`, `domain hello { }` to `domains`. If it has a record field `word`, the block fills it (`agent { }`). |
| `template t { ... }` | Entries to reuse; top level only. Not part of the output. |
| `domain x like t, u { ... }` | Apply template `t`, then `u`, then the body. Later layers override earlier ones. A template reached twice applies once, at its first place. Templates can be `like` other templates. |
| `# ...` | A comment. |

Entries are separated by new lines or commas.

**Units pick the field.** `budget = 1ms` sets `budget_us` to 1000, and
`memory = 128KiB` sets `memory_kib` to 128. Conversions must be exact:
`period = 1500us` is fine, but `memory = 1000B` is refused (not a whole KiB).
The full field name with a plain number (`budget_us = 1000`) also works.

**Errors say where and how to fix it.** Every error names the file, line and
column, shows the line, and suggests a fix:

```
system/my.brix:4:3: domain 'a' has no `budgt`; did you mean `budget`?
      budgt = 1ms
      ^
system/tests/miswired.brix:12:1: domain 'hello' uses 'console.consol', but no domain provides it (write it as "<domain>.<service>")
    domain hello {
    ^
```

Errors from the manifest check (the second one) point at the block they
name.

## What it evaluates to

Brix evaluates against a Zig type, `schema.Manifest`, and never goes beyond
it. Every field, default and choice comes from the schema, so the language
needs no changes when the schema grows. The result is written as ZON, the
plain data Steward embeds and grain-pack hashes. The closure hash covers that
data, not the `.brix` text, so comments, templates and formatting don't
change a system's identity; only what it *is* does.

Evaluation is total and deterministic. There is no I/O, no recursion (template
cycles are refused), no clock and no environment. The same file always gives
the same data.

## Why not just ZON

ZON is fine data but a poor door for people: every domain repeats the same
budget, period and debug-console lines, durations are bare microsecond
counts, and an error says only that the data didn't parse. Brix keeps the
data model and changes the writing. You can share entries with templates,
write units, get named blocks instead of nested anonymous lists, and get an
error message aimed at the line you wrote.
