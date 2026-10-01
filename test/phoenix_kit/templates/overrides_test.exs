defmodule PhoenixKit.Templates.OverridesTest do
  # tmp_dir gives each test its own root, so the persistent_term cache (keyed on
  # the root) cannot leak between them and the suite stays async.
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates.Overrides

  @moduletag :tmp_dir

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "read/4 locale precedence" do
    test "prefers the exact dialect over the base language", %{tmp_dir: root} do
      write(root, "alert", "text.en-GB.txt", "dialect")
      write(root, "alert", "text.en.txt", "base")
      write(root, "alert", "text.txt", "plain")

      assert Overrides.read([root], "alert", :text, "en-GB") == "dialect"
    end

    test "falls back from a dialect to the base language", %{tmp_dir: root} do
      write(root, "alert", "text.en.txt", "base")
      write(root, "alert", "text.txt", "plain")

      assert Overrides.read([root], "alert", :text, "en-GB") == "base"
    end

    test "falls back to the locale-less file", %{tmp_dir: root} do
      # The single-language host: writes one file, gets it for every recipient.
      write(root, "alert", "text.txt", "plain")

      assert Overrides.read([root], "alert", :text, "en-GB") == "plain"
      assert Overrides.read([root], "alert", :text, "uk") == "plain"
      assert Overrides.read([root], "alert", :text, nil) == "plain"
    end

    test "drops one subtag at a time for a multi-subtag locale", %{tmp_dir: root} do
      write(root, "alert", "text.zh-Hant.txt", "script")
      write(root, "alert", "text.zh.txt", "base")

      assert Overrides.read([root], "alert", :text, "zh-Hant-TW") == "script"
      assert Overrides.read([root], "alert", :text, "zh-Hans-CN") == "base"
    end

    test "a nil locale skips the locale-specific candidates", %{tmp_dir: root} do
      write(root, "alert", "text.en.txt", "base")

      assert Overrides.read([root], "alert", :text, nil) == nil
    end
  end

  describe "read/4 parts and roots" do
    test "html reads a .html file, subject and text read .txt", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "s")
      write(root, "alert", "text.txt", "t")
      write(root, "alert", "html.html", "<p>h</p>")

      assert Overrides.read([root], "alert", :subject, nil) == "s"
      assert Overrides.read([root], "alert", :text, nil) == "t"
      assert Overrides.read([root], "alert", :html, nil) == "<p>h</p>"
    end

    test "markdown reads a .md file, layout reads a .txt file", %{tmp_dir: root} do
      write(root, "alert", "markdown.md", "# hi")
      write(root, "alert", "markdown.de.md", "# hallo")
      write(root, "alert", "layout.txt", "billing")

      assert Overrides.read([root], "alert", :markdown, nil) == "# hi"
      assert Overrides.read([root], "alert", :markdown, "de-AT") == "# hallo"
      assert Overrides.read([root], "alert", :layout, nil) == "billing"
    end

    test "parts/0 lists all five" do
      assert Enum.sort(Overrides.parts()) == [:html, :layout, :markdown, :subject, :text]
    end

    test "locate/4 returns the path read/4 reads, through every fallback", %{tmp_dir: root} do
      first = Path.join(root, "first")
      second = Path.join(root, "second")
      write(first, "alert", "text.txt", "plain")
      write(second, "alert", "text.de.txt", "second-de")
      write(second, "alert", "text.de-AT.txt", "second-de-at")

      f_plain = {Path.join([first, "alert", "text.txt"]), "plain"}
      s_de = {Path.join([second, "alert", "text.de.txt"]), "second-de"}
      s_de_at = {Path.join([second, "alert", "text.de-AT.txt"]), "second-de-at"}

      # {roots, locale, expected}: an earlier root shadows a later one even
      # when the later one has the more specific locale.
      cases = [
        {[first, second], nil, f_plain},
        {[first, second], "de", f_plain},
        {[first, second], "de-AT", f_plain},
        {[second, first], nil, f_plain},
        {[second, first], "de", s_de},
        {[second, first], "de-AT", s_de_at},
        {[second, first], "de-CH", s_de},
        {[second, first], "fr", f_plain},
        {[second, first], "junk!", f_plain},
        {[second], "de-AT", s_de_at},
        {[second], "de-CH", s_de},
        {[second], "fr", nil},
        {[second], nil, nil}
      ]

      for {roots, locale, expected} <- cases do
        assert Overrides.locate(roots, "alert", :text, locale) == expected,
               "locate #{inspect(roots)} #{inspect(locale)}"

        expected_content = expected && elem(expected, 1)
        assert Overrides.read(roots, "alert", :text, locale) == expected_content
      end

      assert Overrides.locate([second], "alert", :html, nil) == nil
    end

    test "layout is locale-less: layout.<locale>.txt is ignored", %{tmp_dir: root} do
      write(root, "alert", "layout.de.txt", "de-group")
      assert Overrides.locate([root], "alert", :layout, "de") == nil
      assert Overrides.read([root], "alert", :layout, "de") == nil

      # Absence is cached, so drop it before the file appears.
      Overrides.reset_cache([root])
      write(root, "alert", "layout.txt", "billing")
      path = Path.join([root, "alert", "layout.txt"])
      assert Overrides.locate([root], "alert", :layout, "de") == {path, "billing"}
      assert Overrides.locate([root], "alert", :layout, "de-AT") == {path, "billing"}
      assert Overrides.read([root], "alert", :layout, nil) == "billing"
    end

    test "locate/4 finds an empty file", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "")

      assert Overrides.locate([root], "alert", :text, nil) ==
               {Path.join([root, "alert", "text.txt"]), ""}
    end

    test "locate/4 junk names and locales mint no cache entries", %{tmp_dir: root} do
      before = map_size(cache_entries(root))

      assert Overrides.locate([root], "../etc", :text, nil) == nil
      assert Overrides.locate([root], "__x", :text, nil) == nil
      assert Overrides.locate([root], "alert", :bogus, nil) == nil
      assert Overrides.locate([root], "alert", :text, "../../x") == nil

      # Exactly one entry: the valid name and part, its garbage locale having
      # collapsed into the nil-locale entry.
      assert map_size(cache_entries(root)) == before + 1
    end

    test "an earlier root shadows a later one", %{tmp_dir: root} do
      first = Path.join(root, "first")
      second = Path.join(root, "second")
      write(first, "alert", "text.txt", "winner")
      write(second, "alert", "text.txt", "loser")

      assert Overrides.read([first, second], "alert", :text, nil) == "winner"
    end

    test "returns nil when no root has the file", %{tmp_dir: root} do
      assert Overrides.read([root], "alert", :text, nil) == nil
      assert Overrides.read([], "alert", :text, nil) == nil
    end
  end

  describe "read/4 reserved names with a leading underscore" do
    test "finds a file under _layout", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<p>{{{content}}}</p>")

      assert Overrides.read([root], "_layout", :html, nil) == "<p>{{{content}}}</p>"
    end

    test "prefers the locale file, then falls back to the locale-less one", %{tmp_dir: root} do
      write(root, "_layout", "html.de.html", "de")
      write(root, "_layout", "html.html", "plain")

      assert Overrides.read([root], "_layout", :html, "de") == "de"
      assert Overrides.read([root], "_layout", :html, "de-AT") == "de"
      assert Overrides.read([root], "_layout", :html, "fr") == "plain"
      assert Overrides.read([root], "_layout", :html, nil) == "plain"
    end

    test "falls back to the locale-less file when there is no locale file", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "plain")

      assert Overrides.read([root], "_layout", :html, "en-GB") == "plain"
    end

    test "is nil when the host ships no layout", %{tmp_dir: root} do
      assert Overrides.read([root], "_layout", :html, "en") == nil
    end

    test "ordinary names keep working", %{tmp_dir: root} do
      write(root, "a", "text.txt", "one")
      write(root, "a_b-c9", "text.txt", "two")
      write(root, "9lives", "text.txt", "three")

      assert Overrides.read([root], "a", :text, nil) == "one"
      assert Overrides.read([root], "a_b-c9", :text, nil) == "two"
      assert Overrides.read([root], "9lives", :text, nil) == "three"
    end

    test "only a single leading underscore is accepted", %{tmp_dir: root} do
      File.write!(Path.join(root, "secret.txt"), "top secret")
      write(root, "_x", "text.txt", "ok")
      write(root, "__x", "text.txt", "double")
      write(root, "_", "text.txt", "bare")
      write(root, "_-x", "text.txt", "dash")
      write(root, "._x", "text.txt", "dot")

      assert Overrides.read([root], "_x", :text, nil) == "ok"

      for name <- ["__x", "_", "_-x", "_../x", "._x", "_.x", "_/x", "_..", "_x/../_x", "_x\n"] do
        assert Overrides.read([root], name, :text, nil) == nil,
               "expected #{inspect(name)} to resolve to no override"
      end
    end

    test "rejected underscore names mint no cache entries", %{tmp_dir: root} do
      Overrides.read([root], "_layout", :html, nil)
      before = cache_keys(root)

      for name <- ["__x", "_", "_-x", "_../x", "._x", "_layout\n", "_.x", "_/x", "_.."] do
        Overrides.read([root], name, :html, nil)
        Overrides.read([root], name, :html, "de")
      end

      assert cache_keys(root) == before
    end
  end

  describe "read/4 path safety" do
    test "refuses a name that would escape the root", %{tmp_dir: root} do
      # This module turns a caller-supplied name into a filesystem read; that is
      # not a boundary to leave to the caller's good behaviour.
      File.write!(Path.join(root, "secret.txt"), "top secret")

      for name <- ["../secret", "..", "a/../../b", "/etc/passwd", "Alert", ""] do
        assert Overrides.read([root], name, :text, nil) == nil,
               "expected #{inspect(name)} to resolve to no override"
      end
    end

    test "an unparseable locale contributes no candidate of its own", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "plain")

      # Falls through to the locale-less file rather than building a path out of
      # the junk it was handed.
      assert Overrides.read([root], "alert", :text, "../../etc") == "plain"
    end

    test "a bare string root is a caller bug, not an empty lookup", %{tmp_dir: root} do
      assert_raise FunctionClauseError, fn -> Overrides.read(root, "alert", :text, nil) end
    end

    test "an unknown part resolves to nothing", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "plain")

      assert Overrides.read([root], "alert", :footer, nil) == nil
    end
  end

  describe "caching" do
    test "a lookup is made once and then served from the cache", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "original")
      assert Overrides.read([root], "alert", :text, nil) == "original"

      File.write!(Path.join([root, "alert", "text.txt"]), "changed")
      assert Overrides.read([root], "alert", :text, nil) == "original"

      Overrides.reset_cache([root])
      assert Overrides.read([root], "alert", :text, nil) == "changed"
    end

    test "a missing override is cached too, not re-stat'd on every send", %{tmp_dir: root} do
      assert Overrides.read([root], "alert", :text, nil) == nil

      write(root, "alert", "text.txt", "appeared")
      assert Overrides.read([root], "alert", :text, nil) == nil

      Overrides.reset_cache([root])
      assert Overrides.read([root], "alert", :text, nil) == "appeared"
    end

    test "junk input cannot mint cache entries of its own", %{tmp_dir: root} do
      # Every key is a permanent :persistent_term entry, and each new one copies
      # the whole table — so garbage must share nil's entry or make none at all.
      Overrides.read([root], "alert", :text, nil)
      before = cache_keys(root)

      Overrides.read([root], "alert", :text, "not a locale")
      Overrides.read([root], "alert", :text, "../../etc")
      Overrides.read([root], "../alert", :text, nil)
      Overrides.read([root], "alert", :footer, nil)

      assert cache_keys(root) == before
    end
  end

  defp cache_keys(root) do
    for {{Overrides, :located, roots, _, _, _} = key, _} <- :persistent_term.get(),
        root in roots,
        do: key
  end

  defp cache_entries(root) do
    for {{Overrides, :located, roots, _, _, _} = key, value} <- :persistent_term.get(),
        root in roots,
        into: %{},
        do: {key, value}
  end
end
