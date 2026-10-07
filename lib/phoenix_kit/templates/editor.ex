if Code.ensure_loaded?(Phoenix.LiveComponent) do
  defmodule PhoenixKit.Templates.Editor do
    @moduledoc """
    A `Phoenix.LiveComponent` for editing a host's override files in place.

    Compiled only when the host has `phoenix_live_view`, which this package
    lists as an optional dependency: a host without it gets the renderer and
    the write API and none of this. It depends on nothing else — no PhoenixKit,
    no Gettext backend, no host assets. The markup is HEEx with daisyUI class
    names, so a Tailwind host must scan this package's `lib/` for them.

        <.live_component
          module={PhoenixKit.Templates.Editor}
          id="email-templates"
          root={MyApp.EmailTemplates.root()}
          editable={true}
          name_prefixes={["order_", "_header-shop", "_footer-shop"]}
          locales={["et", "ru", "en"]}
          preview={{MyApp.EmailPreview, :preview}}
          sample_variables={%{"order_number" => "37"}}
          after_write={{MyApp.EmailTemplates, :after_write}}
        />

    Everything is read and written through `PhoenixKit.Templates.Overrides`
    on the one `root`, so the renderer's cache is reset for that root after
    every change — pass the same root string the host renders with.

    ## Attributes

      * `:root` (required) — the host's template directory. Anything but a
        string shows an error and nothing can be written. Keep it fixed for
        the life of the page: the open form's notion of what the user left
        alone belongs to the root it was opened from.
      * `:editable` — `true` to allow saving, creating and deleting; anything
        else shows the files read-only. Default `false`. Checked again by every
        event, not only by what is rendered.
      * `:name_prefixes` — which templates this editor sees **and** may write
        or delete: names starting with one of these strings. Checked on every
        select, save, create, copy and delete. Anything but a list counts as
        `[]`, and entries that are not non-empty strings are dropped. Default
        `[]`, which shows nothing.
      * `:locales` — the language tabs, in order; anything but a list of
        non-empty strings is cleaned the way `:name_prefixes` is. A last tab, *Fallback*, edits
        the locale-less files (`text.txt`), used for any language without its
        own file.
      * `:preview` — `{module, function}` or a 2-arity function called as
        `preview(name, locale)` (`locale` is `nil` on the fallback tab, and
        `name` may be a shared part such as `_header-x`). It returns
        `{subject, html}` — each a string or `nil` — or `{:error, reason}`.
        The HTML is shown in an `<iframe sandbox srcdoc>` without
        `allow-scripts`, so nothing in an edited template runs in the admin
        page; a `{:safe, iodata}` is escaped like a string, never trusted.
        Any other result, an exception, throw or exit is shown as an error
        rather than crashing the page, and the last three are logged. It is
        called on selecting a template or tab, after a save or copy, and when
        the host re-renders with a new callback, new variables or changed
        files — not for a template with no files yet. No callback, no preview
        pane.
      * `:sample_variables` — the variables a template may use, as a map of
        name to a sample value. Listed beside the editor, and any placeholder
        in the current template that is not among them is flagged. The one map
        applies to every template, shared parts included, so a host whose
        headers and footers use its layout's variables (`{{site_url}}` and
        the like) lists those too.
      * `:after_write` — `{module, function}` or a 1-arity function, called
        with the list of paths created by a save or a copy (a new template
        directory first, then files) — for example to change their owner.
        This package never does. The files are written before it is called;
        if it raises, throws or exits, that is shown as an error after the
        save's own result and logged with its stacktrace.
      * `:after_change` — `{module, function}` or a 1-arity function, called
        with the template's name after any change on disk: a save that wrote
        or deleted files, a copy (the new name) or a deleted template — for
        example to refresh what the host shows about the files. Not called
        when nothing changed. Reported and logged like `:after_write`.

    ## What it does

      * Lists the visible templates, captioned with their `label` part, with
        names starting with `_` (headers, footers, layouts) in a group of
        their own.
      * Edits the `label`, `subject`, `text`, `markdown` and `html` parts per
        language tab. Saving writes the parts that changed; a part saved empty
        has its file deleted, so the message falls back to the next file in
        line — and a template left with no files loses its directory, staying
        open as an unsaved one. Line breaks are stored as `\\n`. A save that
        is partly refused (one part too large, say) names the parts it saved
        and the ones it did not, and what was typed into those stays in the
        form to be fixed and saved again. Each tab is saved on its own: switching tabs
        or templates, or a reconnect, drops unsaved changes.
      * A part is written only when the user changed it from what the form
        was given (on opening the template or tab, or after a save): a part
        left alone is never written back over another session's change made
        meanwhile. An edited part wins — the last save of it, with no check
        that another session changed the file since.
      * The host's callbacks (`preview`, `after_write`, `after_change`) run in
        the LiveView's process and block the page while they run: keep them
        fast.
      * Creates a template empty (it exists on disk once its first part is
        saved) or as a copy of a listed one — every file in its directory,
        including any of the host's own beside the parts
        (`Overrides.copy_template/3`).
      * A file that is not UTF-8 is shown as such, read-only, and never
        written over: fix it on disk.
      * Deletes a template, after a confirmation.

    The interface text is plain English: a host Gettext backend cannot be
    reached from here, and messages passed through one at runtime would never
    be extracted.
    """
    use Phoenix.LiveComponent

    require Logger

    alias PhoenixKit.Templates
    alias PhoenixKit.Templates.Overrides

    @parts [:label, :subject, :text, :markdown, :html]

    @part_titles %{
      label: "Label",
      subject: "Subject",
      text: "Text",
      markdown: "Markdown",
      html: "HTML"
    }

    @part_hints %{
      label: "The caption in lists. Never sent.",
      subject: "One line.",
      text: "The plain-text body.",
      markdown: "Optional, an alternative to HTML.",
      html: "Optional."
    }

    @part_rows %{label: 1, subject: 2, text: 10, markdown: 6, html: 10}

    @impl true
    def mount(socket) do
      {:ok,
       assign(socket,
         editable: false,
         name_prefixes: [],
         locales: [],
         preview: nil,
         sample_variables: %{},
         after_write: nil,
         after_change: nil,
         templates: [],
         selected: nil,
         draft?: false,
         locale: nil,
         contents: %{},
         baseline: %{},
         retained: %{},
         confirm_delete?: false,
         preview_result: nil,
         missing: [],
         notice: nil
       )}
    end

    @impl true
    def update(assigns, socket) do
      previous_files = files_of(socket, socket.assigns.selected)
      socket = socket |> assign(assigns) |> sanitize_options()

      socket =
        if editable?(socket.assigns), do: socket, else: assign(socket, confirm_delete?: false)

      socket = socket |> load_templates() |> settle_draft() |> keep_selection()
      {:ok, refresh_preview(socket, previous_files)}
    end

    @impl true
    def handle_event("select", %{"name" => name}, socket) do
      if visible?(socket, name) do
        draft? = socket.assigns.draft? and name == socket.assigns.selected
        {:noreply, socket |> assign(notice: nil, draft?: draft?) |> select(name)}
      else
        {:noreply, socket}
      end
    end

    def handle_event("locale", %{"locale" => locale}, socket) do
      locale = if locale == "", do: nil, else: locale

      if socket.assigns.selected && locale in tabs(socket.assigns) do
        {:noreply, socket |> assign(locale: locale, notice: nil) |> load_contents() |> preview()}
      else
        {:noreply, socket}
      end
    end

    def handle_event("save", %{"parts" => parts}, socket) when is_map(parts) do
      if writable?(socket, socket.assigns.selected) do
        {:noreply, save(socket, parts)}
      else
        {:noreply, socket}
      end
    end

    def handle_event("create", %{"create" => %{"name" => name} = params}, socket)
        when is_binary(name) do
      case Map.get(params, "copy_from", "") do
        copy_from when is_binary(copy_from) ->
          if editable?(socket.assigns) do
            {:noreply, create(socket, String.trim(name), copy_from)}
          else
            {:noreply, socket}
          end

        _malformed ->
          {:noreply, socket}
      end
    end

    def handle_event("delete", _params, socket) do
      {:noreply,
       assign(socket, confirm_delete?: writable?(socket, socket.assigns.selected), notice: nil)}
    end

    def handle_event("cancel_delete", _params, socket) do
      {:noreply, assign(socket, confirm_delete?: false)}
    end

    def handle_event("confirm_delete", _params, socket) do
      if socket.assigns.confirm_delete? and writable?(socket, socket.assigns.selected) do
        {:noreply, delete(socket)}
      else
        {:noreply, assign(socket, confirm_delete?: false)}
      end
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}

    ## Actions

    defp select(socket, name) do
      socket
      |> assign(selected: name, confirm_delete?: false)
      |> assign(locale: initial_locale(socket, name))
      |> load_contents()
      |> preview()
    end

    defp save(socket, params) do
      %{root: root, selected: name, locale: locale, contents: contents, baseline: baseline} =
        socket.assigns

      results =
        Enum.flat_map(@parts, fn part ->
          with value when is_binary(value) <- params[Atom.to_string(part)],
               value = normalize_newlines(value),
               # Left as the form was given it: another session's change to
               # this part since then must not be written back over.
               false <- value == Map.get(baseline, part, ""),
               {:ok, change} <- change(Map.get(contents, part), value) do
            [{part, apply_change(change, root, name, part, locale)}]
          else
            _unchanged -> []
          end
        end)

      paths = for {_part, {:ok, paths}} <- results, path <- paths, do: path
      saved = for {part, {:ok, _paths}} <- results, do: part
      errors = for {part, {:error, reason}} <- results, do: {part, reason}

      # What the user typed into a part that was refused: kept in the form, not
      # replaced by what is on disk, so the edit can be fixed and saved again.
      retained =
        for {part, _reason} <- errors,
            into: %{},
            do: {part, normalize_newlines(params[Atom.to_string(part)])}

      notified =
        socket
        |> notify_written(paths)
        |> then_notify_changed(socket, if(saved == [], do: nil, else: name))

      socket
      |> assign(notice: with_notified(save_notice(saved, errors), notified))
      |> load_templates()
      |> redraft()
      |> load_contents()
      |> assign(retained: retained)
      |> preview()
    end

    defp save_notice([], []), do: {:info, "No changes."}
    defp save_notice(_saved, []), do: {:info, "Saved."}
    defp save_notice([], errors), do: {:error, "Not saved: " <> describe_errors(errors)}

    # Some files did change: saying only "Not saved" would hide that.
    defp save_notice(saved, errors) do
      {:error,
       "Saved: " <>
         Enum.map_join(saved, ", ", &part_title/1) <>
         ". Not saved: " <> describe_errors(errors)}
    end

    defp change(%{invalid: true}, _value), do: :none
    defp change(nil, ""), do: :none
    defp change(_file, ""), do: {:ok, :delete}
    defp change(nil, value), do: {:ok, {:write, value}}

    defp change(%{content: content}, value) do
      if normalize_newlines(content) == value, do: :none, else: {:ok, {:write, value}}
    end

    defp apply_change(:delete, root, name, part, locale) do
      case Overrides.delete(root, name, part, locale) do
        :ok -> {:ok, []}
        error -> error
      end
    end

    defp apply_change({:write, value}, root, name, part, locale) do
      Overrides.write(root, name, part, locale, value)
    end

    defp create(socket, name, copy_from) do
      cond do
        not Overrides.valid_name?(name) ->
          notice(
            socket,
            :error,
            "“#{name}” is not a valid template name: use lowercase letters, digits, " <>
              "“_” and “-”, with at most one leading “_”."
          )

        not allowed?(socket, name) ->
          notice(
            socket,
            :error,
            "“#{name}” is not allowed here: names must start with " <>
              Enum.map_join(socket.assigns.name_prefixes, ", ", &"“#{&1}”") <> "."
          )

        File.exists?(Path.join(socket.assigns.root, name)) ->
          notice(socket, :error, "“#{name}” already exists.")

        copy_from == "" ->
          socket |> assign(notice: nil, draft?: true) |> select(name)

        # Only a template on disk can be copied; a draft has no directory.
        exists?(socket, copy_from) ->
          copy(socket, copy_from, name)

        true ->
          notice(socket, :error, "There is no “#{copy_from}” to copy.")
      end
    end

    # The whole directory, not just the parts this editor shows: a host's own
    # files beside them (who a message is for, say) belong to the template.
    defp copy(socket, from, name) do
      case Overrides.copy_template(socket.assigns.root, from, name) do
        {:ok, paths} ->
          notified =
            socket |> notify_written(paths) |> then_notify_changed(socket, name)

          notice = {:info, "Created “#{name}” as a copy of “#{from}”."}

          socket
          |> assign(notice: with_notified(notice, notified), draft?: false)
          |> load_templates()
          |> select(name)

        {:error, reason} ->
          notice(socket, :error, "Not copied: " <> describe(reason))
      end
    end

    defp delete(socket) do
      %{root: root, selected: name} = socket.assigns

      result = if socket.assigns.draft?, do: :ok, else: Overrides.delete_template(root, name)

      notice =
        case result do
          :ok ->
            changed = if socket.assigns.draft?, do: nil, else: name
            with_notified({:info, "Deleted “#{name}”."}, notify_changed(socket, changed))

          {:error, reason} ->
            {:error, "Not deleted: " <> describe(reason)}
        end

      socket = socket |> assign(notice: notice, confirm_delete?: false) |> load_templates()
      if result == :ok, do: deselect(socket), else: keep_selection(socket)
    end

    ## State

    defp load_templates(socket) do
      templates =
        for %{name: name, files: files} <- Overrides.list(socket.assigns.root),
            allowed?(socket, name) do
          %{name: name, files: files, caption: caption(socket, name, files)}
        end

      assign(socket, templates: templates)
    end

    # A parent re-render, a deletion or a change of prefixes may leave the
    # selection pointing at something this editor can no longer show.
    defp keep_selection(%{assigns: %{selected: nil}} = socket), do: socket

    defp keep_selection(socket) do
      if visible?(socket, socket.assigns.selected) do
        if socket.assigns.locale in tabs(socket.assigns),
          do: refresh_contents(socket),
          else: socket |> reset_locale() |> load_contents()
      else
        deselect(socket)
      end
    end

    # A parent re-render calls the host's preview again only when something it
    # depends on changed: the callback or variables, the tab, or the files —
    # another session may have saved them.
    defp refresh_preview(%{assigns: %{selected: nil}} = socket, _previous_files), do: socket

    defp refresh_preview(socket, previous_files) do
      if files_of(socket, socket.assigns.selected) != previous_files or
           Enum.any?(
             [:root, :preview, :sample_variables, :locale, :contents],
             &changed?(socket, &1)
           ) do
        preview(socket)
      else
        socket
      end
    end

    # A draft that now exists on disk — saved here, or by another session — is
    # an ordinary template again, so deleting it deletes its directory.
    defp settle_draft(socket) do
      assign(socket,
        draft?: socket.assigns.draft? and not exists?(socket, socket.assigns.selected)
      )
    end

    # After a save the template is a draft exactly when it has no directory:
    # a first save makes it an ordinary template, and emptying its last file
    # (`Overrides.delete/4` removes the directory with it) makes it a draft
    # again, still selected and still writable.
    defp redraft(socket) do
      assign(socket, draft?: not exists?(socket, socket.assigns.selected))
    end

    defp reset_locale(socket),
      do: assign(socket, locale: initial_locale(socket, socket.assigns.selected))

    defp deselect(socket) do
      assign(socket,
        selected: nil,
        draft?: false,
        contents: %{},
        baseline: %{},
        retained: %{},
        preview_result: nil,
        missing: [],
        confirm_delete?: false
      )
    end

    # What the form is drawn from. `baseline` is what the form was last given
    # for this template and tab (on select, a tab switch or a save); a parent
    # re-render refreshes `contents` from disk but keeps it, so `save/2` can
    # tell a part the user left alone from one they edited. `retained` holds
    # the text of parts a save refused; it lasts until the next load.
    defp load_contents(socket) do
      socket = refresh_contents(socket)
      assign(socket, baseline: baseline(socket.assigns.contents), retained: %{})
    end

    defp refresh_contents(socket) do
      %{selected: name, locale: locale} = socket.assigns

      contents =
        for %{part: part, locale: ^locale, path: path, mtime: mtime} <- files_of(socket, name),
            part in @parts,
            {:ok, content} <- [File.read(path)],
            into: %{},
            do: {part, file_contents(content, mtime)}

      socket |> assign(contents: contents) |> load_missing()
    end

    defp baseline(contents) do
      for {part, %{content: content}} <- contents,
          into: %{},
          do: {part, normalize_newlines(content)}
    end

    # A file put on disk by hand may not be UTF-8, which the page cannot carry:
    # such a part is shown as broken and is never written over from here.
    defp file_contents(content, mtime) do
      if String.valid?(content),
        do: %{content: content, mtime: mtime},
        else: %{invalid: true, mtime: mtime}
    end

    defp load_missing(socket) do
      %{root: root, selected: name, locale: locale, sample_variables: variables} = socket.assigns

      # A template with no files (a draft) has nothing to check, and looking it
      # up would leave cache entries behind for a name that may never be saved.
      if variables == %{} or files_of(socket, name) == [] do
        assign(socket, missing: [])
      else
        assign(socket, missing: missing_variables(name, variables, locale, root))
      end
    end

    defp missing_variables(name, variables, locale, root) do
      name
      |> Templates.missing_variables(%{}, variables, locale: locale, paths: [root])
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp preview(%{assigns: %{preview: nil}} = socket), do: assign(socket, preview_result: nil)

    defp preview(socket) do
      %{preview: callback, selected: name, locale: locale} = socket.assigns

      # A template with no files (a draft) has nothing to show, and rendering
      # it would leave cache entries behind for a name that may never be saved.
      result =
        if files_of(socket, name) == [] do
          :unsaved
        else
          safely({"preview", callback, [name, locale]}, fn ->
            callback |> call([name, locale]) |> preview_result()
          end)
        end

      assign(socket, preview_result: result)
    end

    # Only text is trusted into the page: `{:safe, iodata}` is turned back into
    # a string so it is escaped like any other — inside `srcdoc` a raw one
    # would break out of the attribute and the sandbox.
    defp preview_result({:error, reason}), do: {:error, describe_host(reason)}

    defp preview_result({subject, html}) do
      with {:ok, subject} <- preview_text(subject),
           {:ok, html} <- preview_text(html) do
        {:ok, subject, html}
      else
        :error -> {:error, "unexpected preview result"}
      end
    end

    defp preview_result(_other), do: {:error, "unexpected preview result"}

    defp preview_text(nil), do: {:ok, nil}

    defp preview_text({:safe, _iodata} = safe),
      do: preview_text(Phoenix.HTML.safe_to_string(safe))

    defp preview_text(text) when is_binary(text) do
      if String.valid?(text), do: {:ok, text}, else: :error
    end

    defp preview_text(_other), do: :error

    # The files are written by now, whatever the host's callback does with them.
    defp notify_written(_socket, []), do: :ok
    defp notify_written(%{assigns: %{after_write: nil}}, _paths), do: :ok

    defp notify_written(socket, paths) do
      callback = socket.assigns.after_write

      safely({"after_write", callback, [paths]}, fn ->
        call(callback, [paths])
        :ok
      end)
      |> tag_failure("after_write")
    end

    defp notify_changed(_socket, nil), do: :ok
    defp notify_changed(%{assigns: %{after_change: nil}}, _name), do: :ok

    defp notify_changed(socket, name) do
      callback = socket.assigns.after_change

      safely({"after_change", callback, [name]}, fn ->
        call(callback, [name])
        :ok
      end)
      |> tag_failure("after_change")
    end

    defp tag_failure(:ok, _role), do: :ok
    defp tag_failure({:error, reason}, role), do: {:error, {role, reason}}

    # Both callbacks run even when the first fails; the notice reports the
    # first failure, and every failure is logged (`safely/2`).
    defp then_notify_changed(:ok, socket, name), do: notify_changed(socket, name)

    defp then_notify_changed(written_error, socket, name) do
      notify_changed(socket, name)
      written_error
    end

    defp with_notified(notice, :ok), do: notice

    defp with_notified({_kind, message}, {:error, {role, reason}}),
      do: {:error, message <> " But the host's #{role} failed: " <> reason}

    # A host callback that raises, throws or exits is reported, not a crash —
    # and logged with its stacktrace, since the notice is gone with the page.
    defp safely(context, fun) do
      fun.()
    rescue
      exception ->
        log_failure(context, :error, exception, __STACKTRACE__)
        {:error, Exception.message(exception)}
    catch
      kind, reason ->
        log_failure(context, kind, reason, __STACKTRACE__)
        {:error, Exception.format_banner(kind, reason)}
    end

    defp log_failure({role, callback, args}, kind, reason, stacktrace) do
      Logger.error(
        "#{inspect(__MODULE__)}: the host's #{role} callback " <>
          "#{describe_callback(callback, length(args))} " <>
          "failed for #{inspect(args)}:\n" <> Exception.format(kind, reason, stacktrace)
      )
    end

    defp describe_callback({module, function}, arity),
      do: Exception.format_mfa(module, function, arity)

    defp describe_callback(fun, _arity), do: inspect(fun)

    defp call({module, function}, args), do: apply(module, function, args)
    defp call(fun, args) when is_function(fun, length(args)), do: apply(fun, args)

    defp notice(socket, kind, message), do: assign(socket, notice: {kind, message})

    ## Queries

    # With no usable root there is nothing to write to, whatever the host says.
    defp editable?(assigns), do: assigns.editable == true and is_binary(assigns.root)

    defp allowed?(socket, name) do
      is_binary(name) and String.starts_with?(name, socket.assigns.name_prefixes)
    end

    # A host's mistake (no list, an empty prefix that would match every name)
    # allows nothing rather than everything, or a crash. The same goes for
    # `locales` and `sample_variables`, which the page would otherwise crash on.
    defp sanitize_options(socket) do
      %{name_prefixes: prefixes, locales: locales, sample_variables: variables} =
        socket.assigns

      assign(socket,
        name_prefixes: non_empty_strings(prefixes),
        locales: locales |> non_empty_strings() |> Enum.uniq(),
        sample_variables: if(is_map(variables), do: variables, else: %{})
      )
    end

    defp non_empty_strings(list) when is_list(list),
      do: Enum.filter(list, &(is_binary(&1) and &1 != ""))

    defp non_empty_strings(_other), do: []

    defp writable?(socket, name), do: editable?(socket.assigns) and visible?(socket, name)

    # Listed templates are already filtered by prefix; a draft is checked here,
    # since the host may have changed the prefixes since it was created.
    defp visible?(socket, name) do
      exists?(socket, name) or
        (socket.assigns.draft? and name == socket.assigns.selected and allowed?(socket, name))
    end

    defp exists?(socket, name), do: Enum.any?(socket.assigns.templates, &(&1.name == name))

    defp files_of(socket, name) do
      case Enum.find(socket.assigns.templates, &(&1.name == name)) do
        %{files: files} -> files
        nil -> []
      end
    end

    defp tabs(assigns), do: assigns.locales ++ [nil]

    # The first tab that has a file, so a locale-less shared part opens on
    # its fallback tab rather than on an empty first language.
    defp initial_locale(socket, name) do
      files = files_of(socket, name)
      tabs = tabs(socket.assigns)
      Enum.find(tabs, hd(tabs), fn tab -> Enum.any?(files, &(&1.locale == tab)) end)
    end

    defp caption(socket, name, files) do
      labels = for %{part: :label} = file <- files, into: %{}, do: {file.locale, file.path}

      Enum.find_value(tabs(socket.assigns), name, fn tab ->
        with path when is_binary(path) <- labels[tab],
             {:ok, label} <- File.read(path),
             true <- String.valid?(label),
             label when label != "" <- String.trim(label) do
          label
        else
          _no_label -> nil
        end
      end)
    end

    defp normalize_newlines(value), do: String.replace(value, "\r\n", "\n")

    defp describe_errors(errors) do
      Enum.map_join(errors, "; ", fn {part, reason} ->
        "#{@part_titles[part]}: #{describe(reason)}"
      end)
    end

    defp describe(:too_large), do: "larger than #{div(Overrides.max_bytes(), 1024)} KiB"
    defp describe(:invalid_content), do: "not valid UTF-8 text"
    defp describe(:invalid_name), do: "not a valid template name"
    defp describe(:invalid_part), do: "not a part this editor writes"
    defp describe(:invalid_locale), do: "not a valid language tag"
    defp describe(:invalid_root), do: "the template directory does not exist"
    defp describe(:unsafe_path), do: "the path leads outside the template directory"
    defp describe(:enoent), do: "already gone"
    defp describe(reason) when is_atom(reason), do: reason |> :file.format_error() |> to_string()
    defp describe(reason) when is_binary(reason), do: reason
    defp describe(reason), do: inspect(reason)

    # A host's own reason is not a file error: shown as it is, not as POSIX.
    defp describe_host(reason) when is_atom(reason), do: Atom.to_string(reason)

    defp describe_host(reason) when is_binary(reason) do
      if String.valid?(reason), do: reason, else: inspect(reason)
    end

    defp describe_host(reason), do: inspect(reason)

    ## Rendering

    @impl true
    def render(assigns) do
      assigns =
        assign(assigns,
          messages: Enum.reject(assigns.templates, &String.starts_with?(&1.name, "_")),
          shared: Enum.filter(assigns.templates, &String.starts_with?(&1.name, "_")),
          tabs: tabs(assigns),
          parts: @parts,
          can_edit: editable?(assigns)
        )

      ~H"""
      <div id={@id} class="flex flex-col gap-4">
        <div :if={!is_binary(@root)} role="alert" class="alert alert-error">
          No template directory is configured.
        </div>
        <div :if={@notice} role="alert" class={notice_class(elem(@notice, 0))}>
          {elem(@notice, 1)}
        </div>

        <div class="grid gap-6 lg:grid-cols-4">
          <aside class="flex flex-col gap-4 lg:col-span-1">
            <p :if={@templates == []} class="text-sm opacity-70">No templates yet.</p>

            <.template_group
              :if={@messages != []}
              id={"#{@id}-messages"}
              title="Messages"
              templates={@messages}
              selected={@selected}
              myself={@myself}
            />
            <.template_group
              :if={@shared != []}
              id={"#{@id}-shared"}
              title="Headers, footers and layouts"
              templates={@shared}
              selected={@selected}
              myself={@myself}
            />

            <form
              :if={@can_edit}
              id={"#{@id}-create"}
              phx-submit="create"
              phx-target={@myself}
              class="flex flex-col gap-2"
            >
              <span class="text-sm font-semibold">New template</span>
              <input
                type="text"
                name="create[name]"
                aria-label="Template name"
                class="input input-sm w-full font-mono"
                placeholder={List.first(@name_prefixes, "name")}
                autocomplete="off"
              />
              <select
                name="create[copy_from]"
                aria-label="Start from"
                class="select select-sm w-full"
              >
                <option value="">Empty</option>
                <option :for={template <- @templates} value={template.name}>
                  Copy of {template.name}
                </option>
              </select>
              <button type="submit" class="btn btn-sm">Create</button>
            </form>
          </aside>

          <section class="flex flex-col gap-4 lg:col-span-3">
            <p :if={is_nil(@selected)} class="text-sm opacity-70">Select a template.</p>

            <div :if={@selected} class="flex flex-wrap items-center gap-2">
              <h3 class="font-mono text-lg font-semibold">{@selected}</h3>
              <span :if={@draft?} class="badge badge-warning badge-sm">not saved yet</span>
              <button
                :if={@can_edit}
                id={"#{@id}-delete"}
                type="button"
                phx-click="delete"
                phx-target={@myself}
                class="btn btn-sm btn-outline btn-error ml-auto"
              >
                Delete
              </button>
            </div>

            <div :if={@confirm_delete?} role="alert" class="alert alert-warning">
              <span>Delete “{@selected}” and all its files?</span>
              <div class="flex gap-2">
                <button
                  id={"#{@id}-delete-confirm"}
                  type="button"
                  phx-click="confirm_delete"
                  phx-target={@myself}
                  class="btn btn-sm btn-error"
                >
                  Delete
                </button>
                <button
                  id={"#{@id}-delete-cancel"}
                  type="button"
                  phx-click="cancel_delete"
                  phx-target={@myself}
                  class="btn btn-sm btn-ghost"
                >
                  Cancel
                </button>
              </div>
            </div>

            <div :if={@selected} role="tablist" class="tabs tabs-box w-fit">
              <button
                :for={tab <- @tabs}
                type="button"
                role="tab"
                phx-click="locale"
                phx-value-locale={tab || ""}
                phx-target={@myself}
                aria-selected={to_string(tab == @locale)}
                class={["tab", tab == @locale && "tab-active"]}
                title={if(is_nil(tab), do: "Used for any language without its own file")}
              >
                {tab || "Fallback"}
              </button>
            </div>

            <form
              :if={@selected && @can_edit}
              id={"#{@id}-parts"}
              phx-submit="save"
              phx-target={@myself}
              class="flex flex-col gap-3"
            >
              <.part_field
                :for={part <- @parts}
                id={"#{@id}-part-#{part}"}
                part={part}
                file={@contents[part]}
                retained={@retained[part]}
              />
              <p class="text-xs opacity-70">
                Each language is saved on its own: switching tabs or templates drops unsaved
                changes. A part saved empty has its file deleted.
              </p>
              <button type="submit" class="btn btn-primary btn-sm w-fit">Save</button>
            </form>

            <dl :if={@selected && !@can_edit} class="flex flex-col gap-3">
              <div :for={part <- @parts}>
                <dt class="text-sm font-semibold">{part_title(part)}</dt>
                <dd :if={@contents[part] && @contents[part][:invalid]} class="text-sm text-error">
                  {invalid_utf8()}
                </dd>
                <dd :if={@contents[part] && !@contents[part][:invalid]}>
                  <pre class="whitespace-pre-wrap rounded-box bg-base-200 p-3 text-sm">{@contents[part].content}</pre>
                </dd>
                <dd :if={!@contents[part]} class="text-sm opacity-60">No file.</dd>
              </div>
            </dl>

            <div
              :if={@selected && @missing != []}
              id={"#{@id}-missing"}
              role="alert"
              class="alert alert-warning text-sm"
            >
              Unknown placeholders: {Enum.map_join(@missing, ", ", &"{{#{&1}}}")}
            </div>

            <details :if={@selected && @sample_variables != %{}} class="text-sm">
              <summary class="cursor-pointer">Variables</summary>
              <ul class="mt-2 font-mono">
                <li :for={{name, value} <- Enum.sort(@sample_variables)}>
                  {"{{#{name}}}"} <span class="opacity-60">{inspect(value)}</span>
                </li>
              </ul>
            </details>

            <div :if={@selected && @preview_result} id={"#{@id}-preview"} class="flex flex-col gap-2">
              <span class="text-sm font-semibold">Preview</span>
              <.preview_pane id={@id} result={@preview_result} />
            </div>
          </section>
        </div>
      </div>
      """
    end

    attr :id, :string, required: true
    attr :title, :string, required: true
    attr :templates, :list, required: true
    attr :selected, :string, default: nil
    attr :myself, :any, required: true

    defp template_group(assigns) do
      ~H"""
      <div id={@id}>
        <span class="text-sm font-semibold">{@title}</span>
        <ul class="menu menu-sm w-full p-0">
          <li :for={template <- @templates}>
            <button
              type="button"
              phx-click="select"
              phx-value-name={template.name}
              phx-target={@myself}
              class={["flex flex-col items-start gap-0", template.name == @selected && "menu-active"]}
            >
              <span>{template.caption}</span>
              <span :if={template.caption != template.name} class="font-mono text-xs opacity-60">
                {template.name}
              </span>
            </button>
          </li>
        </ul>
      </div>
      """
    end

    attr :id, :string, required: true
    attr :part, :atom, required: true
    attr :file, :map, default: nil
    attr :retained, :string, default: nil

    defp part_field(%{file: %{invalid: true}} = assigns) do
      ~H"""
      <div class="flex flex-col gap-1">
        <span class="text-sm font-semibold">{part_title(@part)}</span>
        <div id={"#{@id}-invalid"} role="alert" class="alert alert-error text-sm">
          {invalid_utf8()}
        </div>
      </div>
      """
    end

    defp part_field(assigns) do
      assigns =
        assign(assigns,
          value: assigns.retained || if(assigns.file, do: assigns.file.content, else: ""),
          rows: Map.fetch!(@part_rows, assigns.part)
        )

      ~H"""
      <div class="flex flex-col gap-1">
        <label for={@id} class="flex items-baseline gap-2 text-sm">
          <span class="font-semibold">{part_title(@part)}</span>
          <span class="opacity-60">{part_hint(@part)}</span>
          <span :if={@file} class="ml-auto text-xs opacity-60">
            changed {Calendar.strftime(@file.mtime, "%Y-%m-%d %H:%M UTC")}
          </span>
        </label>
        <textarea
          id={@id}
          name={"parts[#{@part}]"}
          rows={@rows}
          class="textarea w-full font-mono text-sm"
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </div>
      """
    end

    attr :id, :string, required: true
    attr :result, :any, required: true

    defp preview_pane(%{result: {:ok, subject, html}} = assigns) do
      assigns = assign(assigns, subject: subject, html: html)

      ~H"""
      <p id={"#{@id}-preview-subject"} class="text-sm">
        <span class="opacity-60">Subject:</span> {@subject}
      </p>
      <%!-- bg-white, not a theme colour: an email is drawn on white whatever the admin theme. --%>
      <iframe
        :if={@html}
        sandbox=""
        srcdoc={@html}
        title="Preview"
        class="h-[32rem] w-full rounded-box border border-base-300 bg-white"
      ></iframe>
      <p :if={!@html} class="text-sm opacity-70">No HTML.</p>
      """
    end

    defp preview_pane(%{result: :unsaved} = assigns) do
      ~H"""
      <p class="text-sm opacity-70">Save the template to preview it.</p>
      """
    end

    defp preview_pane(%{result: {:error, message}} = assigns) do
      assigns = assign(assigns, message: message)

      ~H"""
      <div role="alert" class="alert alert-error text-sm">Preview unavailable: {@message}</div>
      """
    end

    defp invalid_utf8, do: "This file is not valid UTF-8 text; fix it on disk to edit it here."

    defp part_title(part), do: Map.fetch!(@part_titles, part)
    defp part_hint(part), do: Map.fetch!(@part_hints, part)

    defp notice_class(:info), do: "alert alert-success"
    defp notice_class(:error), do: "alert alert-error"
  end
end
