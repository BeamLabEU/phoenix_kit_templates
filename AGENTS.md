# phoenix_kit_templates

A dependency-free renderer for message templates, with an optional LiveView
editor (`PhoenixKit.Templates.Editor`). `phoenix_kit` depends on this package,
so it depends on neither PhoenixKit nor Gettext; keep it that way.

## Checks

```bash
mix format
mix credo --strict
mix dialyzer
MIX_ENV=test mix test
```

## Content-Security-Policy

The editor works under a host policy that allows inline code by nonce only
(`script-src 'self' 'nonce-…'; style-src 'self' 'nonce-…'`). It renders no
inline `<script>` / `<style>` and no inline event handler of its own, and the
package ships no JavaScript. `style="…"` attributes of a previewed message take
no nonce: the host's `style-src-attr` has to allow them.

- The preview is an `<iframe sandbox="" srcdoc>`, and an srcdoc document
  inherits the embedding page's policy: the previewed message's `<style>` tags
  are stamped with the page's nonce (`PhoenixKit.Templates.CSP.stamp_styles/2`).
  The nonce is the editor's `style_nonce` attribute, else PhoenixKit's.
- The stamping reads markup as HTML's tokenizer does, in part; it is no parser
  (CDATA inside `<svg>` and `<!--<script>` fool it). The preview's frame stays
  `sandbox=""`: never `allow-scripts`.
- Stamp at render time, the preview only. A nonce belongs to one page: never
  put it into a file, the renderer's cache or a message that is sent.
- `PhoenixKitWeb.CSP` is reached only through `PhoenixKit.Templates.CSP`, which
  feature-detects it (`Code.ensure_loaded?/1` + `function_exported?/3` +
  `apply/3`) and answers `nil` without it.
- No inline event handlers (`onclick=` …): no nonce covers an attribute. Use a
  `phx-` binding.
- `test/csp_inline_tags_test.exs` fails on an inline tag without a nonce, an
  inline handler or a direct call to PhoenixKit's module;
  `test/phoenix_kit/templates/csp_test.exs` and `editor_test.exs` cover the
  stamping and the preview.
