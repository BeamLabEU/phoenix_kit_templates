defmodule PhoenixKit.Templates.Overrides do
  @moduledoc """
  Locates a host application's override file for one part of one template.

  A host customizes a message by dropping a file into its own repo, where it is
  version-controlled and reviewable, instead of editing a database row through
  an admin UI. Nothing here writes; an override is only ever read.

  ## Layout

  **`name` is a DIRECTORY, never a filename.** Files inside it are named for the
  part they supply, optionally carrying a locale:

      <root>/<name>/<part>.<locale>.<ext>       text.en-GB.txt
      <root>/<name>/<part>.<ext>                text.txt

  Worked:

      priv/phoenix_kit_templates/     <- <root>
      └── new_login_alert/            <- <name>
          ├── subject.txt
          ├── subject.de.txt
          └── text.txt

  `subject`, `text` and `layout` are `.txt`; `html` is `.html`; `markdown` is
  `.md`. A root is typically `Application.app_dir(:my_app,
  "priv/phoenix_kit_templates")`, but this module
  takes roots as an argument and reads no configuration of its own — it must
  not know which application is using it.

  `layout` is the one part with no locale: it names a layout group, which is
  chosen per message rather than per language, so only `layout.txt` is ever
  read and `layout.<locale>.txt` is ignored.

  Lookup runs most- to least-specific and stops at the first file that exists:

      text.en-GB.txt   →   text.en.txt   →   text.txt

  so a host that only cares about one language writes `text.txt` and is done,
  while one that translates its overrides gets dialect precision. Roots are
  tried in order, so an earlier root shadows a later one.

  Each part is looked up separately: in the tree above, a German reader gets
  `subject.de.txt` and `text.txt`, and an Italian reader gets `subject.txt` and
  `text.txt`. A part with no file at all resolves to `nil`, and the caller falls
  back to its own default.

  `locate/4` is `read/4` that also returns the path of the file it read —
  `{path, content}` — for callers that need to say where content came from.
  `read/4` is built on it, so the two always agree.

  ## Reserved names

  A name may start with **one** underscore (`_layout`). Such names are
  reserved for shared parts that the *caller* assembles around a message — the
  first is core's email layout, `_layout`. This package knows nothing about
  layouts and wraps nothing: it finds `_layout/html.html` (and
  `html.<locale>.html`) exactly as it finds any other name. The underscore is
  meant to keep such a directory from colliding with a template name: by
  convention ordinary names should not start with one, but this module does not
  enforce that.

  ## Runtime, not compile time

  Overrides live in the *host* application, which is compiled separately from
  this package — there is no point in this package's compilation at which they
  could be read. So they are read at runtime and cached in `:persistent_term`,
  including the *absence* of a file, since a missing override is the common case
  and would otherwise cost a `File.stat` on every send. Files cannot change
  without a deploy; `reset_cache/0` exists for tests and dev reloads.

  ## Path safety

  `name` and `locale` are matched against strict patterns before they are ever
  joined onto a root. A name is `[a-z0-9][a-z0-9_\-]*` with an optional single
  leading underscore; dots and slashes never match. They are literals at every
  current call site, but this module turns a name into a filesystem read, and
  that is not a boundary to leave to the caller's good behaviour —
  `../../../etc/passwd` resolves to no override rather than to a file.
  """

  @parts %{subject: "txt", text: "txt", html: "html", markdown: "md", layout: "txt"}

  @name_pattern ~r/\A_?[a-z0-9][a-z0-9_\-]*\z/
  @locale_pattern ~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}\z/

  @typedoc "Which part of a template to look for."
  @type part :: :subject | :text | :html | :markdown | :layout

  @doc "The parts an override file can supply."
  @spec parts() :: [part()]
  def parts, do: Map.keys(@parts)

  @doc """
  The contents of the best-matching override file, or `nil` when there is none.

  `locale` may be `nil`, which skips straight to the locale-less candidate, as
  does a locale that is not a well-formed tag. `roots` must be a list — a bare
  string is a caller bug, and silently finding no overrides in it would hide
  that.
  """
  @spec read([Path.t()], String.t(), part(), String.t() | nil) :: String.t() | nil
  def read(roots, name, part, locale) when is_list(roots) do
    case locate(roots, name, part, locale) do
      {_path, content} -> content
      nil -> nil
    end
  end

  @doc """
  Like `read/4`, but also says *which file* the content came from:
  `{path, content}`, or `nil` when there is no override.

  Validation, candidate order (locale → base language → locale-less, roots in
  order) and the cache are exactly `read/4`'s — `read/4` is implemented on top
  of this function, so the two can never disagree about which file wins. The
  path is the one that was read (a root joined with the name and file), as a
  preview screen would show it. An empty file is still found: whether empty
  means absent is the caller's decision.
  """
  @spec locate([Path.t()], String.t(), part(), String.t() | nil) ::
          {Path.t(), String.t()} | nil
  def locate(roots, name, part, locale) when is_list(roots) do
    if valid_request?(name, part) do
      cached_lookup(roots, name, part, normalize_locale(part, locale))
    end
  end

  @doc """
  Drops cached override lookups.

  Only tests and dev reloads need this: a deploy starts a fresh VM.

  Pass a list of roots to clear only the entries that consulted them. That
  scoping is what lets an async test clear its own `tmp_dir` without erasing a
  concurrently-running one's cache — and it is the honest shape anyway, since a
  dev reload usually means one application's files changed, not all of them.
  """
  @spec reset_cache([Path.t()] | :all) :: :ok
  def reset_cache(roots \\ :all) do
    for {{__MODULE__, :located, cached_roots, _name, _part, _locale} = key, _value} <-
          :persistent_term.get(),
        roots == :all or Enum.any?(cached_roots, &(&1 in roots)) do
      :persistent_term.erase(key)
    end

    :ok
  end

  # Validated before the cache is consulted, not after: every distinct key is a
  # permanent `:persistent_term` entry, and each new one copies the whole table.
  # A junk name or locale must not be able to mint entries of its own.
  defp valid_request?(name, part) do
    is_binary(name) and Map.has_key?(@parts, part) and Regex.match?(@name_pattern, name)
  end

  # `layout` is locale-less, so it normalizes to `nil` like an unparseable one.
  # An unparseable locale contributes no candidates of its own rather than being
  # interpolated into a path, so it resolves exactly as `nil` does — and shares
  # `nil`'s cache entry.
  defp normalize_locale(:layout, _locale), do: nil

  defp normalize_locale(_part, locale) when is_binary(locale) do
    if Regex.match?(@locale_pattern, locale), do: locale
  end

  defp normalize_locale(_part, _locale), do: nil

  defp cached_lookup(roots, name, part, locale) do
    # The tag keeps a cache entry written by 0.2.1 (a bare binary under the
    # untagged key) from being misread as a `{path, content}` pair after a
    # live code reload.
    key = {__MODULE__, :located, roots, name, part, locale}

    case :persistent_term.get(key, :miss) do
      :miss ->
        found = lookup(roots, name, part, locale)
        :persistent_term.put(key, found)
        found

      cached ->
        cached
    end
  end

  defp lookup(roots, name, part, locale) do
    roots
    |> Enum.flat_map(&candidates(&1, name, part, locale))
    |> Enum.find_value(&read_file/1)
  end

  defp candidates(root, name, part, locale) do
    extension = Map.fetch!(@parts, part)

    locale
    |> locale_suffixes()
    |> Enum.map(fn
      nil -> Path.join([root, name, "#{part}.#{extension}"])
      suffix -> Path.join([root, name, "#{part}.#{suffix}.#{extension}"])
    end)
  end

  # Most- to least-specific, dropping one subtag at a time: "zh-Hant-TW" tries
  # "zh-Hant-TW", "zh-Hant", "zh", then the locale-less file.
  defp locale_suffixes(nil), do: [nil]

  defp locale_suffixes(locale) do
    subtags = String.split(locale, "-")

    length(subtags)..1//-1
    |> Enum.map(&(subtags |> Enum.take(&1) |> Enum.join("-")))
    |> Kernel.++([nil])
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {path, content}
      {:error, _reason} -> nil
    end
  end
end
