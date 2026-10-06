defmodule PhoenixKit.Templates.OverridesWriteTest do
  # tmp_dir gives each test its own root, so the persistent_term cache (keyed on
  # the root) cannot leak between them and the suite stays async.
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates
  alias PhoenixKit.Templates.Overrides

  @moduletag :tmp_dir

  defp file(root, name, file), do: Path.join([root, name, file])

  describe "write/5" do
    test "writes <root>/<name>/<part>[.<locale>].<ext>", %{tmp_dir: root} do
      assert {:ok, _paths} = Overrides.write(root, "alert", :subject, "et", "Tere")
      assert {:ok, _paths} = Overrides.write(root, "alert", :text, nil, "plain")
      assert {:ok, _paths} = Overrides.write(root, "alert", :html, "en-GB", "<p>h</p>")
      assert {:ok, _paths} = Overrides.write(root, "alert", :markdown, "ru", "# r")
      assert {:ok, _paths} = Overrides.write(root, "alert", :layout, nil, "billing")

      assert File.read!(file(root, "alert", "subject.et.txt")) == "Tere"
      assert File.read!(file(root, "alert", "text.txt")) == "plain"
      assert File.read!(file(root, "alert", "html.en-GB.html")) == "<p>h</p>"
      assert File.read!(file(root, "alert", "markdown.ru.md")) == "# r"
      assert File.read!(file(root, "alert", "layout.txt")) == "billing"
    end

    test "label is a writable .txt part that rendering never reads", %{tmp_dir: root} do
      assert {:ok, _paths} = Overrides.write(root, "alert", :label, "et", "Hinnapakkumine")
      assert {:ok, _paths} = Overrides.write(root, "alert", :label, nil, "Price offer")

      assert File.read!(file(root, "alert", "label.et.txt")) == "Hinnapakkumine"
      assert File.read!(file(root, "alert", "label.txt")) == "Price offer"
      refute :label in Overrides.parts()
      assert Overrides.read([root], "alert", :label, "et") == nil
    end

    test "returns the file written, preceded by a directory it created", %{tmp_dir: root} do
      dir = Path.join(root, "alert")

      assert Overrides.write(root, "alert", :text, "et", "one") ==
               {:ok, [dir, Path.join(dir, "text.et.txt")]}

      assert Overrides.write(root, "alert", :text, "ru", "two") ==
               {:ok, [Path.join(dir, "text.ru.txt")]}
    end

    test "replaces an existing file", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alert", :text, nil, "first")
      {:ok, _} = Overrides.write(root, "alert", :text, nil, "second")

      assert File.read!(file(root, "alert", "text.txt")) == "second"
    end

    test "accepts a name with one leading underscore", %{tmp_dir: root} do
      assert {:ok, _} = Overrides.write(root, "_header-andi", :html, nil, "<b>hi</b>")
      assert File.read!(file(root, "_header-andi", "html.html")) == "<b>hi</b>"
    end

    test "rejects a name the read pattern rejects", %{tmp_dir: root} do
      for name <- ["../escape", "..", "a/b", "/etc/x", "Alert", "", "__x", "_", "a.b", "x\n", nil] do
        assert Overrides.write(root, name, :text, nil, "x") == {:error, :invalid_name},
               "expected #{inspect(name)} to be rejected"
      end

      assert File.ls!(root) == []
    end

    test "rejects an unknown part", %{tmp_dir: root} do
      for part <- [:footer, :audience, "text", nil] do
        assert Overrides.write(root, "alert", part, nil, "x") == {:error, :invalid_part}
      end

      assert File.ls!(root) == []
    end

    test "rejects a locale the read pattern rejects", %{tmp_dir: root} do
      # Reading falls back on a junk locale; writing must not silently turn it
      # into the locale-less file instead.
      for locale <- ["../../etc", "e", "not a locale", "en_GB", "en.x", "", :et] do
        assert Overrides.write(root, "alert", :text, locale, "x") == {:error, :invalid_locale},
               "expected #{inspect(locale)} to be rejected"
      end

      assert File.ls!(root) == []
    end

    test "layout is locale-less, so a locale is refused rather than ignored", %{tmp_dir: root} do
      assert Overrides.write(root, "alert", :layout, "de", "billing") == {:error, :invalid_locale}
      refute File.exists?(file(root, "alert", "layout.de.txt"))
    end

    test "refuses content over the size limit", %{tmp_dir: root} do
      limit = Overrides.max_bytes()
      assert limit == 256 * 1024

      assert {:ok, _} = Overrides.write(root, "alert", :text, nil, String.duplicate("a", limit))

      assert Overrides.write(root, "alert", :html, nil, String.duplicate("a", limit + 1)) ==
               {:error, :too_large}

      refute File.exists?(file(root, "alert", "html.html"))
    end

    test "refuses content that is not a UTF-8 string", %{tmp_dir: root} do
      assert Overrides.write(root, "alert", :text, nil, <<0xFF, 0xFE>>) ==
               {:error, :invalid_content}

      assert Overrides.write(root, "alert", :text, nil, nil) == {:error, :invalid_content}
      assert File.ls!(root) == []
    end

    test "refuses a root that is not an existing directory", %{tmp_dir: root} do
      missing = Path.join(root, "missing")

      assert Overrides.write(missing, "alert", :text, nil, "x") == {:error, :invalid_root}
      refute File.exists?(missing)
      assert Overrides.write(nil, "alert", :text, nil, "x") == {:error, :invalid_root}
    end

    test "refuses a template directory that is a symlink out of the root", %{tmp_dir: root} do
      outside = Path.join(root, "outside")
      inside = Path.join(root, "root")
      File.mkdir_p!(outside)
      File.mkdir_p!(inside)
      File.ln_s!(outside, Path.join(inside, "alert"))

      assert Overrides.write(inside, "alert", :text, nil, "x") == {:error, :unsafe_path}
      assert File.ls!(outside) == []
    end

    test "is atomic: a failed write leaves the old file and no temporary file", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alert", :text, nil, "old")
      # A directory where the file should go makes the final rename fail.
      File.mkdir_p!(file(root, "alert", "html.html"))

      assert {:error, _reason} = Overrides.write(root, "alert", :html, nil, "new")
      assert File.ls!(Path.join(root, "alert")) |> Enum.sort() == ["html.html", "text.txt"]
      assert File.read!(file(root, "alert", "text.txt")) == "old"
    end

    test "leaves no temporary file behind after a successful write", %{tmp_dir: root} do
      for n <- 1..5, do: {:ok, _} = Overrides.write(root, "alert", :text, nil, "v#{n}")

      assert File.ls!(Path.join(root, "alert")) == ["text.txt"]
    end

    test "the new content is visible to a cached read immediately", %{tmp_dir: root} do
      # Both a cached absence and a cached hit must be dropped by the write.
      assert Overrides.read([root], "alert", :text, "et") == nil

      {:ok, _} = Overrides.write(root, "alert", :text, "et", "first")
      assert Overrides.read([root], "alert", :text, "et") == "first"

      {:ok, _} = Overrides.write(root, "alert", :text, "et", "second")
      assert Overrides.read([root], "alert", :text, "et") == "second"
    end

    test "clears cache entries whose roots include this one", %{tmp_dir: root} do
      other = Path.join(root, "other")
      mine = Path.join(root, "mine")
      File.mkdir_p!(other)
      File.mkdir_p!(mine)
      File.mkdir_p!(Path.join(other, "alert"))
      File.write!(Path.join([other, "alert", "subject.txt"]), "from other")

      assert Templates.render("alert", %{}, %{}, paths: [mine, other]).subject == "from other"

      {:ok, _} = Overrides.write(mine, "alert", :subject, nil, "from mine")
      assert Templates.render("alert", %{}, %{}, paths: [mine, other]).subject == "from mine"
    end
  end

  describe "valid_name?/1" do
    test "applies the pattern read/4 and write/5 use" do
      for name <- ["alert", "_header-andi", "a_b-c9", "9lives"],
          do: assert(Overrides.valid_name?(name))

      for name <- ["../x", "Alert", "", "__x", "_", "a.b", "x\n", nil, :alert] do
        refute Overrides.valid_name?(name), "expected #{inspect(name)} to be invalid"
      end
    end
  end

  describe "delete/4" do
    test "removes one file and drops the cached content", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alert", :text, "et", "et")
      {:ok, _} = Overrides.write(root, "alert", :text, nil, "plain")
      assert Overrides.read([root], "alert", :text, "et") == "et"

      assert Overrides.delete(root, "alert", :text, "et") == :ok

      refute File.exists?(file(root, "alert", "text.et.txt"))
      assert Overrides.read([root], "alert", :text, "et") == "plain"
    end

    test "deletes a label", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alert", :label, "et", "x")
      assert Overrides.delete(root, "alert", :label, "et") == :ok
      refute File.exists?(file(root, "alert", "label.et.txt"))
    end

    test "reports a missing file", %{tmp_dir: root} do
      assert Overrides.delete(root, "alert", :text, "et") == {:error, :enoent}
    end

    test "validates exactly like write/5", %{tmp_dir: root} do
      File.write!(Path.join(root, "secret.txt"), "top secret")

      assert Overrides.delete(root, "../x", :text, nil) == {:error, :invalid_name}
      assert Overrides.delete(root, "alert", :footer, nil) == {:error, :invalid_part}
      assert Overrides.delete(root, "alert", :text, "../x") == {:error, :invalid_locale}
      assert Overrides.delete(Path.join(root, "no"), "a", :text, nil) == {:error, :invalid_root}
      assert File.exists?(Path.join(root, "secret.txt"))
    end
  end

  describe "delete_template/2" do
    test "removes the whole directory and drops the cache", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alert", :text, nil, "plain")
      {:ok, _} = Overrides.write(root, "alert", :subject, "et", "s")
      assert Overrides.read([root], "alert", :text, nil) == "plain"

      assert Overrides.delete_template(root, "alert") == :ok

      refute File.exists?(Path.join(root, "alert"))
      assert Overrides.read([root], "alert", :text, nil) == nil
    end

    test "reports a missing template", %{tmp_dir: root} do
      assert Overrides.delete_template(root, "alert") == {:error, :enoent}
    end

    test "refuses names that would escape the root", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "keep"))

      for name <- ["..", ".", "", "../keep", "keep/..", "/tmp", nil] do
        assert Overrides.delete_template(Path.join(root, "keep"), name) ==
                 {:error, :invalid_name}
      end

      assert File.dir?(Path.join(root, "keep"))
    end

    test "refuses a symlinked template directory pointing out of the root", %{tmp_dir: root} do
      outside = Path.join(root, "outside")
      inside = Path.join(root, "root")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "text.txt"), "keep me")
      File.mkdir_p!(inside)
      File.ln_s!(outside, Path.join(inside, "alert"))

      assert Overrides.delete_template(inside, "alert") == {:error, :unsafe_path}
      assert File.read!(Path.join(outside, "text.txt")) == "keep me"
    end
  end

  describe "list/1" do
    test "lists template directories with their part files", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "beta", :text, nil, "t")
      {:ok, _} = Overrides.write(root, "alpha", :subject, "et", "s")
      {:ok, _} = Overrides.write(root, "alpha", :label, "en-GB", "l")
      {:ok, _} = Overrides.write(root, "alpha", :layout, nil, "billing")
      {:ok, _} = Overrides.write(root, "_footer-x", :html, nil, "<p>f</p>")

      assert [
               %{name: "_footer-x", files: [%{part: :html, locale: nil}]},
               %{name: "alpha", files: alpha_files},
               %{name: "beta", files: [%{part: :text, locale: nil} = text]}
             ] = Overrides.list(root)

      assert Enum.map(alpha_files, &{&1.part, &1.locale}) ==
               [{:label, "en-GB"}, {:layout, nil}, {:subject, "et"}]

      assert text.path == Path.join([root, "beta", "text.txt"])
      assert %DateTime{} = text.mtime
    end

    test "skips files and directories that are not templates or parts", %{tmp_dir: root} do
      {:ok, _} = Overrides.write(root, "alpha", :text, "et", "t")
      File.write!(Path.join(root, "README.txt"), "not a template")
      File.mkdir_p!(Path.join(root, "Bad.Name"))
      File.mkdir_p!(Path.join(root, "__x"))

      for junk <- [
            "audience.txt",
            "text.et.html",
            "layout.de.txt",
            "text.not-a-locale!.txt",
            ".text.txt.123.tmp",
            "notes.md"
          ] do
        File.write!(Path.join([root, "alpha", junk]), "junk")
      end

      assert [%{name: "alpha", files: [%{part: :text, locale: "et"}]}] = Overrides.list(root)
    end

    test "keeps an empty template directory", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, "draft"))
      assert Overrides.list(root) == [%{name: "draft", files: []}]
    end

    test "a missing root lists nothing", %{tmp_dir: root} do
      assert Overrides.list(Path.join(root, "missing")) == []
    end
  end
end
