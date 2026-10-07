defmodule PhoenixKit.Templates.EditorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias PhoenixKit.Templates
  alias PhoenixKit.Templates.Overrides

  @endpoint PhoenixKit.Templates.TestEndpoint
  @moduletag :tmp_dir

  defmodule Host do
    # A host LiveView rendering the editor the way an application would. The
    # test process gets every after_write call as a message, unless the test
    # passes an after_write of its own.
    use Phoenix.LiveView

    @impl true
    def mount(_params, %{"opts" => opts, "test_pid" => test_pid}, socket) do
      opts =
        opts
        |> Map.put_new(:after_write, fn paths -> send(test_pid, {:after_write, paths}) end)
        |> Map.put_new(:after_change, fn name -> send(test_pid, {:after_change, name}) end)
        |> maybe_render_preview()

      {:ok, assign(socket, opts: opts)}
    end

    @impl true
    def handle_info({:put, changes}, socket) do
      {:noreply, assign(socket, opts: Map.merge(socket.assigns.opts, changes))}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.live_component module={PhoenixKit.Templates.Editor} id="editor" {@opts} />
      """
    end

    # Renders the files themselves, to show a preview reads what was just saved.
    defp maybe_render_preview(%{preview: :render, root: root} = opts) do
      preview = fn name, locale ->
        parts = Templates.render(name, %{}, %{}, locale: locale, paths: [root])
        {parts.subject, parts.html || parts.text}
      end

      %{opts | preview: preview}
    end

    defp maybe_render_preview(opts), do: opts

    def preview("order_broken", _locale), do: {:error, :boom}
    def preview("order_timeout", _locale), do: exit(:timeout)
    def preview("order_shapeless", _locale), do: %{subject: "S"}

    def preview("order_safe", _locale) do
      {{:safe, ~s(<b id="pwned-subject">S</b>)},
       {:safe, ~s("></iframe><b id="pwned">x</b><iframe srcdoc=")}}
    end

    def preview(name, locale) do
      {"Subject of #{name} (#{locale})",
       "<p>Hello from #{name}</p><script>window.parent.alert(1)</script>"}
    end

    def failing_after_write(_paths), do: raise("chown failed")
    def failing_after_change(_name), do: raise("refresh failed")

    # A host's text and HTML versions, the way a mailer would build them.
    def preview_with_text(name, locale) do
      {subject, html} = preview(name, locale)
      {subject, html, "Hello from #{name} <as text>"}
    end

    # Crude stand-ins for a host's Markdown renderer: like a real one, they
    # leave a placeholder they are given no value for as it is.
    def to_text(:markdown, markdown), do: String.replace(markdown, "**", "")
    def to_text(:html, html), do: String.replace(html, ~r/<[^>]*>/, "")

    def markdown_to_html(markdown) do
      "<p>" <> String.replace(markdown, ~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>") <> "</p>"
    end

    def failing_to_text(_format, _source), do: raise("converter down")
    def refusing_to_text(_format, _source), do: {:error, "cannot convert this"}
    def shapeless_to_text(_format, _source), do: {:ok, "text"}
    def latin_to_text(_format, _source), do: <<"Tere ", 0xE4>>
  end

  defp put(root, name, file, content) do
    File.mkdir_p!(Path.join(root, name))
    File.write!(Path.join([root, name, file]), content)
  end

  defp seed(root) do
    put(root, "order_offer", "label.et.txt", "Pakkumiskiri\n")
    put(root, "order_offer", "label.en.txt", "Price offer\n")
    put(root, "order_offer", "subject.et.txt", "Pakkumine {{order_number}}\n")
    put(root, "order_offer", "text.et.txt", "Tere!\n\n{{documents_list}}\n")
    put(root, "order_offer", "subject.ru.txt", "Предложение\n")
    put(root, "_header-shop", "html.html", "<p>Shop</p>\n")
    put(root, "secret_other", "text.txt", "not for this editor\n")
  end

  defp mount_editor(root, opts \\ %{}) do
    opts =
      Map.merge(
        %{
          root: root,
          editable: true,
          name_prefixes: ["order_", "_header-shop", "_footer-shop", "_layout-shop"],
          locales: ["et", "ru", "en"],
          preview: {Host, :preview},
          sample_variables: %{"order_number" => "37", "documents_list" => "- offer.pdf"}
        },
        opts
      )

    {:ok, view, _html} =
      live_isolated(build_conn(), Host, session: %{"opts" => opts, "test_pid" => self()})

    view
  end

  defp select(view, name) do
    view |> element("#editor [phx-click=select][phx-value-name=#{name}]") |> render_click()
  end

  defp tab(view, locale) do
    view |> element("#editor [phx-click=locale][phx-value-locale='#{locale}']") |> render_click()
  end

  defp save(view, parts) do
    view |> form("#editor-parts", parts: parts) |> render_submit()
  end

  defp create(view, name, copy_from \\ "") do
    view |> form("#editor-create", create: %{name: name, copy_from: copy_from}) |> render_submit()
  end

  # Presses a conversion button, the browser sending every field as it stands.
  defp convert(view, action, parts) do
    view
    |> form("#editor-parts", parts: parts)
    |> put_submitter("#editor-parts button[name=action][value=#{action}]")
    |> render_submit()
  end

  # The diff the server sends back for `fun`'s event, as a browser gets it.
  # The test's page never holds what a user retyped in a field, so whether
  # the field is sent again is seen here, not in the rendered page.
  defp reply_diff(view, fun) do
    {_ref, _topic, proxy} = view.proxy
    :erlang.trace(proxy, true, [:receive])
    fun.()
    assert_receive {:trace, ^proxy, :receive, %Phoenix.Socket.Reply{payload: payload}}
    :erlang.trace(proxy, false, [:receive])
    payload |> Map.get(:diff, %{}) |> inspect(limit: :infinity, printable_limit: :infinity)
  end

  # What a field holds in the page, unescaped.
  defp field(view, part) do
    view
    |> element("#editor-parts textarea[name='parts[#{part}]']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace_prefix("\n", "")
  end

  @convert %{to_text: {Host, :to_text}, markdown_to_html: {Host, :markdown_to_html}}

  describe "the list" do
    test "shows only names under the prefixes, shared parts in their own group",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      html = render(view)

      assert has_element?(view, "#editor-messages [phx-value-name=order_offer]")
      assert has_element?(view, "#editor-shared [phx-value-name=_header-shop]")
      refute has_element?(view, "#editor-messages [phx-value-name=_header-shop]")
      refute html =~ "secret_other"
    end

    test "captions a template with its label in the first locale", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      assert view |> element("[phx-value-name=order_offer]") |> render() =~
               "Pakkumiskiri"

      view = mount_editor(root, %{locales: ["en", "et"]})
      assert view |> element("[phx-value-name=order_offer]") |> render() =~ "Price offer"
    end

    test "a missing root shows an empty list rather than crashing", %{tmp_dir: root} do
      view = mount_editor(Path.join(root, "missing"))
      assert render(view) =~ "No templates"
    end

    test "a root that is not a path says so and offers nothing to write", %{tmp_dir: _root} do
      view = mount_editor(nil)

      assert render(view) =~ "No template directory is configured"
      refute has_element?(view, "#editor-create")

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => "order_x", "copy_from" => ""}
      })

      assert Process.alive?(view.pid)
    end

    test "a label that is not UTF-8 is not used as the caption", %{tmp_dir: root} do
      put(root, "order_latin", "label.et.txt", <<"Pakkumiskiri ", 0xE4>>)
      put(root, "order_latin", "text.et.txt", "Tere")
      view = mount_editor(root)

      assert view |> element("[phx-value-name=order_latin]") |> render() =~
               "order_latin"

      assert String.valid?(render(view))
      refute render(view) =~ "Pakkumiskiri"
    end
  end

  describe "editing" do
    test "shows each part of the selected locale", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      assert view |> element("#editor-parts textarea[name='parts[subject]']") |> render() =~
               "Pakkumine {{order_number}}"

      tab(view, "ru")

      assert view |> element("#editor-parts textarea[name='parts[subject]']") |> render() =~
               "Предложение"

      assert has_element?(view, "#editor [role=tab][aria-selected=true]", "ru")
      refute has_element?(view, "#editor [role=tab][aria-selected=true]", "et")

      for part <- ~w(label subject text markdown html) do
        assert has_element?(view, "#editor-parts textarea[name='parts[#{part}]']")
      end
    end

    test "opens a locale-less template on its fallback tab", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "_header-shop")

      assert view |> element("#editor-parts textarea[name='parts[html]']") |> render() =~
               "&lt;p&gt;Shop&lt;/p&gt;"
    end

    test "saves changed parts to the selected locale and reports the paths",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")
      tab(view, "en")

      html = save(view, %{label: "Offer", subject: "Offer {{order_number}}", text: ""})

      assert html =~ "Saved"
      dir = Path.join(root, "order_offer")
      assert File.read!(Path.join(dir, "label.en.txt")) == "Offer"
      assert File.read!(Path.join(dir, "subject.en.txt")) == "Offer {{order_number}}"
      refute File.exists?(Path.join(dir, "text.en.txt"))
      assert_received {:after_write, paths}

      assert Enum.sort(paths) == [
               Path.join(dir, "label.en.txt"),
               Path.join(dir, "subject.en.txt")
             ]
    end

    test "does not rewrite a part that did not change", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      html = save(view, %{subject: "Pakkumine {{order_number}}\n", label: "Pakkumiskiri\n"})

      assert html =~ "No changes"
      refute_received {:after_write, _paths}
    end

    test "an emptied part deletes its file, so rendering falls back", %{tmp_dir: root} do
      seed(root)
      put(root, "order_offer", "subject.txt", "Fallback subject\n")
      view = mount_editor(root)
      select(view, "order_offer")

      save(view, %{subject: ""})

      refute File.exists?(Path.join([root, "order_offer", "subject.et.txt"]))

      assert Templates.render("order_offer", %{}, %{}, locale: "et", paths: [root]).subject ==
               "Fallback subject"
    end

    test "emptying every part leaves an unsaved template, not an empty directory",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "_header-shop")

      html = save(view, %{html: ""})

      assert html =~ "Saved."
      refute File.exists?(Path.join(root, "_header-shop"))
      assert render(view) =~ "not saved yet"
      refute has_element?(view, "[phx-value-name=_header-shop]")

      save(view, %{html: "<p>Back</p>"})

      assert File.read!(Path.join([root, "_header-shop", "html.html"])) == "<p>Back</p>"
      refute render(view) =~ "not saved yet"
    end

    test "stores browser CRLF line breaks as LF", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      save(view, %{text: "Tere!\r\n\r\nNägemist\r\n"})

      assert File.read!(Path.join([root, "order_offer", "text.et.txt"])) ==
               "Tere!\n\nNägemist\n"
    end

    test "surfaces a refusal from the write API", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      html = save(view, %{html: String.duplicate("a", Overrides.max_bytes() + 1)})

      assert html =~ "larger than"
      refute File.exists?(Path.join([root, "order_offer", "html.et.html"]))
      refute_received {:after_write, _paths}
    end

    test "a save that is partly refused says which parts were saved", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      html =
        save(view, %{
          subject: "New subject",
          text: "",
          html: String.duplicate("a", Overrides.max_bytes() + 1)
        })

      assert html =~ "Saved: Subject, Text. Not saved: HTML: larger than"
      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) == "New subject"
      refute File.exists?(Path.join([root, "order_offer", "text.et.txt"]))
      assert_received {:after_write, [_subject]}
    end

    test "malformed locales and sample variables are cleaned, not a crash", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{locales: ["et", "", :ru, "et", "en"], sample_variables: [:x]})

      html = select(view, "order_offer")

      assert html =~ "Fallback"
      assert html =~ "Pakkumine"
      refute has_element?(view, "#editor [role=tab][phx-value-locale='ru']")
      assert length(Regex.scan(~r/phx-value-locale="et"/, html)) == 1

      view2 = mount_editor(root, %{locales: "et"})
      assert select(view2, "order_offer") =~ "Fallback"
    end

    test "a part the write refused stays in the form, so the edit is not lost", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")
      big = String.duplicate("a", Overrides.max_bytes() + 1)

      save(view, %{subject: "New subject", html: big})

      assert view |> element("#editor-parts textarea[name='parts[html]']") |> render() =~ "aaaa"
      # What was saved shows what is on disk now.
      assert view |> element("#editor-parts textarea[name='parts[subject]']") |> render() =~
               "New subject"

      # Still an edit to retry: fixing the part and saving writes it.
      save(view, %{html: "<p>small</p>"})
      assert File.read!(Path.join([root, "order_offer", "html.et.html"])) == "<p>small</p>"
    end

    test "a refused part is dropped from the form on another tab", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      save(view, %{html: String.duplicate("a", Overrides.max_bytes() + 1)})
      tab(view, "ru")

      refute view |> element("#editor-parts textarea[name='parts[html]']") |> render() =~ "aaaa"
    end

    test "a failing after_write is reported and logged, not a crash", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{after_write: {Host, :failing_after_write}})
      select(view, "order_offer")

      log = capture_log(fn -> assert save(view, %{subject: "Uus"}) =~ "chown failed" end)

      path = Path.join([root, "order_offer", "subject.et.txt"])
      assert File.read!(path) == "Uus"
      assert Process.alive?(view.pid)
      assert log =~ "after_write"
      assert log =~ "chown failed"
      assert log =~ path
      assert log =~ "failing_after_write/1"
    end

    test "names a refusal in words, not as a POSIX error", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{locales: ["e"]})
      select(view, "order_offer")
      tab(view, "e")

      html = save(view, %{subject: "Uus"})

      assert html =~ "Subject: not a valid language tag"
      refute html =~ "POSIX"
    end

    test "a preview right after saving shows the saved content", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: :render})
      select(view, "order_offer")

      assert view |> element("#editor-preview-subject") |> render() =~
               "Pakkumine {{order_number}}"

      save(view, %{subject: "Uus pealkiri"})

      assert view |> element("#editor-preview-subject") |> render() =~ "Uus pealkiri"
    end

    test "a part file that is not UTF-8 is shown read-only and never overwritten",
         %{tmp_dir: root} do
      seed(root)
      latin = <<"Tere ", 0xE4, "\n">>
      put(root, "order_offer", "text.et.txt", latin)
      view = mount_editor(root)
      select(view, "order_offer")

      assert String.valid?(render(view))
      assert view |> element("#editor-part-text-invalid") |> render() =~ "not valid UTF-8"
      refute has_element?(view, "#editor-parts textarea[name='parts[text]']")

      save(view, %{subject: "Uus"})
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"text" => ""}})

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) == "Uus"
      assert File.read!(Path.join([root, "order_offer", "text.et.txt"])) == latin
    end

    test "a part file that is not UTF-8 is flagged in read-only mode too", %{tmp_dir: root} do
      seed(root)
      put(root, "order_offer", "text.et.txt", <<"Tere ", 0xE4>>)
      view = mount_editor(root, %{editable: false})
      select(view, "order_offer")

      assert String.valid?(render(view))
      assert render(view) =~ "not valid UTF-8"
    end

    test "flags placeholders the sample variables do not know", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")
      refute has_element?(view, "#editor-missing")

      save(view, %{text: "Tere {{order_numbr}}"})

      assert view |> element("#editor-missing") |> render() =~ "order_numbr"
    end
  end

  describe "creating" do
    test "the name and source fields have accessible names", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      assert has_element?(
               view,
               ~s(#editor-create input[name="create[name]"][aria-label="Template name"])
             )

      assert has_element?(
               view,
               ~s(#editor-create select[name="create[copy_from]"][aria-label="Start from"])
             )
    end

    test "an empty template exists once its first part is saved", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "order_new", copy_from: ""})
      |> render_submit()

      refute File.exists?(Path.join(root, "order_new"))

      save(view, %{subject: "Uus"})

      dir = Path.join(root, "order_new")
      assert File.read!(Path.join(dir, "subject.et.txt")) == "Uus"
      assert_received {:after_write, [^dir, _file]}
      assert has_element?(view, "#editor-messages [phx-value-name=order_new]")
    end

    test "a copy duplicates every part file of the source", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "order_copy", copy_from: "order_offer"})
      |> render_submit()

      source = Path.join(root, "order_offer")
      copy = Path.join(root, "order_copy")
      assert File.ls!(copy) |> Enum.sort() == File.ls!(source) |> Enum.sort()

      assert File.read!(Path.join(copy, "text.et.txt")) ==
               File.read!(Path.join(source, "text.et.txt"))

      assert_received {:after_write, [^copy | files]}
      assert length(files) == length(File.ls!(source))
    end

    test "a copy takes the host's own files beside the parts along", %{tmp_dir: root} do
      seed(root)
      put(root, "order_offer", "audience.txt", "partner\n")
      view = mount_editor(root)

      create(view, "order_copy", "order_offer")

      copy = Path.join(root, "order_copy")
      assert File.read!(Path.join(copy, "audience.txt")) == "partner\n"
      assert_received {:after_write, [^copy | files]}
      assert Path.join(copy, "audience.txt") in files
    end

    test "a copy whose source is gone says so", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      html =
        render_submit(with_target(view, "#editor"), "create", %{
          "create" => %{"name" => "order_x", "copy_from" => "order_gone"}
        })

      assert html =~ "There is no “order_gone” to copy."
      refute File.exists?(Path.join(root, "order_x"))
    end

    test "a copy refused by the write API leaves nothing and says why", %{tmp_dir: root} do
      seed(root)
      big = String.duplicate("a", Overrides.max_bytes() + 1)
      put(root, "order_offer", "html.et.html", big)
      view = mount_editor(root)

      html = create(view, "order_copy", "order_offer")

      assert html =~ "Not copied: larger than"
      refute File.exists?(Path.join(root, "order_copy"))
      refute_received {:after_write, _paths}
    end

    test "refuses a bad name, a name outside the prefixes and an existing name",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      for {name, message} <- [
            {"order_Bad.Name", "not a valid"},
            {"other_thing", "not allowed"},
            {"order_offer", "already exists"}
          ] do
        html =
          view
          |> form("#editor-create", create: %{name: name, copy_from: ""})
          |> render_submit()

        assert html =~ message, "expected #{inspect(name)} to be refused with #{message}"
      end

      refute File.exists?(Path.join(root, "other_thing"))
    end

    test "a copy of an empty template directory is an empty template", %{tmp_dir: root} do
      seed(root)
      File.mkdir_p!(Path.join(root, "order_empty"))
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "order_copy", copy_from: "order_empty"})
      |> render_submit()

      copy = Path.join(root, "order_copy")
      assert File.dir?(copy)
      assert_received {:after_write, [^copy]}
      refute render(view) =~ "not saved yet"
      save(view, %{subject: "Uus"})
      assert File.read!(Path.join(copy, "subject.et.txt")) == "Uus"
    end

    test "an unsaved draft is neither checked nor previewed against the file cache",
         %{tmp_dir: root} do
      # Every distinct lookup is a permanent :persistent_term entry; a name
      # with no files has nothing to check or render.
      seed(root)
      view = mount_editor(root, %{preview: :render})
      create(view, "order_new")

      assert render(view) =~ "not saved yet"
      assert view |> element("#editor-preview") |> render() =~ "Save the template to preview it."

      refute Enum.any?(:persistent_term.get(), fn
               {{Overrides, :located, [^root], "order_new", _part, _locale}, _} -> true
               _other -> false
             end)
    end

    test "a draft cannot be the source of a copy", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "order_draft")

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => "order_copy", "copy_from" => "order_draft"}
      })

      assert Process.alive?(view.pid)
      refute File.exists?(Path.join(root, "order_copy"))
    end

    test "a draft another session saved meanwhile is no longer a draft", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "order_new")

      put(root, "order_new", "subject.et.txt", "From elsewhere")
      send(view.pid, {:put, %{sample_variables: %{"order_number" => "38"}}})

      refute render(view) =~ "not saved yet"
      view |> element("#editor-delete") |> render_click()
      view |> element("#editor-delete-confirm") |> render_click()
      refute File.exists?(Path.join(root, "order_new"))
    end

    test "a malformed create event is ignored", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => ["order_x"], "copy_from" => ""}
      })

      assert has_element?(view, "#editor-create")
    end

    test "a create event whose copy source is not a string is ignored", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => "order_x", "copy_from" => %{"a" => "b"}}
      })

      assert Process.alive?(view.pid)
      assert has_element?(view, "#editor-create")
      refute File.exists?(Path.join(root, "order_x"))
    end

    test "cannot copy a template outside the prefixes", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> with_target("#editor")
      |> render_submit("create", %{
        "create" => %{"name" => "order_x", "copy_from" => "secret_other"}
      })

      refute File.exists?(Path.join(root, "order_x"))
    end
  end

  describe "deleting" do
    test "asks for confirmation first", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      view |> element("#editor-delete") |> render_click()
      assert File.dir?(Path.join(root, "order_offer"))
      view |> element("#editor-delete-cancel") |> render_click()
      refute has_element?(view, "#editor-delete-confirm")

      view |> element("#editor-delete") |> render_click()
      view |> element("#editor-delete-confirm") |> render_click()

      refute File.exists?(Path.join(root, "order_offer"))
      refute has_element?(view, "[phx-value-name=order_offer]")
    end
  end

  describe "preview" do
    test "shows the host's HTML in a sandboxed iframe that cannot run scripts",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      assert view |> element("#editor-preview-subject") |> render() =~
               "Subject of order_offer (et)"

      iframe = view |> element("#editor-preview iframe") |> render()
      assert iframe =~ ~s(sandbox="")
      refute iframe =~ "allow-scripts"
      assert iframe =~ "Hello from order_offer"

      tab(view, "ru")
      assert render(view) =~ "Subject of order_offer (ru)"
    end

    test "shows a host error instead of a preview, in the host's words", %{tmp_dir: root} do
      seed(root)
      put(root, "order_broken", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "order_broken")

      assert view |> element("#editor-preview [role=alert]") |> render() =~
               "Preview unavailable: boom"

      refute render(view) =~ "POSIX"
      refute has_element?(view, "#editor-preview iframe")
    end

    test "shows a host exit instead of a preview, and logs it", %{tmp_dir: root} do
      seed(root)
      put(root, "order_timeout", "text.et.txt", "x")
      view = mount_editor(root)

      log = capture_log(fn -> select(view, "order_timeout") end)

      assert render(view) =~ "Preview unavailable"
      assert log =~ "preview"
      assert log =~ "timeout"
      assert log =~ "Host.preview/2"
    end

    test "escapes safe tuples from the host instead of trusting them", %{tmp_dir: root} do
      seed(root)
      put(root, "order_safe", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "order_safe")

      refute has_element?(view, "#pwned")
      refute has_element?(view, "#pwned-subject")
      assert view |> element("#editor-preview iframe") |> render() =~ "pwned"
      assert view |> element("#editor-preview-subject") |> render() =~ "pwned-subject"
    end

    test "shows a result of the wrong shape as an error, not a crash", %{tmp_dir: root} do
      seed(root)
      put(root, "order_shapeless", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "order_shapeless")

      assert render(view) =~ "Preview unavailable: unexpected preview result"
      assert Process.alive?(view.pid)
    end

    test "follows a new preview callback from the host", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      send(view.pid, {:put, %{preview: fn name, _locale -> {"New look of #{name}", nil} end}})

      assert view |> element("#editor-preview-subject") |> render() =~
               "New look of order_offer"
    end

    test "an unrelated re-render does not call the preview again", %{tmp_dir: root} do
      seed(root)
      test_pid = self()
      view = mount_editor(root)
      select(view, "order_offer")

      counting = fn name, locale ->
        send(test_pid, {:previewed, name})
        Host.preview(name, locale)
      end

      send(view.pid, {:put, %{preview: counting}})
      render(view)
      assert_received {:previewed, "order_offer"}

      send(view.pid, {:put, %{tick: 1}})
      render(view)

      refute_received {:previewed, _name}
    end

    test "shows a file another session changed on the next update", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: :render})
      select(view, "order_offer")

      {:ok, _} = Overrides.write(root, "order_offer", :subject, "et", "From elsewhere")
      send(view.pid, {:put, %{tick: 1}})

      assert view |> element("#editor-preview-subject") |> render() =~ "From elsewhere"
    end

    test "no preview pane without a preview callback", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: nil})
      select(view, "order_offer")

      refute has_element?(view, "#editor-preview")
    end
  end

  describe "read-only" do
    test "shows the content with no way to change it", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{editable: false})
      select(view, "order_offer")

      assert render(view) =~ "Pakkumine {{order_number}}"
      refute has_element?(view, "#editor-parts")
      refute has_element?(view, "#editor-create")
      refute has_element?(view, "#editor-delete")
      assert has_element?(view, "#editor-preview iframe")
    end

    test "refuses write events sent anyway", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{editable: false})
      select(view, "order_offer")
      target = with_target(view, "#editor")

      render_submit(target, "save", %{"parts" => %{"subject" => "hacked"}})

      render_submit(target, "create", %{
        "create" => %{"name" => "order_x", "copy_from" => ""}
      })

      render_click(target, "delete", %{})
      render_click(target, "confirm_delete", %{})

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) ==
               "Pakkumine {{order_number}}\n"

      refute File.exists?(Path.join(root, "order_x"))
      refute_received {:after_write, _paths}
    end

    test "turning editable off on a live editor takes effect", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")
      assert has_element?(view, "#editor-parts")

      send(view.pid, {:put, %{editable: false}})

      refute has_element?(view, "#editor-parts")
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"subject" => "x"}})
      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) =~ "Pakkumine"
    end
  end

  describe "name prefixes" do
    test "a hidden template cannot be selected, written or deleted", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      target = with_target(view, "#editor")

      render_click(target, "select", %{"name" => "secret_other"})
      render_submit(target, "save", %{"parts" => %{"text" => "overwritten"}})
      render_click(target, "delete", %{})
      render_click(target, "confirm_delete", %{})

      assert File.read!(Path.join([root, "secret_other", "text.txt"])) == "not for this editor\n"
      refute_received {:after_write, _paths}
    end

    test "a draft whose name the host no longer allows cannot be saved", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "order_new")

      send(view.pid, {:put, %{name_prefixes: ["zzz_"]}})
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"text" => "x"}})

      refute File.exists?(Path.join(root, "order_new"))
      refute render(view) =~ "order_new"
    end

    test "an unknown locale is not a tab", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      render_click(with_target(view, "#editor"), "locale", %{"locale" => "de"})
      save(view, %{subject: "x"})

      refute File.exists?(Path.join([root, "order_offer", "subject.de.txt"]))
      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) == "x"
    end
  end

  describe "after_change" do
    test "follows a save that only deletes a part", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      html = save(view, %{text: ""})

      assert html =~ "Saved"
      refute File.exists?(Path.join([root, "order_offer", "text.et.txt"]))
      refute_received {:after_write, _paths}
      assert_received {:after_change, "order_offer"}
    end

    test "follows a save that writes", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      save(view, %{subject: "Uus {{order_number}}"})

      assert_received {:after_write, _paths}
      assert_received {:after_change, "order_offer"}
    end

    test "is not called when nothing changed", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      save(view, %{subject: "Pakkumine {{order_number}}\n"})

      refute_received {:after_change, _name}
    end

    test "follows a copy, named for the new template", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      create(view, "order_copy", "order_offer")

      assert File.exists?(Path.join(root, "order_copy"))
      assert_received {:after_change, "order_copy"}
    end

    test "follows deleting a template", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")
      target = with_target(view, "#editor")

      render_click(target, "delete", %{})
      render_click(target, "confirm_delete", %{})

      refute File.exists?(Path.join(root, "order_offer"))
      assert_received {:after_change, "order_offer"}
    end

    test "is not called for an unsaved draft deleted", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "order_draft")
      target = with_target(view, "#editor")

      render_click(target, "delete", %{})
      render_click(target, "confirm_delete", %{})

      refute_received {:after_change, _name}
    end

    test "a failing after_change is reported and logged, not a crash", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{after_change: {Host, :failing_after_change}})
      select(view, "order_offer")

      log =
        capture_log(fn ->
          html = save(view, %{text: ""})
          assert html =~ "after_change failed"
        end)

      assert log =~ "failing_after_change/1"
      refute File.exists?(Path.join([root, "order_offer", "text.et.txt"]))
    end
  end

  describe "a part the user did not edit" do
    test "is not written back over another session's change", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      # Another session saves the subject; the host re-renders the editor.
      File.write!(Path.join([root, "order_offer", "subject.et.txt"]), "Teine sessioon\n")
      Overrides.reset_cache([root])
      send(view.pid, {:put, %{sample_variables: %{"order_number" => "38"}}})
      _ = render(view)

      # The browser still holds the subject it was shown, untouched, and the
      # text the user did edit.
      view
      |> with_target("#editor")
      |> render_submit("save", %{
        "parts" => %{"subject" => "Pakkumine {{order_number}}\n", "text" => "Uus tekst\n"}
      })

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) ==
               "Teine sessioon\n"

      assert File.read!(Path.join([root, "order_offer", "text.et.txt"])) == "Uus tekst\n"
    end

    test "an edited part still wins over another session's change", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      File.write!(Path.join([root, "order_offer", "subject.et.txt"]), "Teine sessioon\n")
      Overrides.reset_cache([root])
      send(view.pid, {:put, %{sample_variables: %{"order_number" => "38"}}})
      _ = render(view)

      view
      |> with_target("#editor")
      |> render_submit("save", %{"parts" => %{"subject" => "Minu muudatus"}})

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) == "Minu muudatus"
    end
  end

  describe "a host's bad name_prefixes" do
    test "an empty prefix allows nothing by itself", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{name_prefixes: ["", "order_"]})

      assert has_element?(view, "#editor [phx-click=select][phx-value-name=order_offer]")
      refute has_element?(view, "#editor [phx-click=select][phx-value-name=secret_other]")
    end

    test "no list shows nothing and does not crash", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{name_prefixes: nil})

      refute has_element?(view, "#editor [phx-click=select]")
      assert Process.alive?(view.pid)
    end
  end

  describe "preview with a text version" do
    test "a host returning text gets HTML and Text tabs", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: {Host, :preview_with_text}})
      select(view, "order_offer")

      assert has_element?(view, "#editor-preview-tab-html[aria-selected=true]")
      assert has_element?(view, "#editor-preview iframe")
      refute has_element?(view, "#editor-preview-text")

      view |> element("#editor-preview-tab-text") |> render_click()

      assert has_element?(view, "#editor-preview-tab-text[aria-selected=true]")
      refute has_element?(view, "#editor-preview iframe")

      assert view |> element("#editor-preview-text") |> render() =~
               "Hello from order_offer &lt;as text&gt;"

      assert view |> element("#editor-preview-subject") |> render() =~
               "Subject of order_offer (et)"

      view |> element("#editor-preview-tab-html") |> render_click()
      assert has_element?(view, "#editor-preview iframe")
    end

    test "a text version of nil says there is none", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      send(view.pid, {:put, %{preview: fn _name, _locale -> {"S", "<p>H</p>", nil} end}})
      select(view, "order_offer")

      view |> element("#editor-preview-tab-text") |> render_click()

      assert view |> element("#editor-preview") |> render() =~ "No text."
    end

    test "a host returning only HTML gets no tabs", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      assert has_element?(view, "#editor-preview iframe")
      refute has_element?(view, "#editor-preview-tab-text")
    end

    test "a text version that is not a string is an error", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      send(view.pid, {:put, %{preview: fn _name, _locale -> {"S", "<p>H</p>", 42} end}})
      select(view, "order_offer")

      assert render(view) =~ "Preview unavailable: unexpected preview result"
    end
  end

  describe "conversion buttons" do
    test "are not shown without a convert callback, or read-only", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "order_offer")

      refute has_element?(view, "#editor-parts button[name=action][value=to_text]")
      refute has_element?(view, "#editor-parts button[name=action][value=md_to_html]")

      view = mount_editor(root, %{editable: false, convert: @convert})
      select(view, "order_offer")

      refute has_element?(view, "button[name=action]")
    end

    test "each shows only with its own callback", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: %{to_text: {Host, :to_text}}})
      select(view, "order_offer")

      assert has_element?(view, "#editor-parts button[name=action][value=to_text]")
      refute has_element?(view, "#editor-parts button[name=action][value=md_to_html]")
    end

    test "Save is the form's first submit button, so a submit naming none saves", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      [first | _rest] =
        view
        |> element("#editor-parts")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("button")
        |> Enum.to_list()

      assert LazyHTML.attribute(first, "type") == ["submit"]
      assert LazyHTML.attribute(first, "value") == ["save"]

      view
      |> form("#editor-parts", parts: %{subject: "Uus"})
      |> put_submitter("#editor-parts button[value=save]")
      |> render_submit()

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) == "Uus"
    end

    test "a submit with an unknown action neither saves nor converts", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      render_submit(with_target(view, "#editor"), "save", %{
        "action" => "publish",
        "parts" => %{"subject" => "x"}
      })

      assert File.read!(Path.join([root, "order_offer", "subject.et.txt"])) ==
               "Pakkumine {{order_number}}\n"
    end

    test "fill the text from Markdown, keeping the other unsaved fields", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      html =
        convert(view, "to_text", %{
          subject: "Unsaved subject",
          markdown: "**Tere** {{order_number}}",
          html: "<p>Ignored</p>"
        })

      assert html =~ "not saved yet"
      assert field(view, :text) == "Tere {{order_number}}"
      assert field(view, :subject) == "Unsaved subject"
      assert field(view, :markdown) == "**Tere** {{order_number}}"
      assert field(view, :html) == "<p>Ignored</p>"
      assert field(view, :label) == "Pakkumiskiri\n"

      dir = Path.join(root, "order_offer")
      assert File.read!(Path.join(dir, "text.et.txt")) == "Tere!\n\n{{documents_list}}\n"
      refute File.exists?(Path.join(dir, "markdown.et.md"))
      refute_received {:after_write, _paths}
      refute_received {:after_change, _name}
    end

    test "fill the text from HTML when there is no Markdown", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      convert(view, "to_text", %{markdown: "  \n", html: "<p>Tere <b>{{order_number}}</b></p>"})

      assert field(view, :text) == "Tere {{order_number}}"
    end

    test "Markdown to HTML fills the HTML field, keeping the rest", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      convert(view, "md_to_html", %{
        text: "Unsaved text",
        markdown: "**Pakkumine** {{order_number}}\n\n{{{raw_block}}}"
      })

      assert field(view, :html) ==
               "<p><strong>Pakkumine</strong> {{order_number}}\n\n{{{raw_block}}}</p>"

      assert field(view, :text) == "Unsaved text"
      refute File.exists?(Path.join([root, "order_offer", "html.et.html"]))
    end

    test "a conversion is sent to the page again over the user's retyping", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")
      convert(view, "md_to_html", %{markdown: "**Tere**"})

      # The user retypes only the HTML, then converts again: the form comes
      # out as the server already had it, yet the page must get it back. A
      # browser redraws each field the reply touches from what it holds for
      # it, the converted value; an empty reply leaves the retyped text.
      diff =
        reply_diff(view, fn ->
          convert(view, "md_to_html", %{markdown: "**Tere**", html: "<p>Retyped</p>"})
        end)

      assert diff =~ "data-form-rev"
      assert field(view, :html) == "<p><strong>Tere</strong></p>"
    end

    test "with nothing to convert says so and calls nothing", %{tmp_dir: root} do
      seed(root)
      test_pid = self()

      to_text = fn format, source ->
        send(test_pid, {:converted, format})
        source
      end

      markdown_to_html = fn markdown ->
        send(test_pid, {:converted, :markdown})
        markdown
      end

      view = mount_editor(root)
      send(view.pid, {:put, %{convert: %{to_text: to_text, markdown_to_html: markdown_to_html}}})
      select(view, "order_offer")

      assert convert(view, "to_text", %{markdown: "", html: " "}) =~ "Nothing to convert"
      assert convert(view, "md_to_html", %{markdown: ""}) =~ "Nothing to convert"
      refute_received {:converted, _format}
    end

    test "a save after a conversion writes only the changed parts", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      convert(view, "md_to_html", %{markdown: "**Tere**"})

      # Another session saves the subject meanwhile; the host re-renders.
      File.write!(Path.join([root, "order_offer", "subject.et.txt"]), "Teine sessioon\n")
      Overrides.reset_cache([root])
      send(view.pid, {:put, %{sample_variables: %{"order_number" => "38"}}})

      assert field(view, :html) == "<p><strong>Tere</strong></p>"
      assert field(view, :subject) == "Pakkumine {{order_number}}\n"

      html = save(view, %{})

      assert html =~ "Saved."
      dir = Path.join(root, "order_offer")
      assert File.read!(Path.join(dir, "html.et.html")) == "<p><strong>Tere</strong></p>"
      assert File.read!(Path.join(dir, "markdown.et.md")) == "**Tere**"
      assert File.read!(Path.join(dir, "subject.et.txt")) == "Teine sessioon\n"
      assert File.read!(Path.join(dir, "text.et.txt")) == "Tere!\n\n{{documents_list}}\n"
      assert_received {:after_write, paths}

      assert Enum.sort(paths) == [
               Path.join(dir, "html.et.html"),
               Path.join(dir, "markdown.et.md")
             ]

      # The form is drawn from the files again.
      assert field(view, :subject) == "Teine sessioon\n"
    end

    test "a converted part a save refuses stays in the form", %{tmp_dir: root} do
      seed(root)
      too_large = String.duplicate("x", Overrides.max_bytes() + 1)
      view = mount_editor(root)
      send(view.pid, {:put, %{convert: %{markdown_to_html: fn _markdown -> too_large end}}})
      select(view, "order_offer")
      convert(view, "md_to_html", %{markdown: "**Tere**"})

      assert save(view, %{subject: "Uus"}) =~ "Not saved: HTML: larger than 256 KiB"
      dir = Path.join(root, "order_offer")
      assert File.read!(Path.join(dir, "subject.et.txt")) == "Uus"
      refute File.exists?(Path.join(dir, "html.et.html"))
      assert field(view, :html) == too_large
      assert field(view, :subject) == "Uus"

      assert save(view, %{}) =~ "Not saved: HTML: larger than 256 KiB"
      assert field(view, :html) == too_large
    end

    test "converted values are dropped on another tab or template", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      convert(view, "to_text", %{markdown: "**Tere**"})
      tab(view, "ru")
      tab(view, "et")

      assert field(view, :text) == "Tere!\n\n{{documents_list}}\n"
      assert field(view, :markdown) == ""

      convert(view, "to_text", %{markdown: "**Tere**"})
      select(view, "_header-shop")
      select(view, "order_offer")

      assert field(view, :text) == "Tere!\n\n{{documents_list}}\n"
    end

    test "a failing converter is reported and logged, the fields unchanged",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: %{to_text: {Host, :failing_to_text}}})
      select(view, "order_offer")

      log =
        capture_log(fn ->
          assert convert(view, "to_text", %{markdown: "**Tere**"}) =~
                   "Not converted: converter down"
        end)

      assert log =~ "to_text"
      assert log =~ "failing_to_text/2"
      assert Process.alive?(view.pid)
      assert field(view, :text) == "Tere!\n\n{{documents_list}}\n"
    end

    test "a converter's refusal or odd result is an error, the field unchanged",
         %{tmp_dir: root} do
      seed(root)

      for {callback, message} <- [
            {:refusing_to_text, "Not converted: cannot convert this"},
            {:shapeless_to_text, "Not converted: unexpected result"},
            {:latin_to_text, "Not converted: unexpected result"}
          ] do
        view = mount_editor(root, %{convert: %{to_text: {Host, callback}}})
        select(view, "order_offer")

        html = convert(view, "to_text", %{markdown: "**Tere**"})

        assert html =~ message
        assert String.valid?(html)
        assert field(view, :text) == "Tere!\n\n{{documents_list}}\n"
      end
    end

    test "a field that is not UTF-8 is refused, nothing changed", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      # A form submit cannot carry it (Plug refuses the params); an event
      # payload sent by other means can.
      html =
        render_click(with_target(view, "#editor"), "save", %{
          "action" => "to_text",
          "parts" => %{"markdown" => <<"Tere ", 0xE4>>, "subject" => "Uus"}
        })

      assert html =~ "Not converted: not valid UTF-8 text"
      assert String.valid?(render(view))
      assert field(view, :text) == "Tere!\n\n{{documents_list}}\n"
      assert field(view, :subject) == "Pakkumine {{order_number}}\n"
    end

    test "a target part that is not UTF-8 on disk is not converted into",
         %{tmp_dir: root} do
      seed(root)
      latin = <<"Tere ", 0xE4, "\n">>
      put(root, "order_offer", "text.et.txt", latin)
      view = mount_editor(root, %{convert: @convert})
      select(view, "order_offer")

      html = convert(view, "to_text", %{markdown: "**Tere**"})

      assert html =~ "Not converted: Text"
      refute has_element?(view, "#editor-parts textarea[name='parts[text]']")
      save(view, %{})
      assert File.read!(Path.join([root, "order_offer", "text.et.txt"])) == latin
    end

    test "conversion events are refused read-only or without the callback",
         %{tmp_dir: root} do
      seed(root)
      test_pid = self()

      to_text = fn _format, _source ->
        send(test_pid, :converted)
        "x"
      end

      for opts <- [
            %{editable: false, convert: %{to_text: to_text}},
            %{convert: %{markdown_to_html: fn _md -> "x" end}},
            %{convert: %{to_text: fn _source -> "wrong arity" end}},
            %{convert: :yes}
          ] do
        view = mount_editor(root)
        send(view.pid, {:put, opts})
        select(view, "order_offer")

        render_submit(with_target(view, "#editor"), "save", %{
          "action" => "to_text",
          "parts" => %{"markdown" => "**Tere**"}
        })

        assert Process.alive?(view.pid)
        refute render(view) =~ "Not converted"
      end

      refute_received :converted
    end
  end
end
