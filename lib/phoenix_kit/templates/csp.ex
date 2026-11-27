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
      token, opening, name, rest, close, content ->
        # `close` is empty for a tag cut off by the end of the input.
        if String.downcase(name) == "style" and close == ">" and not nonced?(rest <> close),
          do: opening <> attribute <> rest <> close <> content,
          else: token
    end)
  end

  def stamp_styles(html, _nonce), do: html

  # The markup is read one token at a time, so that `<style` is rewritten only
  # where a browser reads a tag: not in a comment, in an attribute's value or in
  # the text of a raw-text element. In order:
  #
  #   * a comment;
  #   * <plaintext>, whose text nothing ends;
  #   * a raw-text element: `<name`, its attributes, `>`, its text;
  #   * any other tag.
  #
  # A quote opens a value only after `=`, as in HTML: the one in `class=it's`
  # must not swallow the tags after it. Whitespace is HTML's, which `\s` is not.
  #
  # Keep it linear: once its opener has matched, a token must not fail, so each
  # end may also be the end of the input. One that failed there would be tried
  # again from every later opener, in time growing with the square of the size.
  #
  # PCRE gives up on a token of a few million bytes (its match limit). The scan
  # stops there: the styles from that token on stay unstamped, nothing is lost.
  defp token do
    ~r/
      <!--(?:-?>|.*?(?:--!?>|\z))
      | <plaintext(?=[ \t\n\f\r\/>]).*+
      | (<(script|style|textarea|title|xmp|iframe|noembed|noframes)(?=[ \t\n\f\r\/>]))
        ((?:=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+')|[^>])*+)
        (>|\z)
        (.*?(?=<\/\2[ \t\n\f\r\/>]|\z))
      | <[a-z\/!?](?:=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+')|[^>])*+(?:>|\z)
    /isx
  end

  # `rest` is the opening tag after its name. It is read one attribute at a
  # time, as HTML does, so that only an attribute named `nonce` counts: not a
  # value, and not the end of another name. A quoted value ends its attribute,
  # with or without a space after it; a `=` where a name begins is part of the
  # name.
  defp nonced?(rest) do
    ~r/
      ([^ \t\n\f\r\/>][^ \t\n\f\r\/>=]*+)
      (?:[ \t\n\f\r]*+=[ \t\n\f\r]*+(?:"[^"]*+"|'[^']*+'|[^ \t\n\f\r>]*+))?+
    /x
    |> Regex.scan(rest, capture: :all_but_first)
    |> Enum.any?(fn [name] -> String.downcase(name) == "nonce" end)
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
