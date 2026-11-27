defmodule PhoenixKit.Templates.CSP do
  @moduledoc false
  # What the editor needs under a host Content-Security-Policy that allows
  # inline styles by nonce only. Its preview is an `<iframe srcdoc>`, which
  # inherits the embedding page's policy, so every `<style>` of the previewed
  # message needs the page's nonce.
  #
  # `PhoenixKitWeb.CSP` is PhoenixKit's, and this package does not depend on
  # PhoenixKit: it is reached only when it is there, through `apply/3` so that
  # the compiler and dialyzer accept a build without it.

  @core PhoenixKitWeb.CSP

  @doc "The page's nonce for inline styles, or `nil`: none set, or no PhoenixKit to ask."
  @spec nonce(:style) :: String.t() | nil
  def nonce(:style) do
    case core(:nonce, [:style], nil) do
      value when is_binary(value) and value != "" -> value
      _none -> nil
    end
  end

  @doc """
  `html` with `nonce="…"` on every `<style>` tag that has none, and `html`
  unchanged without a nonce.

  For a preview only: a nonce belongs to one page, so it is never written into
  a file, a cache or a message that is sent.
  """
  @spec stamp_styles(String.t() | nil, String.t() | nil) :: String.t() | nil
  def stamp_styles(html, nonce) when is_binary(html) and is_binary(nonce) and nonce != "" do
    attribute = ~s( nonce="#{escape(nonce)}")

    Regex.replace(token(), html, fn
      token, opening, name, rest, content ->
        if String.downcase(name) == "style" and not nonced?(rest),
          do: opening <> attribute <> rest <> content,
          else: token
    end)
  end

  def stamp_styles(html, _nonce), do: html

  # The markup is read one token at a time, so that `<style` is rewritten only
  # where a browser reads a tag: not in a comment, in an attribute's value or in
  # the text of <script>, <style>, <textarea> and <title>. In order:
  #
  #   * a comment;
  #   * one of those four elements: `<name`, the rest of its opening tag, its text;
  #   * any other tag.
  #
  # A quote opens a value only after `=`, as in HTML: the one in `class=it's`
  # must not swallow the tags after it.
  defp token do
    ~r/
      <!--(?:-?>|.*?--!?>)
      | (<(script|style|textarea|title)(?=[\s\/>]))
        ((?:=\s*+(?:"[^"]*+"|'[^']*+')|[^>])*+>)
        (.*?(?=<\/\2[\s\/>]|\z))
      | <[a-z\/!?](?:=\s*+(?:"[^"]*+"|'[^']*+')|[^>])*+>
    /isx
  end

  # `rest` is the opening tag after its name. Values are blanked first, so that
  # only an attribute named `nonce` counts.
  defp nonced?(rest) do
    names = Regex.replace(~r/=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/, rest, "=")
    Regex.match?(~r/[\s\/]nonce(?=[\s=\/>])/i, names)
  end

  # The one call into PhoenixKit.
  defp core(function, args, default) do
    if Code.ensure_loaded?(@core) and function_exported?(@core, function, length(args)) do
      apply(@core, function, args)
    else
      default
    end
  end

  defp escape(value) do
    String.replace(value, ["&", "\"", "<", ">"], fn
      "&" -> "&amp;"
      "\"" -> "&quot;"
      "<" -> "&lt;"
      ">" -> "&gt;"
    end)
  end
end
