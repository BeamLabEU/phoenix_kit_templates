# PR #2 — Allow one leading underscore in template names

**Author:** timujinne · **Merged:** 2026-10-01 (`5ea6120`) · **Reviewer:** Claude
**Released as:** 0.2.1

## Summary

`@name_pattern` goes from `\A[a-z0-9][a-z0-9_\-]*\z` to
`\A_?[a-z0-9][a-z0-9_\-]*\z`, so a shared part like `_layout` resolves through
`Overrides.read/4` like any other name. The README and moduledocs are reworded
to stop describing core's auth emails as text-only, and seven tests cover the
new names.

The change is correct and small. I checked it against the path-safety claim:
the leading `_` can only be followed by `[a-z0-9]`, so `.`, `/`, `-` and a
second `_` can never come right after it. `\z` (not `$`) still rejects a
trailing newline. Names are validated before the `:persistent_term` lookup, so
rejected names still mint no cache entries, and the PR tests that. No other
code validates names, so nothing else needed to change. The findings below are
about a stale comment and one missing end-to-end test.

## Findings

### IMPROVEMENT - LOW — no test went through `Templates.render/4` with a reserved name (fixed)

Every new test calls `Overrides.read/4` directly. `render/4` is the public
entry point, and it is the path that reads all three parts for a name. A
`_layout` carries only `html`, so the useful check is that `subject` and `text`
come back `nil` and that `{{{content}}}` substitutes raw. Added that test to
`templates_test.exs`.

### NITPICK — a test comment still claimed core's auth emails are text-only (fixed)

The PR reworded the README and moduledocs to say that what a caller does
without `html` is the caller's decision. `templates_test.exs` still carried
"Core's auth emails ship text-only". Reworded to match.

### NITPICK — one new test repeats assertions from its neighbour (left)

"falls back to the locale-less file when there is no locale file" asserts
`"en-GB"` → `"plain"`. The previous test already asserts the same fallback
for `"fr"`. It costs nothing to keep and reads as a clear statement of the
rule, so I left it.

### NOTE — an unenforced convention (not changed)

Ordinary names may also start with `_`, so a host can name a normal template
`_foo`. The README and moduledoc both say the package does not enforce the
convention. That is a deliberate choice: the package has no way to tell a
layout from a template, and enforcing it would mean inventing a list of
reserved names. Left as documented.

### NOTE — core is not affected until it opts in

`phoenix_kit` pins `~> 0.1.0`, which cannot resolve 0.2.x. A core `_layout`
needs the core pin raised to this release first.

## Gate

`mix format`, `compile --warnings-as-errors`, `deps.unlock --check-unused`,
`credo --strict`, `dialyzer`: see the release commit. Tests: 6 doctests,
84 tests, 0 failures.
