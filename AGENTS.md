# AGENTS.md — lex-pack-flex

This file is for AI assistants (Claude Code, Cursor, Aider, Copilot, …)
working in this repo. Humans should read `README.md` first; agents should
read this **first**, then run `lex agent-guidelines` for the authoritative
idiom contract before writing any code.

## 1. Install the Lex toolchain

If `lex --version` doesn't work, download the pre-built binary for your
platform. This project was scaffolded against **v0.10.11** — the CI
workflow is pinned to that version, so use it locally too.

```sh
LEX_VERSION=v0.10.18
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)   TARGET=x86_64-unknown-linux-gnu  ;;
  Linux-aarch64)  TARGET=aarch64-unknown-linux-gnu ;;
  Darwin-x86_64)  TARGET=x86_64-apple-darwin       ;;
  Darwin-arm64)   TARGET=aarch64-apple-darwin      ;;
  *) echo "unsupported platform" >&2; exit 1 ;;
esac
curl -sSfL "https://github.com/alpibrusl/lex-lang/releases/download/${LEX_VERSION}/lex-${LEX_VERSION}-${TARGET}.tar.gz" | tar -xz
sudo install -m 0755 "lex-${LEX_VERSION}-${TARGET}/lex" /usr/local/bin/lex
lex --version
```

Windows: download `lex-v0.10.11-x86_64-pc-windows-msvc.zip` from
<https://github.com/alpibrusl/lex-lang/releases/tag/v0.10.11> and put
`lex.exe` on `PATH`.

**Fallback (build from source).** Only needed if you want a version
that has no published release yet (off-`main` fixes, custom branches):

```sh
git clone --depth=1 https://github.com/alpibrusl/lex-lang /tmp/lex-lang
cd /tmp/lex-lang && cargo build --release -p lex-cli
export PATH="/tmp/lex-lang/target/release:$PATH"
```

Requires Rust 1.80+. Takes ~3 minutes the first time.

## 2. The loop

Every change goes through this loop. **Do not claim done before `lex ci`
is green.**

```sh
lex check src/main.lex   # type-check (fast, catches most issues)
lex test                 # run all tests/test_*.lex files
lex fmt src/ tests/      # auto-format (or `lex fmt --check` to verify)
lex ci                   # umbrella: pkg install + check --strict + fmt --check + test
```

`lex check --output json` emits structured errors with `rule_tag`,
`position`, and `rule_explanation` fields — use these when iterating.

## 3. Lex in 60 seconds (the bits most likely to trip you up)

Coming from Rust / TypeScript / Python? These are the differences worth
internalising before writing your first line:

```lex
import "std.list" as list           # stdlib import, alias is mandatory
import "./helper" as h              # local import (path relative to this file)

type Status = Healthy | Sick(Str)   # tagged union, no `enum` keyword

fn parse(s :: Str) -> Result[Int, Str]   # `::` types params; `->` is the return arrow
  examples {                        # OPTIONAL: pure fns can carry test cases
    parse("1") => Ok(1),
    parse("x") => Err("not a number"),
  }
{
  let n := str.length(s)            # `:=` for let-binding, NOT `=`
  if n == 0 {
    Err("empty")
  } else {
    Ok(n)
  }
}

fn save(path :: Str, body :: Str) -> [fs.write] Result[Unit, Str] {
  fs.write(path, body)              # `[effects]` between `->` and the type
}
```

Key rules:

1. **Types use `::`, lets use `:=`, returns use `->`.** Easy to mix up; the
   compiler error is clear when you do.
2. **Effects are types.** Any function that does I/O, time, randomness,
   network, LLM calls, etc. must declare them: `-> [io] Nil`,
   `-> [http.get, fs.read] Result[Str, Str]`. Pure functions declare
   nothing. The checker refuses bodies that reach outside their declaration.
3. **No exceptions.** `Result[T, E]` and `Option[T]` are the only error /
   absence channels. Idiom: `match res { Ok(x) => ..., Err(e) => ... }`.
4. **`examples { … }` blocks are part of the signature.** They're
   compiled into the canonical AST and run at `lex check` time. Use them
   for every pure function — they're cheaper than a test and they survive
   refactors.
5. **No mutation in user code.** No `mut`, no `var`. Build new values.
6. **One canonical AST per meaning.** `lex fmt` is deterministic; don't
   fight it.

## 4. This project

- Source lives in `src/` — entry point is `src/main.lex`.
- Tests live in `tests/` — files must start with `test_` and export
  `fn run_all() -> ...`.
- Dependencies go in `[dependencies]` of `lex.toml`; run `lex pkg install`
  after editing.
- Before pushing: `lex ci`. CI runs the same command.

## 5. Idiom rules — read before writing code

Run this in the project root:

```sh
lex agent-guidelines               # full prescriptive contract (~10 pages)
lex agent-guidelines > AGENTS.md   # capture into the repo so it travels with the code
```

The rules are numbered and stable. The four that matter most when
you're tempted to skip them:

1. **Narrow effects, always.** `fn foo() -> [fs_write("/tmp/x")] T`,
   not `[fs_write]`. If the type checker rejects, narrow the *body*,
   not the signature. Rule 1.2 in the guidelines.
2. **Repair, don't regenerate.** When `lex check` fails, run
   `lex --output json check` to get the structured error, then
   `lex repair --apply --transform '<suggested_transform>'`. Only
   regenerate after two failed repair attempts. Rules 4.1–4.3.
3. **`examples {}` blocks on every pure fn.** They're part of the
   SigId and run at `lex check` time — free regression tests with no
   `tests/` boilerplate. Rule 2.1.
4. **Use the stdlib.** `std.crypto` not hand-rolled crypto, `std.conc`
   not threads, `std.sql` not string-concat SQL. Section 3.

## 6. Need more?

Deep references in the upstream repo:

- **`lex agent-guidelines`** — the authoritative idiom contract
  (travels with the toolchain version).
- **`docs/AGENT.md`** — reference: error envelope schema, every
  `rule_tag`, stdlib module summary, every sharp edge.
- **`docs/design/canonicalization.md`** — which edits preserve a
  SigId and which break it.
- **`docs/index.html`** — the design pitch (effects-as-types,
  content-addressed AST, op log, attestations).
- **`README.md`** in [alpibrusl/lex-lang](https://github.com/alpibrusl/lex-lang)
  — design rules, stdlib index, examples.

When a `lex check` error confuses you, search its `rule_tag` in
`docs/AGENT.md` — most tags have an explanation and a fix template.
