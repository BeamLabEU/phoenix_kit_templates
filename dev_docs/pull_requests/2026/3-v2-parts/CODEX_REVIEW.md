# PR #3 — Markdown and layout parts, single-line subjects, locate/sources

**Author:** timujinne · **Merged:** 2026-10-01 (`cc932f5`) · **Reviewer:** Codex
**Released as:** 0.2.2 · **Reviewed:** 2026-10-01

## Scope

Reviewed `v0.2.1..v0.2.2`, including Claude's follow-up changes, the surrounding
renderer, override lookup/cache and substitution code, and the current core
email consumer. Fixes below are local to this package; no version bump or
publication is part of this review.

## Findings

### BUG - MEDIUM — subject normalization takes quadratic time (fixed)

The new `~r/\s*[\r\n]\s*/` starts its greedy whitespace prefix at each possible
position. When a long run has no newline, each attempt scans and backtracks
over the remaining run. This affects both template content and substituted
values, since normalization runs after substitution.

Reproduction: render a default subject of `"A" <> String.duplicate(" ", 50_000)
<> "B"`. The unchanged release took 12.1 seconds on this workspace; 10,000
spaces took 486 ms. The patched implementation took about 1.8 ms for the
50,000-space input, including renderer overhead. These measurements illustrate
the issue rather than guarantee a particular latency.

Fix: scan complete whitespace runs once, replacing only a run containing CR
or LF with one space. Other runs retain their content. A regression test uses
the public `render/4` API with a five-second test timeout; it timed out on the
released implementation and passes with the fix.

### BUG - LOW — Unicode whitespace around line breaks survives (fixed)

The old regex has no Unicode option, so its whitespace class misses characters
such as a non-breaking space and an em space. A subject containing
`"New login\u{00A0}\r\n\u{2003}to your account"` returned the non-breaking space,
an additional ASCII space, and the em space. This violates the documented rule
that whitespace surrounding a line break becomes one space.

Fix: the whitespace-run regex uses Unicode semantics. A regression test covers
an override file and a substituted variable; it failed on the released code.
Whitespace without CR/LF remains intact.

### BUG - MEDIUM — documented Markdown pipeline breaks placeholder links (fixed guidance)

The README and module docs said to render Markdown and then substitute because
renderers percent-encode braces in link targets. That encoding is precisely
what prevents the subsequent substitution from recognizing the placeholder.

Reproduced with the workspace's compiled MDEx dependency and this package's
substitution module:

```elixir
MDEx.to_html!("[Confirm]({{confirmation_url}})")
# => "<p><a href=\"%7B%7Bconfirmation_url%7D%7D\">Confirm</a></p>"
```

Calling `Substitution.substitute/3` on that HTML with a bound confirmation URL
leaves it unchanged. Following the old instructions therefore produces a
broken confirmation link despite supplying the variable.

Fix: document that callers own the pipeline and must preserve placeholders
through Markdown rendering when substituting afterwards. Explain protecting
them with renderer-safe tokens and restoring them before HTML-escaped
substitution. Correct the related implementation comment and the `rendered`
type description. The Markdown part remains verbatim as the API promises; no
Markdown dependency or renderer is added to this leaf package. A caller still
needs to implement and verify its renderer-specific pipeline.

## Other reviewed behavior

No additional defects found in the new `locate/4` and `sources/3` resolution,
empty-file handling, root precedence, locale-less layout selection, or tagged
cache key. Existing fallback, substitution and path-safety tests pass.

## Validation

- Baseline: 6 doctests, 114 tests, no failures.
- Regression reproduction: the two new tests failed against the released code
  (Unicode mismatch and timeout).
- After fixes: 6 doctests, 116 tests, no failures.
- Final quality gate: formatting, compilation with warnings as errors,
  unused-lock check, strict Credo, Dialyzer, the full test suite, and documentation
  generation with warnings as errors all pass.
