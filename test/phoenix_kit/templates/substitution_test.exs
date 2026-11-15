defmodule PhoenixKit.Templates.SubstitutionTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates.Substitution

  doctest PhoenixKit.Templates.Substitution

  describe "variables/1" do
    test "collects each placeholder once, in order of first appearance" do
      assert Substitution.variables("{{b}} {{a}} {{ b }}") == ["b", "a"]
    end

    test "ignores text that only looks like a placeholder" do
      for content <- [
            "{{ }}",
            "{{1abc}}",
            "{{a-b}}",
            "{single}",
            "{{unclosed",
            "{{}}",
            "{{{}}}",
            "{{{ }}}"
          ] do
        assert Substitution.variables(content) == [], "expected no match in #{inspect(content)}"
      end
    end

    test "handles absent content" do
      assert Substitution.variables(nil) == []
    end

    test "recognizes {{{raw}}} and normalizes its name like {{escaped}}" do
      assert Substitution.variables("{{{a}}} {{ a }} {{{ b }}}") == ["a", "b"]
    end
  end

  describe "split/1" do
    @samples [
      "",
      "plain text",
      "{{a}}",
      "{{{a}}}",
      "x{{a}}y{{{ b }}}z",
      "{{a}}{{b}}{{{c}}}",
      "{{{{a}}}}",
      "{{{a}}",
      "{{a}}}",
      "{{ }} {{1abc}} {{a-b}} {single} {{unclosed {{}}",
      "Hi {{ user_name }}, <a href=\"{{url}}\">go</a> {{{table}}}"
    ]

    test "alternates text and placeholders, and joins back to the input" do
      for content <- @samples do
        pieces = Substitution.split(content)

        assert rem(length(pieces), 2) == 1, inspect(content)
        assert Enum.join(pieces) == content
      end
    end

    test "the odd pieces are exactly what variables/1 and substitute/3 see" do
      for content <- @samples do
        placeholders = content |> Substitution.split() |> Enum.drop(1) |> Enum.take_every(2)
        names = placeholders |> Enum.flat_map(&Substitution.variables/1) |> Enum.uniq()

        assert names == Substitution.variables(content), inspect(content)

        # Every placeholder is one whole match: substituting it alone consumes it.
        for placeholder <- placeholders do
          [name] = Substitution.variables(placeholder)
          assert Substitution.substitute(placeholder, %{name => "V"}) == "V"
        end

        # The text pieces hold no placeholder.
        texts = content |> Substitution.split() |> Enum.take_every(2)
        assert Enum.all?(texts, &(Substitution.variables(&1) == []))
      end
    end

    test "keeps the braces and inner whitespace as written" do
      assert Substitution.split("{{{ raw }}}") == ["", "{{{ raw }}}", ""]
    end
  end

  describe "substitute/2" do
    test "accepts atom and string keys alike" do
      # Callers write %{user_email: …}; content exported from the old database
      # templates carries "user_email" keys. Both have to work.
      assert Substitution.substitute("{{a}}/{{b}}", %{"b" => 2, a: 1}) == "1/2"
    end

    test "tolerates whitespace inside the braces" do
      assert Substitution.substitute("{{ name }}", %{name: "Ada"}) == "Ada"
    end

    test "stringifies non-binary values" do
      assert Substitution.substitute("{{n}} {{ok}}", %{n: 42, ok: true}) == "42 true"
    end

    test "leaves an unbound placeholder visible rather than blanking it" do
      # A silent empty string reads as finished copy and ships; a visible
      # {{user_emial}} announces the typo in a preview or a test.
      assert Substitution.substitute("Hi {{user_emial}}", %{user_email: "a@b.c"}) ==
               "Hi {{user_emial}}"
    end

    test "substitutes every occurrence of a repeated placeholder" do
      assert Substitution.substitute("{{a}}-{{a}}", %{a: "x"}) == "x-x"
    end

    test "passes absent content through" do
      assert Substitution.substitute(nil, %{a: 1}) == nil
    end

    test "does not re-scan a substituted value for placeholders" do
      # Otherwise a value carrying braces could inject a second round.
      assert Substitution.substitute("{{a}}", %{a: "{{b}}", b: "boom"}) == "{{b}}"
    end

    test "{{{raw}}} substitutes the same as {{escaped}} — plain semantics escape neither" do
      assert Substitution.substitute("{{{name}}}", %{name: "<b>Ada</b>"}) == "<b>Ada</b>"
    end
  end

  describe "substitute/3 with escape: true" do
    test "escapes a {{variable}} value's &, <, >, \", '" do
      assert Substitution.substitute("{{v}}", %{v: ~s(&<>"')}, escape: true) ==
               "&amp;&lt;&gt;&quot;&#39;"
    end

    test "escapes every occurrence, leaving multibyte text between them intact" do
      assert Substitution.substitute("{{v}}", %{v: "Zoë & Ω <'a'> & ё"}, escape: true) ==
               "Zoë &amp; Ω &lt;&#39;a&#39;&gt; &amp; ё"
    end

    test "escapes already-escaped-looking content again, because a value is always data" do
      assert Substitution.substitute("{{v}}", %{v: "&amp;"}, escape: true) == "&amp;amp;"
    end

    test "{{{raw}}} is never escaped, opting a pre-rendered HTML value out" do
      assert Substitution.substitute("{{{v}}}", %{v: "<b>Ada</b>"}, escape: true) ==
               "<b>Ada</b>"
    end

    test "an unbound placeholder is left verbatim in either syntax, escape option notwithstanding" do
      assert Substitution.substitute("{{v}}", %{}, escape: true) == "{{v}}"
      assert Substitution.substitute("{{{v}}}", %{}, escape: true) == "{{{v}}}"
    end

    test "without the option, substitute/2 and substitute/3 agree — plain semantics" do
      assert Substitution.substitute("{{v}}", %{v: "<b>"}) ==
               Substitution.substitute("{{v}}", %{v: "<b>"}, [])
    end

    # Boundary cases from the moduledoc table, each pinned so a future change
    # to the regex has to look at this table rather than guess.
    boundary_cases = [
      {"{{{x}}}", "<b>Ada</b>", "<b>Ada</b>"},
      {"{{{ x }}}", "<b>Ada</b>", "<b>Ada</b>"},
      {"{{ x }}", "<b>Ada</b>", "&lt;b&gt;Ada&lt;/b&gt;"},
      {"{{{{x}}}}", "V", "{V}"},
      {"{{{x}}", "<b>", "{&lt;b&gt;"},
      {"{{x}}}", "<b>", "&lt;b&gt;}"},
      {"{ {{x}} }", "<b>", "{ &lt;b&gt; }"},
      {"{{{x}}}}", "<b>Ada</b>", "<b>Ada</b>}"},
      {"{{{{x}}}", "<b>Ada</b>", "{<b>Ada</b>"},
      {"{{{{{x}}}}}", "<b>Ada</b>", "{{<b>Ada</b>}}"}
    ]

    for {input, value, expected} <- boundary_cases do
      test "#{inspect(input)} bound renders #{inspect(expected)}" do
        assert Substitution.substitute(unquote(input), %{x: unquote(value)}, escape: true) ==
                 unquote(expected)
      end

      test "#{inspect(input)} unbound reproduces the input byte-for-byte" do
        assert Substitution.substitute(unquote(input), %{}, escape: true) == unquote(input)
      end
    end

    test "CSS braces in an html part are untouched — no {{ }} pair, no match" do
      css = "body { margin: 0 } @media (min-width: 1px) { body { margin: 0 } }"
      assert Substitution.substitute(css, %{}, escape: true) == css
    end

    test "a single stray brace from legacy content passes through unchanged" do
      assert Substitution.substitute("cost: {5, 10}", %{}, escape: true) == "cost: {5, 10}"
    end

    test "adjacent placeholders without a separating space both resolve" do
      assert Substitution.substitute("{{a}}{{{b}}}", %{a: "<x>", b: "<y>"}, escape: true) ==
               "&lt;x&gt;<y>"
    end

    test "an empty or whitespace-only name never matches, in either syntax" do
      for content <- ["{{}}", "{{ }}", "{{{}}}", "{{{ }}}"] do
        assert Substitution.substitute(content, %{}, escape: true) == content,
               "expected #{inspect(content)} to pass through unchanged"
      end
    end
  end

  describe "substitute/3 option validation" do
    test "raises on an unknown option — a typo must not silently behave like escape: false" do
      assert_raise ArgumentError, fn ->
        Substitution.substitute("{{a}}", %{a: 1}, escaped: true)
      end
    end

    test "raises when :escape is not a boolean" do
      assert_raise ArgumentError, fn ->
        Substitution.substitute("{{a}}", %{a: 1}, escape: "yes")
      end
    end

    test "validates options even when content is nil" do
      assert_raise ArgumentError, fn -> Substitution.substitute(nil, %{}, escaped: true) end
      assert_raise ArgumentError, fn -> Substitution.substitute(nil, %{}, escape: "yes") end
    end
  end

  describe "missing/2" do
    test "names only the unbound placeholders" do
      assert Substitution.missing("{{a}} {{b}} {{c}}", %{a: 1, c: 3}) == ["b"]
    end

    test "is empty when the render would be fully bound" do
      assert Substitution.missing("{{a}}", %{a: 1}) == []
      assert Substitution.missing("no placeholders", %{}) == []
      assert Substitution.missing(nil, %{}) == []
    end

    test "sees a {{{raw}}} placeholder's name like a {{escaped}} one" do
      assert Substitution.missing("{{{a}}} {{b}}", %{a: 1}) == ["b"]
    end
  end
end
