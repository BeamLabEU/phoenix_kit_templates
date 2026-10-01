# phoenix_kit_templates

Locale-aware rendering for outbound message content — email, push, Telegram,
SMS, the in-app inbox. One renderer for every channel, so localized and
customizable copy is built the same way everywhere instead of once per channel.

```elixir
PhoenixKit.Templates.render(
  "new_login_alert",
  %{subject: gettext("New login to your account"), text: gettext("Hi {{user_email}}, …")},
  %{"user_email" => email, "ip_address" => ip},
  locale: "uk",
  paths: [Application.app_dir(:my_app, "priv/phoenix_kit_templates")]
)
#=> %{subject: "…", text: "…", html: nil, markdown: nil, layout: nil}
```

## Two layers

A template has a **default**, shipped by the package that sends the message,
and an optional **override**, shipped by the host application.

The caller passes the default in *already localized*. That split is the whole
design: translation belongs to the sending package's Gettext backend, and
reaching for one here would make this package depend on it. A shipped default
expressed as one file per locale would fork the same sentence seven ways and
drift; expressed as a Gettext call it rides the extraction and translation
pipeline that package already runs.

Files are how a **host** overrides — a host writes one or two languages, not
seven — and how chrome-bearing HTML gets authored.

Resolution runs per part, independently:

```
1. host override · recipient locale     text.en-GB.txt
2. host override · base language        text.en.txt
3. host override · locale-less          text.txt
4. the default the caller passed in
```

Independence matters: a host that overrides only `html` keeps the package's
translated `subject` and `text` rather than having to restate them.

## Override layout

**The template's name is a directory, not a filename.** Files inside it are
named for the part they supply, optionally carrying a locale:

```
priv/phoenix_kit_templates/     <- a root, passed as :paths
└── new_login_alert/            <- the template NAME (a directory)
    ├── subject.txt             <- <part>.<ext>
    ├── subject.de.txt          <- <part>.<locale>.<ext>
    ├── text.txt
    ├── text.de.txt
    ├── html.html
    ├── markdown.md
    └── layout.txt
```

Parts are named for what they are rather than for email, because every channel
reads the same set:

| part | file | read by |
|---|---|---|
| `subject` | `subject[.locale].txt` | email subject line, push title |
| `text` | `text[.locale].txt` | email body, push body, Telegram, SMS, in-app inbox |
| `html` | `html[.locale].html` | email only — optional |
| `markdown` | `markdown[.locale].md` | email only — optional, an alternative to `html` |
| `layout` | `layout.txt` | email only — optional, names a layout group |

`render/4` returns all five keys: `%{subject:, text:, html:, markdown:, layout:}`.
A part with neither an override nor a default is `nil`.

Given that tree, a German recipient resolves to `subject.de.txt` + `text.de.txt`;
an Italian one falls through to `subject.txt` + `text.txt`. A host that wrote
only `text.txt` still gets the package's translated subject in every language —
parts are looked up independently.

A directory rather than flat files because one template is up to five parts
times however many locales a host translates. Flat, they would interleave with
every other template's files and you would be reading filename prefixes to tell
them apart; grouped, a template is one folder to copy, diff or delete.

`html` is genuinely optional, not nominally so: a template with only `subject`
and `text` is valid. What a caller does when there is no `html` — send plain
text, derive an HTML body, wrap it in a layout — is the caller's decision, not
this package's.

Overrides live in the host application, which compiles separately from this
package — so they are read at runtime and cached in `:persistent_term`, the
absence of a file included.

### `markdown` and `layout` are found, not interpreted

This package renders no Markdown and selects no layout; it only finds the files.
They differ from the other parts in what `render/4` does with them:

- `markdown` is returned **exactly as read** (or as passed in `defaults`), with
  **no placeholder substitution**. A Markdown renderer percent-encodes
  `{{url}}` inside a link target (`%7B%7Burl%7D%7D`), so the caller renders the
  Markdown first and substitutes afterwards. `missing_variables/4` still
  reports the placeholders of a `markdown` part that the variables do not bind
  — those the caller is going to substitute.
- `layout` holds the *name* of a layout group (e.g. `billing`) and is
  **locale-less**: the group is chosen per message, not per language, so only
  `layout.txt` is read and a `layout.<locale>.txt` is ignored. It is returned
  trimmed (also of a leading byte-order mark), without substitution, and
  `missing_variables/4` never reports it.

### Where a part came from

For a preview screen, `PhoenixKit.Templates.sources/3` reports the origin of
each part on the same resolution `render/4` uses, so it cannot disagree with
what would be sent:

