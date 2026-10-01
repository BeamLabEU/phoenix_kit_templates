# PR #2 — Allow one leading underscore in template names

**Author:** timujinne · **Merged:** 2026-10-01 (`5ea6120`) · **Reviewer:** Codex
**Released as:** 0.2.1 · **Reviewed:** 2026-10-01

## Result

No additional defects found in this release after Claude's changes. Reviewed
the diff from `v0.2.0` to `v0.2.1`, the implementation surrounding the name
validation and cache lookup, and the tests for reserved names.

The optional leading underscore preserves the anchored path-safety rule.
Rejected names return before consulting the cache, and reserved names retain
the ordinary root and locale fallback behavior. The public rendering test
Claude added covers raw HTML substitution for `_layout`.

The separate review of PR #3 records the issues found in today's other release:
[CODEX_REVIEW.md](../3-v2-parts/CODEX_REVIEW.md).

## Validation

The unmodified `v0.2.2` checkout passed 6 doctests and 114 tests, including all
PR #2 tests. The fixes to PR #3 retain those tests; see its review for the final
gate results.
