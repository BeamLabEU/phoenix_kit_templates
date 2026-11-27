defmodule PhoenixKit.Templates.CSPInlineTagsTest do
  @moduledoc """
  The editor works under a host Content-Security-Policy that allows inline code by nonce
  only (`script-src 'self' 'nonce-…'`): an inline `<style>` / `<script>` of its own would
  carry the page's nonce (`PhoenixKit.Templates.CSP.nonce/1`), and there is no inline event
  handler at all (no nonce can cover an attribute; a `phx-` binding does that work).

  The package renders no inline tag and no handler, and ships no JavaScript; this test keeps
  it that way. The nonce on the previewed message's own styles is tested in
  `test/phoenix_kit/templates/csp_test.exs` and `editor_test.exs`.

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  @tag_opening ~r/<(script|style)(?=[\s\/>])[^>]*>/is

  # Exempt: a colocated hook (`<script :type={Phoenix.LiveView.ColocatedHook}>`) is taken out
  # of the template by the compiler and is never rendered as an inline tag.
  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not external_script?(opening),
          not String.contains?(opening, "ColocatedHook"),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (see `PhoenixKit.Templates.CSP.nonce/1` and " <>
             "AGENTS.md, \"Content-Security-Policy\"):\n" <> Enum.join(offenders, "\n")
  end

  defp external_script?(opening) do
    opening
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("script[src]")
    |> Enum.any?()
  end

  test "only a script with a src attribute is external" do
    assert external_script?(~s(<SCRIPT defer SRC = "preview.js">))
    refute external_script?(~s(<script data-src="preview.js">))
    refute external_script?(~s(<script title=" src=preview.js">))
    refute external_script?(~s(<style src="preview.css">))
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written, a literal attribute
  # the browser cannot match.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKit.Templates.CSP" or line =~ "nonce={CSP.",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # Only the helper names PhoenixKit's module: this package does not depend on PhoenixKit,
  # and a direct call anywhere would not compile without it.
  test "PhoenixKitWeb.CSP is called through the feature-detecting helper only" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path != "lib/phoenix_kit/templates/csp.ex",
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*#/),
          line =~ ~r/PhoenixKitWeb\.CSP\.[a-z_]+\(/ or
            line =~ ~r/on_mount\(\s*PhoenixKitWeb\.CSP\b/,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!(
             "\\son(?!ly=)[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding):\n" <>
             Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button phx-click="go">) =~ @handler
    refute ~s(<.table only={@only}>) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  test "the package ships no JavaScript" do
    assert Path.wildcard("{lib,priv}/**/*.{js,ts}") == []
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
