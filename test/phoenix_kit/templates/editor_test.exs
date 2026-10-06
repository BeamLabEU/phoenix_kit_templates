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

    def preview("andi_order_broken", _locale), do: {:error, :boom}
    def preview("andi_order_timeout", _locale), do: exit(:timeout)
    def preview("andi_order_shapeless", _locale), do: %{subject: "S"}

    def preview("andi_order_safe", _locale) do
      {{:safe, ~s(<b id="pwned-subject">S</b>)},
       {:safe, ~s("></iframe><b id="pwned">x</b><iframe srcdoc=")}}
    end

    def preview(name, locale) do
      {"Subject of #{name} (#{locale})",
       "<p>Hello from #{name}</p><script>window.parent.alert(1)</script>"}
    end

    def failing_after_write(_paths), do: raise("chown failed")
  end

  defp put(root, name, file, content) do
    File.mkdir_p!(Path.join(root, name))
    File.write!(Path.join([root, name, file]), content)
  end

  defp seed(root) do
    put(root, "andi_order_offer", "label.et.txt", "Hinnapakkumine\n")
    put(root, "andi_order_offer", "label.en.txt", "Price offer\n")
    put(root, "andi_order_offer", "subject.et.txt", "Pakkumine {{order_number}}\n")
    put(root, "andi_order_offer", "text.et.txt", "Tere!\n\n{{documents_list}}\n")
    put(root, "andi_order_offer", "subject.ru.txt", "Предложение\n")
    put(root, "_header-andi", "html.html", "<p>ANDI</p>\n")
    put(root, "secret_other", "text.txt", "not for this editor\n")
  end

  defp mount_editor(root, opts \\ %{}) do
    opts =
      Map.merge(
        %{
          root: root,
          editable: true,
          name_prefixes: ["andi_order_", "_header-andi", "_footer-andi", "_layout-andi"],
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

  describe "the list" do
    test "shows only names under the prefixes, shared parts in their own group",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      html = render(view)

      assert has_element?(view, "#editor-messages [phx-value-name=andi_order_offer]")
      assert has_element?(view, "#editor-shared [phx-value-name=_header-andi]")
      refute has_element?(view, "#editor-messages [phx-value-name=_header-andi]")
      refute html =~ "secret_other"
    end

    test "captions a template with its label in the first locale", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      assert view |> element("[phx-value-name=andi_order_offer]") |> render() =~
               "Hinnapakkumine"

      view = mount_editor(root, %{locales: ["en", "et"]})
      assert view |> element("[phx-value-name=andi_order_offer]") |> render() =~ "Price offer"
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
        "create" => %{"name" => "andi_order_x", "copy_from" => ""}
      })

      assert Process.alive?(view.pid)
    end

    test "a label that is not UTF-8 is not used as the caption", %{tmp_dir: root} do
      put(root, "andi_order_latin", "label.et.txt", <<"Hinnapakkumine ", 0xE4>>)
      put(root, "andi_order_latin", "text.et.txt", "Tere")
      view = mount_editor(root)

      assert view |> element("[phx-value-name=andi_order_latin]") |> render() =~
               "andi_order_latin"

      assert String.valid?(render(view))
      refute render(view) =~ "Hinnapakkumine"
    end
  end

  describe "editing" do
    test "shows each part of the selected locale", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

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
      select(view, "_header-andi")

      assert view |> element("#editor-parts textarea[name='parts[html]']") |> render() =~
               "&lt;p&gt;ANDI&lt;/p&gt;"
    end

    test "saves changed parts to the selected locale and reports the paths",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")
      tab(view, "en")

      html = save(view, %{label: "Offer", subject: "Offer {{order_number}}", text: ""})

      assert html =~ "Saved"
      dir = Path.join(root, "andi_order_offer")
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
      select(view, "andi_order_offer")

      html = save(view, %{subject: "Pakkumine {{order_number}}\n", label: "Hinnapakkumine\n"})

      assert html =~ "No changes"
      refute_received {:after_write, _paths}
    end

    test "an emptied part deletes its file, so rendering falls back", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_offer", "subject.txt", "Fallback subject\n")
      view = mount_editor(root)
      select(view, "andi_order_offer")

      save(view, %{subject: ""})

      refute File.exists?(Path.join([root, "andi_order_offer", "subject.et.txt"]))

      assert Templates.render("andi_order_offer", %{}, %{}, locale: "et", paths: [root]).subject ==
               "Fallback subject"
    end

    test "stores browser CRLF line breaks as LF", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      save(view, %{text: "Tere!\r\n\r\nNägemist\r\n"})

      assert File.read!(Path.join([root, "andi_order_offer", "text.et.txt"])) ==
               "Tere!\n\nNägemist\n"
    end

    test "surfaces a refusal from the write API", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      html = save(view, %{html: String.duplicate("a", Overrides.max_bytes() + 1)})

      assert html =~ "larger than"
      refute File.exists?(Path.join([root, "andi_order_offer", "html.et.html"]))
      refute_received {:after_write, _paths}
    end

    test "a failing after_write is reported and logged, not a crash", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{after_write: {Host, :failing_after_write}})
      select(view, "andi_order_offer")

      log = capture_log(fn -> assert save(view, %{subject: "Uus"}) =~ "chown failed" end)

      path = Path.join([root, "andi_order_offer", "subject.et.txt"])
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
      select(view, "andi_order_offer")
      tab(view, "e")

      html = save(view, %{subject: "Uus"})

      assert html =~ "Subject: not a valid language tag"
      refute html =~ "POSIX"
    end

    test "a preview right after saving shows the saved content", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: :render})
      select(view, "andi_order_offer")

      assert view |> element("#editor-preview-subject") |> render() =~
               "Pakkumine {{order_number}}"

      save(view, %{subject: "Uus pealkiri"})

      assert view |> element("#editor-preview-subject") |> render() =~ "Uus pealkiri"
    end

    test "a part file that is not UTF-8 is shown read-only and never overwritten",
         %{tmp_dir: root} do
      seed(root)
      latin = <<"Tere ", 0xE4, "\n">>
      put(root, "andi_order_offer", "text.et.txt", latin)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      assert String.valid?(render(view))
      assert view |> element("#editor-part-text-invalid") |> render() =~ "not valid UTF-8"
      refute has_element?(view, "#editor-parts textarea[name='parts[text]']")

      save(view, %{subject: "Uus"})
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"text" => ""}})

      assert File.read!(Path.join([root, "andi_order_offer", "subject.et.txt"])) == "Uus"
      assert File.read!(Path.join([root, "andi_order_offer", "text.et.txt"])) == latin
    end

    test "a part file that is not UTF-8 is flagged in read-only mode too", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_offer", "text.et.txt", <<"Tere ", 0xE4>>)
      view = mount_editor(root, %{editable: false})
      select(view, "andi_order_offer")

      assert String.valid?(render(view))
      assert render(view) =~ "not valid UTF-8"
    end

    test "flags placeholders the sample variables do not know", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")
      refute has_element?(view, "#editor-missing")

      save(view, %{text: "Tere {{order_numbr}}"})

      assert view |> element("#editor-missing") |> render() =~ "order_numbr"
    end
  end

  describe "creating" do
    test "an empty template exists once its first part is saved", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "andi_order_new", copy_from: ""})
      |> render_submit()

      refute File.exists?(Path.join(root, "andi_order_new"))

      save(view, %{subject: "Uus"})

      dir = Path.join(root, "andi_order_new")
      assert File.read!(Path.join(dir, "subject.et.txt")) == "Uus"
      assert_received {:after_write, [^dir, _file]}
      assert has_element?(view, "#editor-messages [phx-value-name=andi_order_new]")
    end

    test "a copy duplicates every part file of the source", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "andi_order_copy", copy_from: "andi_order_offer"})
      |> render_submit()

      source = Path.join(root, "andi_order_offer")
      copy = Path.join(root, "andi_order_copy")
      assert File.ls!(copy) |> Enum.sort() == File.ls!(source) |> Enum.sort()

      assert File.read!(Path.join(copy, "text.et.txt")) ==
               File.read!(Path.join(source, "text.et.txt"))

      assert_received {:after_write, [^copy | files]}
      assert length(files) == length(File.ls!(source))
    end

    test "a copy takes the host's own files beside the parts along", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_offer", "audience.txt", "partner\n")
      view = mount_editor(root)

      create(view, "andi_order_copy", "andi_order_offer")

      copy = Path.join(root, "andi_order_copy")
      assert File.read!(Path.join(copy, "audience.txt")) == "partner\n"
      assert_received {:after_write, [^copy | files]}
      assert Path.join(copy, "audience.txt") in files
    end

    test "a copy whose source is gone says so", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      html =
        render_submit(with_target(view, "#editor"), "create", %{
          "create" => %{"name" => "andi_order_x", "copy_from" => "andi_order_gone"}
        })

      assert html =~ "There is no “andi_order_gone” to copy."
      refute File.exists?(Path.join(root, "andi_order_x"))
    end

    test "a copy refused by the write API leaves nothing and says why", %{tmp_dir: root} do
      seed(root)
      big = String.duplicate("a", Overrides.max_bytes() + 1)
      put(root, "andi_order_offer", "html.et.html", big)
      view = mount_editor(root)

      html = create(view, "andi_order_copy", "andi_order_offer")

      assert html =~ "Not copied: larger than"
      refute File.exists?(Path.join(root, "andi_order_copy"))
      refute_received {:after_write, _paths}
    end

    test "refuses a bad name, a name outside the prefixes and an existing name",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      for {name, message} <- [
            {"andi_order_Bad.Name", "not a valid"},
            {"other_thing", "not allowed"},
            {"andi_order_offer", "already exists"}
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
      File.mkdir_p!(Path.join(root, "andi_order_empty"))
      view = mount_editor(root)

      view
      |> form("#editor-create", create: %{name: "andi_order_copy", copy_from: "andi_order_empty"})
      |> render_submit()

      copy = Path.join(root, "andi_order_copy")
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
      create(view, "andi_order_new")

      assert render(view) =~ "not saved yet"
      assert view |> element("#editor-preview") |> render() =~ "Save the template to preview it."

      refute Enum.any?(:persistent_term.get(), fn
               {{Overrides, :located, [^root], "andi_order_new", _part, _locale}, _} -> true
               _other -> false
             end)
    end

    test "a draft cannot be the source of a copy", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "andi_order_draft")

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => "andi_order_copy", "copy_from" => "andi_order_draft"}
      })

      assert Process.alive?(view.pid)
      refute File.exists?(Path.join(root, "andi_order_copy"))
    end

    test "a draft another session saved meanwhile is no longer a draft", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      create(view, "andi_order_new")

      put(root, "andi_order_new", "subject.et.txt", "From elsewhere")
      send(view.pid, {:put, %{sample_variables: %{"order_number" => "38"}}})

      refute render(view) =~ "not saved yet"
      view |> element("#editor-delete") |> render_click()
      view |> element("#editor-delete-confirm") |> render_click()
      refute File.exists?(Path.join(root, "andi_order_new"))
    end

    test "a malformed create event is ignored", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      render_submit(with_target(view, "#editor"), "create", %{
        "create" => %{"name" => ["andi_order_x"], "copy_from" => ""}
      })

      assert has_element?(view, "#editor-create")
    end

    test "cannot copy a template outside the prefixes", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)

      view
      |> with_target("#editor")
      |> render_submit("create", %{
        "create" => %{"name" => "andi_order_x", "copy_from" => "secret_other"}
      })

      refute File.exists?(Path.join(root, "andi_order_x"))
    end
  end

  describe "deleting" do
    test "asks for confirmation first", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      view |> element("#editor-delete") |> render_click()
      assert File.dir?(Path.join(root, "andi_order_offer"))
      view |> element("#editor-delete-cancel") |> render_click()
      refute has_element?(view, "#editor-delete-confirm")

      view |> element("#editor-delete") |> render_click()
      view |> element("#editor-delete-confirm") |> render_click()

      refute File.exists?(Path.join(root, "andi_order_offer"))
      refute has_element?(view, "[phx-value-name=andi_order_offer]")
    end
  end

  describe "preview" do
    test "shows the host's HTML in a sandboxed iframe that cannot run scripts",
         %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      assert view |> element("#editor-preview-subject") |> render() =~
               "Subject of andi_order_offer (et)"

      iframe = view |> element("#editor-preview iframe") |> render()
      assert iframe =~ ~s(sandbox="")
      refute iframe =~ "allow-scripts"
      assert iframe =~ "Hello from andi_order_offer"

      tab(view, "ru")
      assert render(view) =~ "Subject of andi_order_offer (ru)"
    end

    test "shows a host error instead of a preview, in the host's words", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_broken", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "andi_order_broken")

      assert view |> element("#editor-preview [role=alert]") |> render() =~
               "Preview unavailable: boom"

      refute render(view) =~ "POSIX"
      refute has_element?(view, "#editor-preview iframe")
    end

    test "shows a host exit instead of a preview, and logs it", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_timeout", "text.et.txt", "x")
      view = mount_editor(root)

      log = capture_log(fn -> select(view, "andi_order_timeout") end)

      assert render(view) =~ "Preview unavailable"
      assert log =~ "preview"
      assert log =~ "timeout"
      assert log =~ "Host.preview/2"
    end

    test "escapes safe tuples from the host instead of trusting them", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_safe", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "andi_order_safe")

      refute has_element?(view, "#pwned")
      refute has_element?(view, "#pwned-subject")
      assert view |> element("#editor-preview iframe") |> render() =~ "pwned"
      assert view |> element("#editor-preview-subject") |> render() =~ "pwned-subject"
    end

    test "shows a result of the wrong shape as an error, not a crash", %{tmp_dir: root} do
      seed(root)
      put(root, "andi_order_shapeless", "text.et.txt", "x")
      view = mount_editor(root)
      select(view, "andi_order_shapeless")

      assert render(view) =~ "Preview unavailable: unexpected preview result"
      assert Process.alive?(view.pid)
    end

    test "follows a new preview callback from the host", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      send(view.pid, {:put, %{preview: fn name, _locale -> {"New look of #{name}", nil} end}})

      assert view |> element("#editor-preview-subject") |> render() =~
               "New look of andi_order_offer"
    end

    test "an unrelated re-render does not call the preview again", %{tmp_dir: root} do
      seed(root)
      test_pid = self()
      view = mount_editor(root)
      select(view, "andi_order_offer")

      counting = fn name, locale ->
        send(test_pid, {:previewed, name})
        Host.preview(name, locale)
      end

      send(view.pid, {:put, %{preview: counting}})
      render(view)
      assert_received {:previewed, "andi_order_offer"}

      send(view.pid, {:put, %{tick: 1}})
      render(view)

      refute_received {:previewed, _name}
    end

    test "shows a file another session changed on the next update", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: :render})
      select(view, "andi_order_offer")

      {:ok, _} = Overrides.write(root, "andi_order_offer", :subject, "et", "From elsewhere")
      send(view.pid, {:put, %{tick: 1}})

      assert view |> element("#editor-preview-subject") |> render() =~ "From elsewhere"
    end

    test "no preview pane without a preview callback", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{preview: nil})
      select(view, "andi_order_offer")

      refute has_element?(view, "#editor-preview")
    end
  end

  describe "read-only" do
    test "shows the content with no way to change it", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{editable: false})
      select(view, "andi_order_offer")

      assert render(view) =~ "Pakkumine {{order_number}}"
      refute has_element?(view, "#editor-parts")
      refute has_element?(view, "#editor-create")
      refute has_element?(view, "#editor-delete")
      assert has_element?(view, "#editor-preview iframe")
    end

    test "refuses write events sent anyway", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root, %{editable: false})
      select(view, "andi_order_offer")
      target = with_target(view, "#editor")

      render_submit(target, "save", %{"parts" => %{"subject" => "hacked"}})

      render_submit(target, "create", %{
        "create" => %{"name" => "andi_order_x", "copy_from" => ""}
      })

      render_click(target, "delete", %{})
      render_click(target, "confirm_delete", %{})

      assert File.read!(Path.join([root, "andi_order_offer", "subject.et.txt"])) ==
               "Pakkumine {{order_number}}\n"

      refute File.exists?(Path.join(root, "andi_order_x"))
      refute_received {:after_write, _paths}
    end

    test "turning editable off on a live editor takes effect", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")
      assert has_element?(view, "#editor-parts")

      send(view.pid, {:put, %{editable: false}})

      refute has_element?(view, "#editor-parts")
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"subject" => "x"}})
      assert File.read!(Path.join([root, "andi_order_offer", "subject.et.txt"])) =~ "Pakkumine"
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
      create(view, "andi_order_new")

      send(view.pid, {:put, %{name_prefixes: ["zzz_"]}})
      render_submit(with_target(view, "#editor"), "save", %{"parts" => %{"text" => "x"}})

      refute File.exists?(Path.join(root, "andi_order_new"))
      refute render(view) =~ "andi_order_new"
    end

    test "an unknown locale is not a tab", %{tmp_dir: root} do
      seed(root)
      view = mount_editor(root)
      select(view, "andi_order_offer")

      render_click(with_target(view, "#editor"), "locale", %{"locale" => "de"})
      save(view, %{subject: "x"})

      refute File.exists?(Path.join([root, "andi_order_offer", "subject.de.txt"]))
      assert File.read!(Path.join([root, "andi_order_offer", "subject.et.txt"])) == "x"
    end
  end
end
