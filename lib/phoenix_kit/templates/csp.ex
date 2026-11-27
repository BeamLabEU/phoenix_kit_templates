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
  `html` with `nonce="…"` on its `<style>` tags that have none, for a preview.

  A message that has `<script`, `<svg`, `<math`, `<iframe`, `<frame`,
  `<object`, `<embed`, `<select` or `<template` in it anywhere, in any case of
  letters, is left as it is; otherwise the nonce is added only to `<style>`
  opening tags. Without a nonce, `html` is left as it is too.

  What this costs is cosmetic: such a message (the text in a comment is enough)
  previews unstyled, and so do the styles from a part of a few million bytes on.

  For a preview only: a nonce belongs to one page, so it is never written into
  a file, a cache or a message that is sent. The frame that shows it must not
  allow scripts, which is also how the markup is read here: `<noscript>` holds
  markup.
  """
  @spec stamp_styles(String.t() | nil, String.t() | nil) :: String.t() | nil
  def stamp_styles(html, nonce) when is_binary(html) and is_binary(nonce) and nonce != "" do
    if Regex.match?(~r{<style}i, html) and not leave_alone?(html) do
      stamp(html, ~s( nonce="#{escape(nonce)}"))
    else
      html
    end
  end

  def stamp_styles(html, _nonce), do: html

  # Whether `html` may hold what the reading below does not follow: a script,
  # foreign content (<svg>, <math>), an embedded document, or where a browser
  # drops a raw-text element's tag and reads its text as markup: in a frameset,
  # in a <select> (parsers by the older rules) and after <template><col>. None
  # of these exists without this text: a NUL in a tag's name becomes U+FFFD,
  # `< svg` is text, and a character reference never opens a tag. Looked for in
  # the whole input, not where that reading finds tags, so that nothing it gets
  # wrong matters here.
  defp leave_alone?(html),
    do: Regex.match?(~r/<(script|svg|math|iframe|frame|object|embed|select|template)/i, html)

  # The markup is read one token at a time, so that `<style` is rewritten only
  # where a browser reads a tag: not in a comment, in an attribute's value or in
  # the text of a raw-text element. In order:
  #
  #   * a comment;
  #   * <plaintext>, whose text nothing ends;
  #   * a raw-text element: `<name`, its attributes, `>`, its text;
  #   * any other start or end tag;
  #   * what HTML takes for a comment too (`<!x`, `<?`, `</1`), ended by the
  #     first `>`, quotes or not.
  #
  # A tag is read one attribute at a time, as in HTML: a quote opens a value only
  # after the `=` of an attribute. The one in `class=it's`, in `<a=">` or in
  # `<a =">` is part of a value or a name and must not swallow what follows. A
  # quoted value left open runs to the end. Whitespace is HTML's, which `\s` is
  # not.
  #
  # Keep it linear: once its opener has matched, a token must not fail, so each
  # end may also be the end of the input. One that failed there would be tried
  # again from every later opener, in time growing with the square of the size.
  #
  # PCRE gives up on a token of a few million bytes (its match limit). The scan
  # stops there: the styles from that token on stay unstamped, nothing is lost.
  #
  # This is HTML's tokenizer, in part, and no parser. What would put it out of
  # step with a browser never reaches it: see `leave_alone?/1`.
  @attributes ~S"""
  (?: [ \t\n\f\r\/]++
    | [^ \t\n\f\r\/>][^ \t\n\f\r\/>=]*+
      (?:[ \t\n\f\r]*+=[ \t\n\f\r]*+(?:"[^"]*+"?|'[^']*+'?|[^ \t\n\f\r>]*+))?+
  )*+
  """

  @token ~r/
      <!--(?:-?>|.*?(?:--!?>|\z))
      | <plaintext(?=[ \t\n\f\r\/>]).*+
      | (<(style|textarea|title|xmp|noembed|noframes)(?=[ \t\n\f\r\/>]))
        (#{@attributes})
        (>|\z)
        (.*?(?=<\/\2[ \t\n\f\r\/>]|\z))
      | <\/?[a-z][^ \t\n\f\r\/>]*+ #{@attributes} (?:>|\z)
      | <[!?\/][^>]*+(?:>|\z)
    /isx

  defp stamp(html, attribute) do
    Regex.replace(@token, html, fn
      token, opening, name, rest, close, content ->
        # `close` is empty for a tag cut off by the end of the input.
        if String.downcase(name) == "style" and close == ">" and not nonced?(rest <> close),
          do: opening <> attribute <> rest <> close <> content,
          else: token
    end)
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
