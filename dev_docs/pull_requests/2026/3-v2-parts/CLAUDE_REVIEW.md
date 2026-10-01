# PR #3 — Add markdown and layout parts, single-line subject, locate/sources

**Author:** timujinne · **Merged:** 2026-10-01 (`cc932f5`) · **Reviewer:** Claude
**Released as:** 0.2.2

## Summary

`render/4` grows from three parts to five (`markdown`, `layout`) and now
returns all five keys. `subject` becomes a single trimmed line. `Overrides.locate/4`
returns `{path, content}` and `read/4` is rebuilt on it, and `Templates.sources/3`
reports where each part came from, on the same resolution as `render/4`.

The design holds up. `read/4`, `render/4`, `missing_variables/4` and `sources/3`
all go through one `locate/4`, so a preview cannot disagree with what is sent.
`layout` normalizes its locale to `nil` before the cache key is built, so a
locale-specific file is never read and mints no extra entries. The cache key is
now tagged (`:located`), which protects a live reload from reading a 0.2.1
bare-binary entry as a `{path, content}` pair. `reset_cache/1` matches the new
key shape. The findings below are about edge cases in the new trimming.

## Findings

### IMPROVEMENT - MEDIUM — `layout` kept a leading byte-order mark (fixed)

`subject` strips a BOM before trimming, because `String.trim/1` does not treat
U+FEFF as whitespace. `layout` was only passed through `String.trim/1`, so a
`layout.txt` saved with a BOM by a Windows editor returned `"\u{FEFF}billing"`.
The caller then looks up a group that does not exist, silently, with nothing
visible in the file. A layout name is the part where an invisible character
matters most. Extracted `trim_bom/1` and use it for both parts; test added.

### NITPICK — interior line breaks left the surrounding whitespace (fixed)

`~r/[\r\n]+/` → `" "` turns `"New login\n    to your account"` into
`"New login      to your account"`: a wrapped file with indented continuation
lines gave a subject with a run of spaces. The regex is now `\s*[\r\n]\s*`, so
the break and the whitespace around it become one space. Test added; README and
moduledoc say so.

### NITPICK — hand-wrapped doc lines (fixed)

Three paragraphs (`README.md` raw-substitution paragraph, `Substitution`
moduledoc, `Overrides` moduledoc) had been edited in place and left with a
very long line. Rewrapped. No wording change.

### NOTE — a blank `layout` file returns `""`, not `nil` (not changed)

A `layout.txt` containing only whitespace is trimmed to `""`, and `sources/3`
reports it as `{:file, path}`. That matches the package's stated stance for
every other part — an empty file is found, and whether empty means absent is
the caller's decision — so a caller that wants `nil` checks for `""`. Making
`layout` the one part that collapses blank to `nil` would split that rule for
the sake of one line.

### NOTE — `reset_cache/1` does not erase 0.2.1's untagged keys (not changed)

After a live reload from 0.2.1, old 5-tuple entries stay in `:persistent_term`
until the VM restarts, because `reset_cache/1` now matches only the tagged
shape. They are never read, and there is one per looked-up part, so the leak
is bounded and transient. Matching both shapes to clean up a development-only
reload path would be more code than the problem is worth.

### NOTE — version: 0.2.2, not 0.3.0

`render/4` gains two keys and `subject` is trimmed. Existing pattern matches on
`%{subject:, text:, html:}` still work; only a whole-map equality assertion
would notice. 0.2.1 shipped a feature as a patch for the same reason, and core
pins this package tightly, so a minor bump would strand consumers for no
breaking change. `phoenix_kit` core still pins `~> 0.1.0` and needs raising
before it can use any of this.

## Gate

`mix format`, `compile --warnings-as-errors`, `deps.unlock --check-unused`,
`credo --strict`, `dialyzer` and `mix test` (6 doctests, 114 tests) are clean.
The repo defines no `precommit` alias, so the steps ran individually.