```elixir
PhoenixKit.Templates.sources("register", defaults, locale: "ru", paths: paths)
#=> %{subject: :default, text: {:file, "/app/priv/phoenix_kit_templates/register/text.txt"}}
```

`{:file, path}` means a host file was found (an empty file counts), `:default`
means the caller's non-`nil` default was used, and a missing key means the part
does not exist. `Overrides.locate/4` is the lower-level form: like `read/4`,
but it returns `{path, content}` (or `nil`) — `read/4` is built on it.

### `subject` is a single line

`render/4` returns `subject` trimmed on both sides (and without a leading
byte-order mark) — the final newline an editor adds to `subject.txt` is not
part of the subject — and replaces any interior `\r`/`\n` (a wrapped file, or
a substituted value), with the whitespace around it, with a single space. This holds for files and `defaults`
alike; `text`, `html` and `markdown` keep their line breaks.

### Reserved names: a leading underscore

A name may start with a single underscore (`_layout`, not `__layout`). Names
like that are reserved for shared parts that the caller assembles around a
message; the first is core's email layout, `_layout`. This package knows
nothing about layouts and wraps nothing — it only finds
`priv/phoenix_kit_templates/_layout/html.html` (or `html.<locale>.html`) the
same way it finds any other name. By convention, ordinary template names
should not start with an underscore, so the two do not collide; the package
does not enforce that.

### The name is the slug

There is no separate slug, and no `display_name`. `name` is validated as
`[a-z0-9][a-z0-9_\-]*` (with one optional leading underscore, see above) —
slug-shaped by construction, because it is a directory name on disk and has to
be safe to join onto a path.

The database schema this replaces carried both, for a reason that no longer
exists: `name` identified the template while `slug` addressed the admin
editor's routes (`…/templates/:slug`), and `display_name` labelled its list
view. With no editor and no routes, a second identifier addresses nothing. A
human-readable label, if one is ever wanted, is a Gettext call in the sending
package rather than a stored column — the same place its subject and body
already live.

## Placeholders

`{{variable}}`, with optional inner whitespace, matching the syntax the
database-backed email templates used so exported content carries over
unchanged — as long as it contains no triple brace. `{{{variable}}}` is new in
0.2.0: writing it into a database row does nothing useful, because
`phoenix_kit_emails`/`phoenix_kit_newsletters` substitute with their own,
older `{{var}}`-only regex, which has no triple-brace rule and renders the
outer pair as literal text instead (see `PhoenixKit.Templates.Substitution`
for exactly what that looks like). Exporting a database template that carries
pre-rendered HTML — `line_items_html`, a wrapped `content` — into this
package's file layout must translate that placeholder from `{{var}}` to
`{{{var}}}` at export time; the reverse direction must not happen.
Atom and string keys are both accepted.

An **unbound placeholder is left verbatim**, not blanked, and never raises. Both
are wrong, but a visible `{{user_emial}}` announces the typo in a preview or a
test, while a silent empty string reads as finished copy and ships — and a
message with one flawed line still beats a message that never arrives. Callers
that want it to be an error ask `missing_variables/4` up front.

### HTML escaping, and the `{{{raw}}}` opt-out

`html` HTML-escapes a bound `{{variable}}` value (`&` `<` `>` `"` `'`) —
`subject` and `text` never do, being plain text. A value is always treated as
data, not as markup to preserve, so a value that already contains `&amp;` is
escaped again.

`{{{variable}}}` (triple braces) substitutes **raw** in `subject`, `text` and
`html`, regardless of escaping — the opt-out for a variable that already holds
rendered HTML, such as a pre-built line-items table:

```elixir
PhoenixKit.Templates.render(
  "billing_invoice",
  %{html: "<table>{{{line_items_html}}}</table>"},
  %{"line_items_html" => render_line_items(invoice)}
)
```

In `subject` and `text`, `{{{variable}}}` and `{{variable}}` are identical —
both are raw — so the same template content is valid pasted into any of the
three substituted parts (`subject`, `text`, `html`). `markdown` and `layout`
are returned without substitution — see above.

> #### Escaping `html` is a breaking change from 0.1.x {: .warning}
>
> Before 0.2.0, `html` substituted every `{{variable}}` raw, exactly like
> `subject` and `text` still do. If a host override's `html` part relies on a
> variable carrying markup on purpose, switch that placeholder to
> `{{{variable}}}` when upgrading. See the CHANGELOG for the full upgrade
> note.

See `PhoenixKit.Templates.Substitution` for the parsing rules and a table of
boundary cases (adjacent braces, stray single braces, CSS inside `html`, and
so on).

## No runtime dependencies

Deliberate: `phoenix_kit` depends on this package, so anything pulled in here
lands upstream of the entire tree.

## License

MIT
