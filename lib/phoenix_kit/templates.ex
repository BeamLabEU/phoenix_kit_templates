defmodule PhoenixKit.Templates do
  @moduledoc """
  Renders a named message template for a recipient.

  One renderer for every channel — email, push, Telegram, SMS, the in-app inbox
  — so localized, customizable message content is built the same way everywhere
  instead of once per channel.

  ## The two layers

  A template has a **default**, shipped by the package that sends the message,
  and an optional **override**, shipped by the host application.

  The caller supplies the default already localized. That split is what keeps
  this package a leaf: translation belongs to the sending package's Gettext
  backend, and reaching for one here would mean depending on it.

      PhoenixKit.Templates.render(
        "new_login_alert",
        %{subject: gettext("New login to your account"), text: gettext("Hi {{user_email}}, …")},
        %{"user_email" => email, "ip_address" => ip},
        locale: "uk",
        paths: [Application.app_dir(:my_app, "priv/phoenix_kit_templates")]
      )

  ## On disk

  **A template's name is a DIRECTORY, never a filename.** The files inside it
  are named for the *part* they supply, optionally carrying a locale:

      priv/phoenix_kit_templates/     <- a root, passed as :paths
      └── new_login_alert/            <- the template NAME (a directory)
          ├── subject.txt             <- <part>.<ext>
          ├── subject.de.txt          <- <part>.<locale>.<ext>
          ├── text.txt
          ├── text.de.txt
          ├── html.html
          ├── markdown.md
          └── layout.txt

  | part | file | used by |
  |---|---|---|
  | `subject` | `subject[.locale].txt` | email subject, push title |
  | `text` | `text[.locale].txt` | every channel |
  | `html` | `html[.locale].html` | email only, optional |
  | `markdown` | `markdown[.locale].md` | email only, optional — an alternative to `html` |
  | `layout` | `layout.txt` | email only, optional — names a layout group |

  A directory rather than flat files because one template is up to five parts
  times however many locales a host translates — flat, they would interleave
  with every other template's files and you would be reading filename prefixes
  to tell them apart. Grouped, a template is one folder to copy, diff or delete.

  This is also why `name` is the only identifier and is validated as
  `[a-z0-9][a-z0-9_\-]*` with one optional leading underscore (see "Reserved
  names" in `PhoenixKit.Templates.Overrides`): it is a path segment, so it must
  be filesystem-safe. It is slug-shaped by necessity, which is what makes a
  separate slug field a second spelling of a constraint the path already
  enforces.

  ## Resolution

  Per part, independently, stopping at the first hit. For part `subject` and a
  recipient locale of `"de-AT"`:

      1. subject.de-AT.txt      host override · exact dialect
      2. subject.de.txt         host override · base language
      3. subject.txt            host override · locale-less
      4. defaults[:subject]     the caller's Gettext default

  Roots are tried in order, so an earlier root shadows a later one.

  Independence matters. Given the tree above and a German recipient, a host that
  wrote only `text.txt` still gets the package's translated German subject; the
  override applies to the body alone. And `subject.de.txt` wins for a German
  reader while an Italian one falls through to `subject.txt`.

  ## Why the default is not a file

  A shipped default expressed as one file per locale forks the same sentence
  seven ways and drifts. Expressed as a Gettext call it rides the extraction and
  translation pipeline the sending package already runs, and ships translated.
  Files are how a *host* overrides — a host writes one or two languages, not
  seven — and how chrome-bearing HTML gets authored. See the design doc.

  ## Parts

  `subject`, `text`, `html`, `markdown` and `layout`, named for what they are
  rather than for email: push uses subject-as-title plus text, Telegram and
  SMS use text alone, the in-app inbox uses text. `html` is genuinely
  optional — a template with no `html` is valid, and what a caller does
  without one is the caller's decision.

  `html` HTML-escapes a bound `{{variable}}` value; `subject` and `text`,
  being plain text, never do. `{{{variable}}}` (triple braces) is the
  escaping opt-out, substituting raw — see `render/4` and
  `PhoenixKit.Templates.Substitution` for the full syntax. Substitution
  (double and triple braces) happens in `subject`, `text` and `html` only;
  `markdown` and `layout` come back without it.

  ### `markdown` and `layout`: found, not interpreted

  This package only *finds* these two parts; it renders no Markdown and
  selects no layout. `render/4` treats them differently from the other three:

    * `markdown` is returned **exactly** as `PhoenixKit.Templates.Overrides.read/4` (or `defaults`)
      supplied it — **no placeholder substitution**. Placeholders such as
      `[Confirm]({{confirmation_url}})` are still in the string. The caller
      owns the rendering and substitution pipeline. If it substitutes after
      rendering, it must preserve placeholders through that step: a Markdown
      renderer may percent-encode `{{url}}` inside a link target as
      `%7B%7Burl%7D%7D`, which `Substitution.substitute/3` will not recognize.
      For example, the caller can protect placeholders with renderer-safe
      tokens and restore them before HTML-escaped substitution.
      `missing_variables/4` still reports a `markdown` part's unbound
      placeholders — the ones the caller will substitute.
    * `layout` is a one-line file whose content names a layout group
      (`billing`). It is **locale-less** — the group is chosen per message,
      not per language — so only `layout.txt` is read and a
      `layout.<locale>.txt` is ignored. It is returned trimmed (and without a
      leading byte-order mark), without substitution, and `missing_variables/4`
      never reports it.

  ### Where a part came from

  `sources/3` answers "which file, if any, supplied each part?" with
  `{:file, path}` / `:default`, on the same resolution as `render/4`. It exists
  for preview screens. `PhoenixKit.Templates.Overrides.locate/4` is the
  lower-level form that also returns the file's content.

  ### `subject` is one line

  A subject becomes a single header line, so `render/4` returns it trimmed on
  both sides, without a leading byte-order mark — the newline most editors
  append to a file is not part of the subject — and any `\\r`/`\\n` inside it
  (a wrapped file, or a variable value), with the whitespace around it,
  becomes a single space. This applies
  to files and `defaults` alike; `text`, `html` and `markdown` keep their line
  breaks.
  """

  alias PhoenixKit.Templates.Overrides
  alias PhoenixKit.Templates.Substitution

  @typedoc "Resolved parts; Markdown rendering and layout selection belong to the caller."
  @type rendered :: %{
          subject: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          markdown: String.t() | nil,
          layout: String.t() | nil
        }

  @typedoc "Package-shipped content, already localized by the caller."
  @type defaults :: %{optional(Overrides.part()) => String.t() | nil}

  @doc """
  Renders `name` into `%{subject:, text:, html:, markdown:, layout:}`.

  The map always carries all five keys; a part with neither override nor
  default is `nil`. Only `subject`, `text` and `html` are substituted;
  `markdown` and `layout` are not — see
  "`markdown` and `layout`: found, not interpreted" in the module docs.

  ## Options

    * `:locale` — the recipient's locale, dialect included (`"en-GB"`). `nil`
      selects only locale-less overrides.
    * `:paths` — host override roots, tried in order. Defaults to `[]`, which
      means the caller's defaults are used verbatim.

  Unbound `{{placeholders}}` survive into the output rather than blanking or
  raising; see `PhoenixKit.Templates.Substitution`.

  ## Escaping

  The `html` part HTML-escapes a bound `{{variable}}` value (`&` `<` `>` `"`
  `'`); `subject` and `text` never do, being plain text. In all three,
  `{{{variable}}}` (triple braces) substitutes raw — the opt-out for a
  variable that already holds rendered HTML, such as a pre-built line-items
  table. See `PhoenixKit.Templates.Substitution` for the full syntax and its
  boundary cases.

  > #### Escaping `html` is a breaking change from 0.1.x {: .warning}
  >
  > Before 0.2.0, `html` substituted every `{{variable}}` raw, like `subject`
  > and `text` still do. A host override whose `html` part relies on a
  > variable carrying markup on purpose must switch that placeholder to
  > `{{{variable}}}` when upgrading — see the CHANGELOG.
  """
  @spec render(String.t(), defaults(), Substitution.variables(), keyword()) :: rendered()
  def render(name, defaults, variables \\ %{}, opts \\ []) when is_binary(name) do
    Map.new(Overrides.parts(), fn part ->
      {part, name |> resolve(part, defaults, opts) |> finish(part, variables)}
    end)
  end

  # Per-part post-processing of the resolved content. `markdown` is handed back
  # untouched: the caller owns the Markdown rendering/substitution pipeline,
  # including preserving placeholders through the Markdown renderer.
  defp finish(content, :markdown, _variables), do: content
  defp finish(content, :layout, _variables) when is_binary(content), do: trim_bom(content)
  defp finish(content, :layout, _variables), do: content

  defp finish(content, :subject, variables) do
    content |> Substitution.substitute(variables, escape: false) |> single_line()
  end

  defp finish(content, part, variables) do
    Substitution.substitute(content, variables, escape: part == :html)
  end

  # A subject is one header line: drop a BOM and surrounding whitespace (the
  # file's final newline) and turn any interior line break, with the whitespace
  # around it (a wrapped file's indentation), into one space.
  defp single_line(nil), do: nil

  defp single_line(subject) do
    subject = trim_bom(subject)

    # Scan each run once. A greedy whitespace prefix followed by a required
    # newline retries at every space if no newline exists, taking quadratic time.
    Regex.replace(~r/\s+/u, subject, fn whitespace ->
      if String.contains?(whitespace, ["\r", "\n"]), do: " ", else: whitespace
    end)
  end

  # An editor on some platforms prepends a BOM; it is not whitespace to
  # `String.trim/1`, so it would otherwise survive as an invisible character.
  defp trim_bom(content), do: content |> String.trim_leading("\u{FEFF}") |> String.trim()

  @doc """
  Where each part of `name` would come from, for a preview screen.

  Returns `%{part => {:file, path} | :default}`:

    * `{:file, path}` — a host override file was found, `path` being the file
      read. An empty file counts: whether empty means absent is the caller's
      decision.
    * `:default` — no file, and `defaults` carries a non-`nil` value for it.
    * no key — neither exists; `render/4` yields `nil` for that part.

  Built on the same resolution as `render/4` and `missing_variables/4`, so the
  reported source cannot differ from the content that would be sent. Takes the
  same `:locale` and `:paths` options.
  """
  @spec sources(String.t(), defaults(), keyword()) ::
          %{optional(Overrides.part()) => {:file, Path.t()} | :default}
  def sources(name, defaults, opts \\ []) when is_binary(name) do
    Enum.reduce(Overrides.parts(), %{}, fn part, acc ->
      case {locate(name, part, opts), Map.get(defaults, part)} do
        {{path, _content}, _default} -> Map.put(acc, part, {:file, path})
        {nil, nil} -> acc
        {nil, _default} -> Map.put(acc, part, :default)
      end
    end)
  end

  @doc """
  Placeholder names that the given variables leave unbound, keyed by part.

  For `subject`, `text` and `html` these are exactly the placeholders `render/4`
  would leave verbatim. `markdown` is not substituted by `render/4`, so there
  the names are the placeholders its source contains that the variables do not
  bind — what the caller would leave unbound when it substitutes after
  rendering the Markdown. `layout` is a group name, not a message part with
  placeholders, and is never reported.

  Parts with nothing unbound are omitted, so an empty map means everything is
  bound. Intended for a test or a preview screen — `render/4` itself
  never fails over a bad placeholder, because a message with one flawed line is
  still better than a message that never arrives.
  """
  @spec missing_variables(String.t(), defaults(), Substitution.variables(), keyword()) ::
          %{optional(Overrides.part()) => [String.t()]}
  def missing_variables(name, defaults, variables \\ %{}, opts \\ []) when is_binary(name) do
    Enum.reduce(Overrides.parts() -- [:layout], %{}, fn part, acc ->
      case name |> resolve(part, defaults, opts) |> Substitution.missing(variables) do
        [] -> acc
        names -> Map.put(acc, part, names)
      end
    end)
  end

  # The one resolution both functions share, so the check can never inspect
  # different content from what the render would send.
  defp resolve(name, part, defaults, opts) do
    case locate(name, part, opts) do
      {_path, content} -> content
      nil -> Map.get(defaults, part)
    end
  end

  defp locate(name, part, opts) do
    Overrides.locate(opts[:paths] || [], name, part, opts[:locale])
  end
end
