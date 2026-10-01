defmodule PhoenixKit.TemplatesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates

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
