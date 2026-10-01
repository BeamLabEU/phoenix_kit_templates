defmodule PhoenixKit.TemplatesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates
  alias PhoenixKit.Templates.Overrides

  @moduletag :tmp_dir

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  defp defaults do
    %{
      subject: "New login to your account",
      text: "Hi {{user_email}}, we saw a login from {{ip_address}}."
    }
  end

  describe "render/4 with no host override" do
    test "renders the caller's defaults with variables substituted" do
      assert %{
               subject: "New login to your account",
               text: "Hi a@b.c, we saw a login from 1.2.3.4.",
               html: nil
             } =
               Templates.render("new_login_alert", defaults(), %{
                 "user_email" => "a@b.c",
                 "ip_address" => "1.2.3.4"
               })
    end

    test "a part the caller did not supply renders as nil" do
      # `html` is optional: a template with only subject and text is valid, so
      # an absent :html is a value (nil), not an error.
      assert %{html: nil} = Templates.render("new_login_alert", defaults(), %{})
    end
  end

  describe "render/4 with host overrides" do
    test "an override replaces the default for that part only", %{tmp_dir: root} do
      write(root, "new_login_alert", "text.txt", "Custom body for {{user_email}}.")

      rendered =
        Templates.render("new_login_alert", defaults(), %{"user_email" => "a@b.c"}, paths: [root])

      assert rendered.text == "Custom body for a@b.c."
      # Untouched parts keep the package's translated default — a host that
      # rewrites the body should not have to restate the subject.
      assert rendered.subject == "New login to your account"
    end

    test "the recipient's locale selects among override files", %{tmp_dir: root} do
      write(root, "new_login_alert", "text.txt", "default body")
      write(root, "new_login_alert", "text.uk.txt", "український текст")

      assert Templates.render("new_login_alert", defaults(), %{}, paths: [root], locale: "uk").text ==
               "український текст"

      assert Templates.render("new_login_alert", defaults(), %{}, paths: [root], locale: "de").text ==
               "default body"
    end

    test "an override supplying html adds a part the defaults omit", %{tmp_dir: root} do
      write(root, "new_login_alert", "html.html", "<p>{{user_email}}</p>")

      assert Templates.render("new_login_alert", defaults(), %{"user_email" => "a@b.c"},
               paths: [root]
             ).html == "<p>a@b.c</p>"
    end

    test "a reserved underscore name renders like any other", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")

      assert %{html: "<main><b>hi</b></main>", subject: nil, text: nil} =
               Templates.render("_layout", %{}, %{"content" => "<b>hi</b>"}, paths: [root])
    end
  end

  describe "render/4 escapes html but not subject or text" do
    test "a {{variable}} value is HTML-escaped in html only" do
      defaults = %{
        subject: "{{company}}",
        text: "{{company}}",
        html: "<p>{{company}}</p>"
      }

      rendered = Templates.render("billing_invoice", defaults, %{"company" => "A & B <ok>"})

      assert rendered.subject == "A & B <ok>"
      assert rendered.text == "A & B <ok>"
      assert rendered.html == "<p>A &amp; B &lt;ok&gt;</p>"
    end

    test "{{{variable}}} opts an html value out of escaping — the pre-rendered-HTML case" do
      defaults = %{html: "<table>{{{line_items_html}}}</table>"}
      pre_rendered = "<tr><td>Widget</td></tr>"

      assert Templates.render("billing_invoice", defaults, %{"line_items_html" => pre_rendered}).html ==
               "<table><tr><td>Widget</td></tr></table>"
    end

    test "{{{variable}}} in subject or text behaves exactly like {{variable}} — both are raw" do
      defaults = %{subject: "{{{name}}}", text: "{{{name}}}"}
      rendered = Templates.render("billing_invoice", defaults, %{"name" => "<b>Ada</b>"})

      assert rendered.subject == "<b>Ada</b>"
      assert rendered.text == "<b>Ada</b>"
    end

    test "a host override's html is escaped exactly like a caller default's", %{tmp_dir: root} do
      write(root, "billing_invoice", "html.html", "<p>{{company}}</p><p>{{{footer_html}}}</p>")

      rendered =
        Templates.render(
          "billing_invoice",
          %{},
          %{"company" => "<script>", "footer_html" => "<em>ok</em>"},
          paths: [root]
        )

      assert rendered.html == "<p>&lt;script&gt;</p><p><em>ok</em></p>"
    end
  end

  describe "render/4 subject is a single line" do
    test "a trailing \\n in a file is dropped", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "New login\n")
      assert Templates.render("alert", %{}, %{}, paths: [root]).subject == "New login"
    end

    test "a trailing \\r\\n and spaces are dropped", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "New login  \r\n\r\n")
      assert Templates.render("alert", %{}, %{}, paths: [root]).subject == "New login"
    end

    test "interior line breaks become one space", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "New\nlogin\r\nto your\raccount\n")

      assert Templates.render("alert", %{}, %{}, paths: [root]).subject ==
               "New login to your account"
    end

    test "applies to defaults too" do
      assert Templates.render("alert", %{subject: "Hi\n"}, %{}).subject == "Hi"
      assert Templates.render("alert", %{subject: "Hi\nthere"}, %{}).subject == "Hi there"
    end

    test "a line break inside a substituted value is flattened too" do
      assert Templates.render("alert", %{subject: "Hi {{name}}"}, %{"name" => "A\nBcc: x"}).subject ==
               "Hi A Bcc: x"
    end

    test "leading whitespace and line breaks are dropped", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "\n  New login\n")
      assert Templates.render("alert", %{}, %{}, paths: [root]).subject == "New login"
      assert Templates.render("alert", %{subject: " \r\nHi"}, %{}).subject == "Hi"
    end

    test "a leading byte-order mark is dropped", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "\u{FEFF}New login\n")
      assert Templates.render("alert", %{}, %{}, paths: [root]).subject == "New login"
      assert Templates.render("alert", %{subject: "\u{FEFF} Hi"}, %{}).subject == "Hi"
    end

    test "whitespace around an interior line break collapses into one space", %{tmp_dir: root} do
      write(root, "alert", "subject.txt", "New login  \r\n    to your account\n")

      assert Templates.render("alert", %{}, %{}, paths: [root]).subject ==
               "New login to your account"
    end

    test "other parts keep their trailing newline", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "Body\nline\n")
      assert Templates.render("alert", %{}, %{}, paths: [root]).text == "Body\nline\n"
    end

    test "an absent subject stays nil" do
      assert Templates.render("alert", %{}, %{}).subject == nil
    end
  end

  describe "render/4 markdown and layout parts" do
    test "always returns the five keys" do
      rendered = Templates.render("alert", %{}, %{})
      assert Enum.sort(Map.keys(rendered)) == [:html, :layout, :markdown, :subject, :text]
    end

    test "markdown is returned verbatim from a file, unsubstituted", %{tmp_dir: root} do
      md = "# Hi {{name}}\n\n[Confirm]({{confirmation_url}})\n"
      write(root, "register", "markdown.md", md)

      rendered =
        Templates.render("register", %{}, %{"name" => "Ada", "confirmation_url" => "https://x"},
          paths: [root]
        )

      assert rendered.markdown == md
    end

    test "markdown from defaults is returned verbatim too" do
      md = "Hi {{{name}}}\n"
      assert Templates.render("register", %{markdown: md}, %{"name" => "Ada"}).markdown == md
    end

    test "markdown selects its locale file", %{tmp_dir: root} do
      write(root, "register", "markdown.md", "en")
      write(root, "register", "markdown.ru.md", "ru")

      assert Templates.render("register", %{}, %{}, paths: [root], locale: "ru").markdown == "ru"
      assert Templates.render("register", %{}, %{}, paths: [root], locale: "de").markdown == "en"
    end

    test "layout is trimmed and unsubstituted", %{tmp_dir: root} do
      write(root, "invoice", "layout.txt", "  billing\n")

      assert Templates.render("invoice", %{}, %{"billing" => "x"}, paths: [root]).layout ==
               "billing"

      assert Templates.render("invoice", %{layout: " {{g}}\n"}, %{"g" => "x"}).layout == "{{g}}"
    end

    test "layout drops a leading byte-order mark", %{tmp_dir: root} do
      write(root, "invoice", "layout.txt", "\u{FEFF}billing\n")

      assert Templates.render("invoice", %{}, %{}, paths: [root]).layout == "billing"
      assert Templates.render("invoice", %{layout: "\u{FEFF} billing"}, %{}).layout == "billing"
    end

    test "layout ignores a locale-specific file", %{tmp_dir: root} do
      write(root, "invoice", "layout.de.txt", "de-group")
      assert Templates.render("invoice", %{}, %{}, paths: [root], locale: "de").layout == nil

      # Absence is cached, so drop it before the file appears.
      Overrides.reset_cache([root])
      write(root, "invoice", "layout.txt", "billing\n")

      assert Templates.render("invoice", %{}, %{}, paths: [root], locale: "de").layout ==
               "billing"

      assert Templates.sources("invoice", %{}, paths: [root], locale: "de").layout ==
               {:file, Path.join([root, "invoice", "layout.txt"])}
    end

    test "missing_variables/4 never reports layout", %{tmp_dir: root} do
      write(root, "invoice", "layout.txt", "{{group}}")
      assert Templates.missing_variables("invoice", %{layout: "{{x}}"}, %{}, paths: [root]) == %{}
      assert Templates.missing_variables("invoice", %{layout: "{{x}}"}, %{}) == %{}
    end

    test "a template with no markdown or layout has nil for both" do
      assert %{markdown: nil, layout: nil} = Templates.render("alert", %{text: "x"}, %{})
    end

    test "missing_variables/4 counts markdown placeholders like any other part", %{tmp_dir: root} do
      write(root, "register", "markdown.md", "[Go]({{confirmation_url}}) {{name}}")

      assert Templates.missing_variables("register", %{}, %{"name" => "Ada"}, paths: [root]) ==
               %{markdown: ["confirmation_url"]}
    end
  end

  describe "sources/3" do
    test "reports file, default, and absent parts", %{tmp_dir: root} do
      write(root, "alert", "text.txt", "from file")
      write(root, "alert", "subject.de.txt", "de subject")

      defaults = %{subject: "default subject", text: "default text", html: nil}

      assert Templates.sources("alert", defaults, paths: [root], locale: "de") == %{
               subject: {:file, Path.join([root, "alert", "subject.de.txt"])},
               text: {:file, Path.join([root, "alert", "text.txt"])}
             }
    end

    test "a default without a file is :default; a nil default has no key" do
      assert Templates.sources("alert", %{subject: "s", text: nil}) == %{subject: :default}
      assert Templates.sources("alert", %{}) == %{}
    end

    test "an empty file is still reported as a file", %{tmp_dir: root} do
      write(root, "alert", "html.html", "")

      assert Templates.sources("alert", %{html: "<p>x</p>"}, paths: [root]) ==
               %{html: {:file, Path.join([root, "alert", "html.html"])}}
    end

    test "covers markdown and layout", %{tmp_dir: root} do
      write(root, "alert", "markdown.md", "# x")
      write(root, "alert", "layout.txt", "billing")

      assert %{markdown: {:file, _}, layout: {:file, _}} =
               Templates.sources("alert", %{}, paths: [root])

      assert Templates.sources("alert", %{markdown: "m", layout: "l"}) ==
               %{markdown: :default, layout: :default}
    end
  end

  describe "missing_variables/4" do
    test "reports unbound placeholders per part, omitting clean ones" do
      assert Templates.missing_variables("new_login_alert", defaults(), %{
               "user_email" => "a@b.c"
             }) == %{text: ["ip_address"]}
    end

    test "is empty when every part would render fully bound" do
      assert Templates.missing_variables("new_login_alert", defaults(), %{
               "user_email" => "a@b.c",
               "ip_address" => "1.2.3.4"
             }) == %{}
    end

    test "sees the override's placeholders, not the default's", %{tmp_dir: root} do
      # The point of the check: a host override is the content most likely to
      # carry a placeholder nobody supplies.
      write(root, "new_login_alert", "text.txt", "Hello {{nickname}}")

      assert Templates.missing_variables("new_login_alert", defaults(), %{}, paths: [root]) ==
               %{text: ["nickname"]}
    end

    test "a {{{raw}}} placeholder is reported like a {{escaped}} one" do
      assert Templates.missing_variables(
               "billing_invoice",
               %{html: "<p>{{{line_items_html}}}</p>"},
               %{}
             ) ==
               %{html: ["line_items_html"]}
    end
  end
end
