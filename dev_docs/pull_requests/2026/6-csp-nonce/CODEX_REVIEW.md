# PR #6 — Editor preview styles under a nonce policy

Reviewed the optional PhoenixKit lookup, LiveComponent updates, preview HTML
rewriting, and source lint checks at `c848c79`.

## Findings and fixes

- **Performance.** Each preview with a nonce rebuilt the token regex, and even
  messages containing no style tags went through token replacement. Compile the
  regex once and skip tokenization when the HTML contains no candidate opener.
  The malformed-input timing tests now include a candidate so they still
  exercise the tokenizer.
- **Lint coverage.** The inline-tag check accepted any opening tag containing
  `src=`, including a style element or a script with a `data-src` attribute.
  It also missed uppercase tag names. Match tag names case-insensitively and
  use the existing test HTML parser to recognize an external script. Regression
  cases cover mixed-case attributes, quoted text, and style elements.
- **Test maintenance.** Two bundle checks iterated over a permanently empty
  list. The package already checks that it ships no JavaScript. Keep that
  assertion and remove the unused bundle heuristics.

## Verification scope

Component tests cover explicit and fallback nonces, nonce changes, an empty
iframe sandbox, and isolation from files and renderer output. The optional
PhoenixKit integration uses a stand-in module. The review did not exercise a
running PhoenixKit host or repeat the author's browser checks.
