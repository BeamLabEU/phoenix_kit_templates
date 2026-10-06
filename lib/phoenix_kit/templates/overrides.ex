defmodule PhoenixKit.Templates.Overrides do
  @moduledoc """
  Locates a host application's override file for one part of one template.

  A host customizes a message by dropping a file into its own repo, where it is
  version-controlled and reviewable, instead of editing a database row through
  an admin UI. Rendering only ever reads an override; `write/5`, `delete/4`,
  `delete_template/2` and `list/1` exist for a host that edits its own files
  from a screen of its own — see "Writing" below.

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
  without a deploy; `reset_cache/0` exists for tests and dev reloads — and the
  write functions below call it for their own root.

  ## Path safety

  `name` and `locale` are matched against strict patterns before they are ever
  joined onto a root. A name is `[a-z0-9][a-z0-9_\-]*` with an optional single
  leading underscore; dots and slashes never match. They are literals at every
  current call site, but this module turns a name into a filesystem read, and
  that is not a boundary to leave to the caller's good behaviour —
  `../../../etc/passwd` resolves to no override rather than to a file.

  ## Writing

  `write/5`, `delete/4`, `delete_template/2` and `list/1` work on **one** root —
  the host's own directory, never a package's — and on the same layout. They are
  plain `File` calls for a host-side editor; rendering does not use them.

    * **Same validation as reading, but refusing instead of falling back.** The
      name must match the pattern above; a locale must be `nil` or a
      well-formed tag (reading treats a junk locale as `nil`, which for a write
      would silently target the locale-less file); `layout` takes no locale.
    * **One more part, `label`** (`label[.locale].txt`): a human-readable
      caption for an editor's list. Rendering never reads it and `parts/0`
      does not include it.
    * **The path stays inside the root**, symlinks included
      (`Path.safe_relative/2`), and the root must already exist.
    * **Atomic:** the content goes to a temporary file in the same directory,
      is synced, and is renamed over the target, so a concurrent read sees the
      old file or the new one, never half of one. A replaced file keeps its
      permission bits.
    * **At most `max_bytes/0`** (256 KiB) of UTF-8 per file.
    * **The cache is reset for the root** (`reset_cache([root])`) after every
      change, so the next render sees it. Pass the same root string the
      renderer gets in `:paths` — the cache is keyed on it.

  Every refusal is an `{:error, reason}`; nothing raises on bad input.
  `write/5` returns the paths it created — the template directory first, when
  the write is its first part file, then the file — so a host can, for example,
  fix their ownership.
  """

  @parts %{subject: "txt", text: "txt", html: "html", markdown: "md", layout: "txt"}
  # `label` is written and listed, never rendered: an editor's caption.
  @writable_parts Map.put(@parts, :label, "txt")
  @max_bytes 256 * 1024

  @name_pattern ~r/\A_?[a-z0-9][a-z0-9_\-]*\z/
  @locale_pattern ~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}\z/

  @typedoc "Which part of a template to look for."
  @type part :: :subject | :text | :html | :markdown | :layout

  @typedoc "A part `write/5` accepts: every rendered part, plus `label`."
  @type writable_part :: part() | :label

  @typedoc "Why a write, delete or listing refused or failed."
  @type error ::
          :invalid_root
          | :invalid_name
          | :invalid_part
          | :invalid_locale
          | :invalid_content
          | :too_large
          | :unsafe_path
          | File.posix()

  @typedoc "One part file found by `list/1`."
  @type file_entry :: %{
          part: writable_part(),
          locale: String.t() | nil,
          path: Path.t(),
          mtime: DateTime.t()
        }

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

  @doc """
  Whether `name` is a valid template name — the pattern `read/4` and `write/5`
  both apply — for a caller that wants to check a name before writing to it.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: check_name(name) == :ok

  @doc "The largest file, in bytes, that `write/5` accepts."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Writes `content` as `<root>/<name>/<part>[.<locale>].<ext>`, replacing any
  file already there, and resets the cache for `root`.

  `part` is any rendered part or `:label`; `locale` is `nil` for the
  locale-less file. Returns `{:ok, paths}` — the template directory when this
  is its first part file (a directory this call created, or one that held no
  part file yet), then the file — or `{:error, reason}`; see "Writing" in the
  module docs for what is refused.
  """
  @spec write(Path.t(), String.t(), writable_part(), String.t() | nil, String.t()) ::
          {:ok, [Path.t()]} | {:error, error()}
  def write(root, name, part, locale, content) do
    with {:ok, dir, path} <- target(root, name, part, locale),
         :ok <- check_content(content),
         first_part? = list_files(root, name) == [],
         :ok <- File.mkdir_p(dir),
         :ok <- write_atomically(path, content) do
      reset_cache([root])
      {:ok, if(first_part?, do: [dir, path], else: [path])}
    end
  end

  @doc """
  Deletes one part file — exactly the one `write/5` would write for the same
  arguments, with no locale fallback — and resets the cache for `root`.

  A missing file is `{:error, :enoent}`.
  """
  @spec delete(Path.t(), String.t(), writable_part(), String.t() | nil) ::
          :ok | {:error, error()}
  def delete(root, name, part, locale) do
    with {:ok, _dir, path} <- target(root, name, part, locale),
         :ok <- File.rm(path) do
      reset_cache([root])
    end
  end

  @doc """
  Deletes the template directory `<root>/<name>` with everything in it, and
  resets the cache for `root`.

  A missing directory is `{:error, :enoent}`.
  """
  @spec delete_template(Path.t(), String.t()) :: :ok | {:error, error()}
  def delete_template(root, name) do
    with :ok <- check_root(root),
         :ok <- check_name(name),
         :ok <- check_inside(root, name),
         dir = Path.join(root, name),
         true <- File.dir?(dir) || {:error, :enoent} do
      remove_tree(root, dir)
    end
  end

  defp remove_tree(root, dir) do
    result = File.rm_rf(dir)
    # Reset even when the removal failed part-way: some files are gone already.
    reset_cache([root])

    case result do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @doc """
  The templates under `root`, sorted by name: `[%{name:, files: [file_entry]}]`.

  Lists every directory whose name passes the name pattern — an empty one
  included — and, inside it, every file that `write/5` could have written
  (`label` included), sorted by part and locale. Anything else (a temporary
  file, `layout.<locale>.txt`, a symlink out of the root, a stray file) is
  skipped. A root that does not exist, or is not a string, lists nothing.
  """
  @spec list(Path.t()) :: [%{name: String.t(), files: [file_entry()]}]
  def list(root) when is_binary(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&template_dir?(root, &1))
        |> Enum.sort()
        |> Enum.map(&%{name: &1, files: list_files(root, &1)})

      {:error, _reason} ->
        []
    end
  end

  def list(_root), do: []

  defp template_dir?(root, name) do
    check_name(name) == :ok and check_inside(root, name) == :ok and
      File.dir?(Path.join(root, name))
  end

  defp list_files(root, name) do
    dir = Path.join(root, name)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(&file_entry(root, name, &1))
        |> Enum.sort_by(&{&1.part, &1.locale})

      {:error, _reason} ->
        []
    end
  end

  defp file_entry(root, name, file) do
    path = Path.join([root, name, file])

    with {:ok, part, locale} <- parse_file_name(file),
         :ok <- check_inside(root, Path.join(name, file)),
         {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.stat(path, time: :posix) do
      [%{part: part, locale: locale, path: path, mtime: DateTime.from_unix!(mtime)}]
    else
      _not_a_part_file -> []
    end
  end

  defp parse_file_name(file) do
    case String.split(file, ".") do
      [part, ext] -> parse_file_name(part, nil, ext)
      [part, locale, ext] -> parse_file_name(part, locale, ext)
      _other -> :error
    end
  end

  defp parse_file_name(part_name, locale, ext) do
    with {part, ^ext} <-
           Enum.find(@writable_parts, :error, fn {part, _ext} ->
             Atom.to_string(part) == part_name
           end),
         {:ok, locale} <- check_locale(part, locale) do
      {:ok, part, locale}
    else
      _invalid -> :error
    end
  end

  # Every check a write or delete makes before it touches the filesystem, in
  # the order a caller is most likely to have got wrong.
  defp target(root, name, part, locale) do
    with :ok <- check_root(root),
         :ok <- check_name(name),
         {:ok, ext} <- check_part(part),
         {:ok, locale} <- check_locale(part, locale),
         file = file_name(part, locale, ext),
         :ok <- check_inside(root, Path.join(name, file)) do
      {:ok, Path.join(root, name), Path.join([root, name, file])}
    end
  end

  defp check_root(root) when is_binary(root) do
    if File.dir?(root), do: :ok, else: {:error, :invalid_root}
  end

  defp check_root(_root), do: {:error, :invalid_root}

  defp check_name(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name), do: :ok, else: {:error, :invalid_name}
  end

  defp check_name(_name), do: {:error, :invalid_name}

  defp check_part(part) do
    case Map.fetch(@writable_parts, part) do
      {:ok, ext} -> {:ok, ext}
      :error -> {:error, :invalid_part}
    end
  end

  defp check_locale(_part, nil), do: {:ok, nil}
  defp check_locale(:layout, _locale), do: {:error, :invalid_locale}

  defp check_locale(_part, locale) when is_binary(locale) do
    if Regex.match?(@locale_pattern, locale), do: {:ok, locale}, else: {:error, :invalid_locale}
  end

  defp check_locale(_part, _locale), do: {:error, :invalid_locale}

  # The name and locale patterns already rule out `..` and `/`; this also
  # catches a symlink inside the root that points out of it.
  defp check_inside(root, relative) do
    case Path.safe_relative(relative, root) do
      {:ok, _path} -> :ok
      :error -> {:error, :unsafe_path}
    end
  end

  defp check_content(content) when is_binary(content) do
    cond do
      byte_size(content) > @max_bytes -> {:error, :too_large}
      String.valid?(content) -> :ok
      true -> {:error, :invalid_content}
    end
  end

  defp check_content(_content), do: {:error, :invalid_content}

  defp file_name(part, nil, ext), do: "#{part}.#{ext}"
  defp file_name(part, locale, ext), do: "#{part}.#{locale}.#{ext}"

  # Written beside the target and renamed over it: a rename within a directory
  # is atomic, so a reader never sees a half-written file. The data is synced
  # before the rename, so a crash cannot leave the new name on an empty file.
  # The dot prefix keeps the temporary name from ever parsing as a part file.
  defp write_atomically(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    with :ok <- write_synced(tmp, content),
         :ok <- keep_mode(path, tmp),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp write_synced(path, content) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- :file.write(file, content), do: :file.datasync(file)
      after
        :file.close(file)
      end
    end
  end

  # A replaced file keeps its permission bits rather than taking the umask's.
  defp keep_mode(path, tmp) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(tmp, Bitwise.band(mode, 0o777))
      {:error, _reason} -> :ok
    end
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
