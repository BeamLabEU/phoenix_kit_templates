# Changelog

## Unreleased

### Added

- **Editor: a text version in the preview, and converters.** A `preview` may
  return `{subject, html, text}`; the preview then has *HTML* and *Text* tabs
  (`{subject, html}` works as before). An optional `convert` attribute,
  `%{to_text: callback, markdown_to_html: callback}`, adds *Fill text from
  content* (Markdown if not blank, else HTML, into Text) and *Markdown → HTML*
  (into HTML). They fill the form, not the files: the user's other unsaved
  fields are kept, and Save writes the converted part like an edited one
  (a part a save refuses stays in the form).
  Converters are called with the form's text as typed, placeholders included,
  and should return the placeholders as they are, in link targets too (see
  the Markdown note under 0.2.3's Documentation); they fail like the other
  callbacks, leaving the form as it was. The buttons submit the form with an
  `action` (LiveView 1.0 or later); Save is the first, and a submit that
  names none saves. No buttons read-only or without `convert`.

## 0.2.3 - 2026-10-07

### Added

- **A write API on one root:** `Overrides.write/5`, `delete/4`,
  `delete_template/2`, `copy_template/3`, `list/1`, plus `valid_name?/1` and
  `max_bytes/0`. Same layout, name and locale rules as reading, but a
  malformed locale is refused instead of falling back; the path stays inside
  the root (symlinks included); writes are atomic (synced, then renamed; a
  replaced file keeps its permissions) and capped at 256 KiB of UTF-8; the
  cache is reset for the root after every change, a failed
  `delete_template/2` included. `delete/4` removes the template directory
  along with its last file, since git does not track an empty one. Errors are
  `{:error, reason}`. `write/5` returns the paths it created — the template
  directory too when the write is its first part file — so a host can fix
  their ownership.
  `copy_template/3` copies every regular file of a template directory, a
  host's own files beside the parts included, through a hidden directory
  renamed into place, and returns the new directory and its files.
- **A `label` part** (`label[.locale].txt`) that the write API and `list/1`
  know and rendering never reads — a caption for an editor's list.
- **`PhoenixKit.Templates.Editor`**, a `Phoenix.LiveComponent` for editing
  those files: list (shared `_`-prefixed parts grouped apart), per-language
  editing of `label`/`subject`/`text`/`markdown`/`html`, create empty or as a
  copy, delete with confirmation, a host preview in a script-less sandboxed
  iframe, read-only mode, an `after_write` callback (the paths a save or copy
  created) and an `after_change` callback (the template's name after any
  change on disk, deletions included). `name_prefixes` is checked on every
  write, an unsaved draft included; a `preview`, `after_write` or
  `after_change` that raises, throws or exits is shown as an error, not a
  crash, and logged with its stacktrace. A preview must return strings or
  `nil` (a `{:safe, _}` is escaped, anything else is an error); it is not
  called for a template with no files, and is called again when the host
  re-renders with a new callback, new variables or changed files. A file that
  is not UTF-8 is shown read-only and never written over. A save that is
  partly refused names the parts saved and the parts refused; a part the user
  left alone is never written back over another session's change, an edited
  part wins with no check for one. Compiled only when
  `phoenix_live_view` is present; it is an optional dependency, and nothing
  depends on PhoenixKit.

### Fixed

- The editor no longer throws away what was typed into a part a save refused
  (one too large, a write error): the text stays in the form, still an edit to
  fix and save again. Before, the form was redrawn from disk, so the part came
  back as it was on disk.
- The editor cleans `locales` (anything but a list of non-empty strings, and
  duplicates) and `sample_variables` (anything but a map) the way it already
  cleaned `name_prefixes`, instead of crashing the page.
- Subject normalization no longer takes quadratic time on long whitespace runs
  without a line break. Unicode whitespace around a `\r`/`\n` is now collapsed
  along with the break, matching the documented single-space behavior.

### Documentation

- Corrected the Markdown substitution guidance: rendering a link target such as
  `{{url}}` can percent-encode its braces, so callers substituting after Markdown
  rendering must preserve and restore placeholders before HTML substitution.

## 0.2.2 - 2026-10-01

### Added

- **`markdown` and `layout` parts.** `render/4` now returns
  `%{subject:, text:, html:, markdown:, layout:}`. `markdown` (`markdown[.locale].md`)
  is returned exactly as read, with no placeholder substitution, so the caller
  can render Markdown before substituting. `layout` (`layout.txt`) names a
  layout group; it is locale-less, trimmed and unsubstituted.
  `missing_variables/4` reports a `markdown` part's unbound placeholders and
  never reports `layout`.
  ([#3](https://github.com/BeamLabEU/phoenix_kit_templates/pull/3))
- `PhoenixKit.Templates.sources/3` reports whether each part came from a host
  file (`{:file, path}`) or from the caller's defaults (`:default`), on the same
  resolution as `render/4`.
- `PhoenixKit.Templates.Overrides.locate/4` is `read/4` that also returns the
  file's path. `read/4` is built on it.

### Changed

- **`subject` is a single line.** It is returned trimmed, without a leading
  byte-order mark, and any line break inside it (with the whitespace around it)
  becomes one space — for files, defaults and substituted values alike. The
  final newline an editor adds to `subject.txt` is no longer part of the
  subject. `text`, `html` and `markdown` keep their line breaks.
- The `Overrides` cache key is tagged, so an entry cached by 0.2.1 is never read
  as a `{path, content}` pair after a live reload.

## 0.2.1 - 2026-10-01

### Added

- **A template name may start with one underscore** (`_layout`). Such names are
  reserved for shared parts that the caller assembles around a message; this
  package only finds the files, it wraps nothing. Names are now matched against
  `\A_?[a-z0-9][a-z0-9_\-]*\z`, so `__x`, `_`, `_-x` and anything containing
  `.` or `/` still resolve to no override and mint no cache entry. Ordinary
  names should not start with an underscore, but that is a convention the
  package does not enforce.
  ([#2](https://github.com/BeamLabEU/phoenix_kit_templates/pull/2))

### Changed

- The README and moduledocs no longer say core's auth emails are text-only. A
  template with no `html` is valid, and what a caller does without one is the
  caller's decision.

## 0.2.0 - 2026-09-23

### Breaking

- **`html` now HTML-escapes a bound `{{variable}}` value** (`&` `<` `>` `"`
  `'`, the set `Phoenix.HTML` escapes). A value carrying markup — a user or
  company name — no longer becomes live HTML in an email. `subject` and `text`
  are plain text and are still never escaped.

  **Upgrading:** a host override whose `html` part relies on a variable carrying
  markup on purpose (billing's `line_items_html`, a wrapped `content`) must
  switch that placeholder from `{{variable}}` to `{{{variable}}}`. A value that
  was being pre-escaped by the caller to compensate is now escaped twice — stop
  escaping it, or opt it out with triple braces.
- **`{{{variable}}}` is now parsed in every part.** In 0.1.x `{{{x}}}` rendered as
  `{V}` (literal outer braces around a substituted `{{x}}`); it now renders `V`.
  This applies to `subject` and `text` too, independent of escaping. Database
  templates in `phoenix_kit_emails` / `phoenix_kit_newsletters` still use their
  own `{{var}}`-only substitution, so a database row must not be written with
  triple braces.

### Added

- `{{{variable}}}` (triple braces) substitutes raw in every part — the opt-out
  for a variable that already holds rendered HTML.
  ([#1](https://github.com/BeamLabEU/phoenix_kit_templates/pull/1))
- `Substitution.substitute/3` with an `:escape` option. Unknown options and a
  non-boolean `:escape` raise `ArgumentError`, so a typo like `escaped: true`
  cannot silently render unescaped.
- `Substitution.variables/1`, `missing/2` and `Templates.missing_variables/4`
  report triple-brace placeholders like double-brace ones.

### Changed

- HTML escaping is a single pass over the value.

## 0.1.2 - 2026-09-16

### Fixed

- **Invalid input no longer creates cache entries.** `Overrides.read/4` checks
  the name, part and locale before it touches `:persistent_term`. A malformed
  locale now shares the `nil` locale's cache entry, and an invalid name or
  unknown part returns `nil` without caching anything. Before, each of these
  added a permanent key, and every new key copies the whole table.
- `Overrides.read/4` now raises on a bare string root instead of quietly finding
  no overrides. The old behaviour also cached a key that made a later
  `reset_cache/1` crash. `render/4` treats `paths: nil` as `[]`.
- The hexdocs source links now point at the `v<version>` tag instead of a ref
  that doesn't exist.
- The README and moduledoc example called `gettext("Hi %{email}, …")` without
  bindings, which raises. It now uses a `{{user_email}}` placeholder.

### Changed

- Locales can have up to three subtags and lose one at a time on fallback:
  `zh-Hant-TW` → `zh-Hant` → `zh` → locale-less. Before, any locale with more
  than one subtag skipped straight to the locale-less file.
- `render/4` and `missing_variables/4` now share one resolution function, so the
  check always sees the same content the render sends.

## 0.1.1 - 2026-09-06

### Documentation

- **Made the on-disk layout unmissable.** A template's `name` is a *directory*,
  not a filename — the one thing the 0.1.0 docs never actually stated, and the
  first thing anyone writing an override needs to know. Every doc now leads with
  it and carries a worked tree: `PhoenixKit.Templates` for the conceptual model
  and the full resolution order, `PhoenixKit.Templates.Overrides` for the lookup
  rules, and the README for practical use.
- Recorded why there is no `slug` and no `display_name`: `name` is validated as
  `[a-z0-9][a-z0-9_\-]*` precisely because it is a path segment, so it is
  slug-shaped by necessity and a second identifier would address nothing.
- Folded the duplicated part/extension listing into one table, keyed by which
  channel reads each part.

No code changes; `0.1.0` and `0.1.1` are functionally identical.

## 0.1.0 - 2026-09-06

Initial release.

- `PhoenixKit.Templates.render/4` resolves a named template per part — host
  override for the recipient's locale, then base language, then locale-less,
  then the caller's default — and substitutes `{{variables}}`. Parts resolve
  independently, so a host overriding only `html` keeps the package's
  translated `subject` and `text`.
- `PhoenixKit.Templates.missing_variables/4` reports unbound placeholders per
  part, for a test or a preview screen. `render/4` itself never raises over one:
  a message with a flawed line still beats a message that never arrives.
- `PhoenixKit.Templates.Overrides` reads host override files at runtime and
  caches them in `:persistent_term`, the absence of a file included. `name` and
  `locale` are validated before being joined onto a root.
- No runtime dependencies, deliberately: `phoenix_kit` depends on this package,
  so anything pulled in here lands upstream of the entire tree.
