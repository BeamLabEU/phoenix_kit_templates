defmodule PhoenixKit.Templates.CSPTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Templates.CSP

  describe "nonce/1" do
    # This package's own test environment has no PhoenixKit.
    test "is nil without PhoenixKit's CSP module" do
      refute Code.ensure_loaded?(PhoenixKitWeb.CSP)
      assert CSP.nonce(:style) == nil
    end
  end

  describe "stamp_styles/2" do
    test "adds the nonce to every <style> opening" do
      assert CSP.stamp_styles("<style>a{}</style><p>x</p><style>b{}</style>", "n1") ==
               ~s(<style nonce="n1">a{}</style><p>x</p><style nonce="n1">b{}</style>)
    end

    test "matches any case and keeps the tag as written" do
      assert CSP.stamp_styles(~s(<STYLE type="text/css">a{}</STYLE>), "n1") ==
               ~s(<STYLE nonce="n1" type="text/css">a{}</STYLE>)

      assert CSP.stamp_styles("<Style\n  media=print>a{}</Style>", "n1") ==
               ~s(<Style nonce="n1"\n  media=print>a{}</Style>)
    end

    test "keeps an attribute value holding a >" do
      assert CSP.stamp_styles(~s|<style media="(width > 600px)">a{}</style>|, "n1") ==
               ~s|<style nonce="n1" media="(width > 600px)">a{}</style>|
    end

    test "leaves a tag that already has a nonce alone" do
      for html <- [
            ~s(<style nonce="own">a{}</style>),
            ~s(<style type="text/css" NONCE='own'>a{}</style>),
            ~s(<style nonce=own>a{}</style>),
            ~s(<style\nnonce = "own">a{}</style>)
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    # A quoted value ends its attribute: the next one needs no space before it.
    test "finds a nonce written right after a quoted value" do
      for html <- [
            ~s(<style media="print"nonce=other>a{}</style>),
            ~s(<style data-a='x'nonce="y">a{}</style>),
            ~s(<style/nonce=own>a{}</style>)
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    test "does not take another attribute or a value for a nonce" do
      for attributes <- [
            ~s( data-nonce="x" title="a nonce here"),
            ~s( title="nonce"),
            " data-nonce=x",
            " media=/nonce/x",
            ~s( title="x"data-nonce="y"),
            ~s( a=b="x"nonce),
            # A = where a name begins is part of that name, quotes and all.
            ~s( ="x"nonce),
            ~s( a="1"="x"nonce)
          ] do
        assert CSP.stamp_styles("<style#{attributes}>a{}</style>", "n1") ==
                 ~s(<style nonce="n1"#{attributes}>a{}</style>)
      end
    end

    # No markup makes a script element without this text, so none can ever be
    # given the nonce, however the rest is read.
    test "leaves a message containing <script wholly unstamped" do
      trap_ = ~s|<script z='">' <style src=//e/a.js>|

      for html <- [
            "<style>a{}</style><script></script>",
            "<SCRIPT>x()</SCRIPT><style>a{}</style>",
            "<ScRiPt src=x.js></ScRiPt><style></style>",
            "<svg><script></script></svg><style></style>",
            ~s(<svg><![CDATA[><a x="]]>) <> trap_,
            ~s(<script><!--<script></script><a x="</script>) <> trap_,
            # Wherever the text is: this is not a reading of the markup.
            "<!-- <script> --><style></style>",
            ~s(<img alt="<script>"><style></style>)
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    # Foreign content and embedded documents follow rules of their own.
    test "leaves a message with svg, math or an embedded document unstamped" do
      for html <- [
            # A script in the nested document, written as character references.
            ~s(<svg><![CDATA[><a x="]]><iframe srcdoc='&lt;script z=">" <style src=//e/a.js>'>),
            # A <link> in this one.
            ~s(<svg><![CDATA[><a x="]]><link rel=stylesheet z='">' <style href=//e/a.css>),
            "<SVG></SVG><style></style>",
            "<style></style><math></math>",
            "<IFrame></IFrame><style></style>",
            "<frameset><frame></frameset><style></style>",
            "<object></object><style></style>",
            "<embed src=x><style></style>",
            ~s(<img alt="<svg>"><style></style>)
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    # Parsers by the older rules ignore a raw-text element's tag inside
    # <select>; lexbor is one of them, and reads this nonce onto the <link>.
    test "leaves a message with a select unstamped" do
      for html <- [
            ~s(<select><xmp></select><link rel=stylesheet z='</xmp>' <style href=//e/a.css>),
            "<style></style><SELECT></SELECT>"
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    # After <template><col> a browser drops other tags, a raw-text element's
    # among them.
    test "leaves a message with a template unstamped" do
      for html <- [
            ~s(<template><col><style></stylex></table></template><link z='</style>' <style href=u>),
            ~s(<template><col><xmp></xmpx></table></template><link z='</xmp>' <style href=u>),
            "<style></style><TEMPLATE></TEMPLATE>"
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    test "stamps a message that only speaks of them" do
      before = "<p>&lt;svg&gt; &lt;iframe&gt; < object> svg math embed select template</p>"

      assert CSP.stamp_styles(before <> "<style>a{}</style>", "n1") ==
               before <> ~s(<style nonce="n1">a{}</style>)
    end

    test "stamps a message that only speaks of scripts" do
      before = "<noscript>script</noscript><p>&lt;script&gt; < script></p>"

      assert CSP.stamp_styles(before <> "<style>a{}</style>", "n1") ==
               before <> ~s(<style nonce="n1">a{}</style>)
    end

    test "leaves text that only looks like a tag as it was" do
      for html <- [
            ~s(<img alt="<style>" src="a.png">),
            ~s(<div data-x='<style media="print">'>x</div>),
            "<!-- <style>a{}</style> -->",
            "<textarea><style></textarea>",
            "<title><style></title>",
            "<styles>a</styles><style-guide></style-guide>",
            "&lt;style&gt;",
            "a < style > b"
          ] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    # In each of the next two, a browser reads `<style href=…>` as attributes of
    # the <link>: a nonce written there would be the link's.
    @link ~s|<link z='">' <style href=//e/a.css>|

    # `<!x`, `<?` and the like are comments to a browser, ended by the first >.
    test "ends a bogus comment at the first >, quotes or not" do
      for opener <- [
            ~s(<!x a=">),
            ~s(<?x a=">),
            ~s(</ a=">),
            ~s(</1 a=">),
            ~s(<!DOCTYPE a=">),
            ~s(<![CDATA[ a=">)
          ] do
        assert CSP.stamp_styles(opener <> @link, "n1") == opener <> @link

        assert CSP.stamp_styles(opener <> "<style>a{}</style>", "n1") ==
                 opener <> ~s(<style nonce="n1">a{}</style>)
      end

      single = ~s(<!x a='>) <> ~s|<link z="'>" <style href=//e/a.css>|
      assert CSP.stamp_styles(single, "n1") == single
    end

    # A = where a name begins is part of the name, and so is a quote after it.
    test "opens a quoted value only where a tag has a value" do
      for tag <- [
            ~s(<a =">),
            ~s(<a=">),
            ~s(<a/=">),
            ~s(<a b="1"=">),
            ~s(</a =">)
          ] do
        assert CSP.stamp_styles(tag <> @link, "n1") == tag <> @link
      end

      # The same in a raw-text element's tag, which must still end at its >.
      before = ~s(<textarea =">x</textarea><i q='">'></i>)

      assert CSP.stamp_styles(before <> "<style>a{}</style>", "n1") ==
               before <> ~s(<style nonce="n1">a{}</style>)
    end

    # A browser drops a tag whose quoted value is never closed, all it holds
    # included.
    test "reads an unclosed quoted value to the end" do
      for html <- [~s(<a x="><style>a{}</style>), ~s(<xmp x='><style></style>)] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    test "leaves the text of a <style> as it was" do
      assert CSP.stamp_styles(~s|<style>a::after{content:"<style>"}</style>|, "n1") ==
               ~s|<style nonce="n1">a::after{content:"<style>"}</style>|
    end

    # A stray quote or comment opener must not swallow the styles after it.
    test "still reaches a <style> after sloppy markup" do
      for before <- [
            "<p class=it's>x</p>",
            "<!-->",
            "<!--->",
            "<!-- c --!>",
            ~s(<!DOCTYPE html><?xml version="1.0"?>),
            "<p>1 < 2, don't</p>"
          ] do
        assert CSP.stamp_styles(before <> "<style>a{}</style><p>'</p>", "n1") ==
                 before <> ~s(<style nonce="n1">a{}</style><p>'</p>)
      end
    end

    test "leaves the text of the other raw-text elements as it was" do
      for element <- ~w(xmp noembed noframes) do
        html = "<#{element}><style></#{element}>"

        assert CSP.stamp_styles(html, "n1") == html

        assert CSP.stamp_styles(html <> "<style></style>", "n1") ==
                 html <> ~s(<style nonce="n1"></style>)
      end

      # Nothing ends <plaintext>.
      html = "<plaintext></plaintext><style>a{}</style>"
      assert CSP.stamp_styles(html, "n1") == html
    end

    test "takes only HTML's whitespace as the end of a tag name" do
      # A vertical tab is part of the name to a browser: not a <style>.
      assert CSP.stamp_styles("<style\v>a{}</style>", "n1") == "<style\v>a{}</style>"

      for space <- [" ", "\t", "\n", "\f", "\r"] do
        assert CSP.stamp_styles("<style#{space}>a{}</style>", "n1") ==
                 ~s(<style nonce="n1"#{space}>a{}</style>)
      end
    end

    # As in a browser, what is not closed runs to the end of the document.
    test "reads an unclosed comment as a comment to the end" do
      for html <- [
            "<!-- <style>a{}</style>",
            "<!-- x> <style>a{}</style>",
            "<!--[if mso]> <style>a{}</style>"
          ] do
        assert CSP.stamp_styles(html, "n1") == html

        assert CSP.stamp_styles("<style></style>" <> html, "n1") ==
                 ~s(<style nonce="n1"></style>) <> html
      end
    end

    test "leaves a <style> tag cut off at the end alone" do
      for html <- ["<style", "<style ", ~s(<style media="print"), "<p><style media=print"] do
        assert CSP.stamp_styles(html, "n1") == html
      end
    end

    test "stamps a <style> that is never closed" do
      assert CSP.stamp_styles("<style>a{}", "n1") == ~s(<style nonce="n1">a{})
    end

    test "copes with an unclosed tag or quote after a <style>" do
      for rest <- ["<a", ~s(<a x="abc), "<a x='abc>", "<textarea>", "</"] do
        assert CSP.stamp_styles("<style></style>" <> rest, "n1") ==
                 ~s(<style nonce="n1"></style>) <> rest
      end
    end

    test "stamps large messages" do
      big = String.duplicate("a", 1_000_000)

      for before <- [
            "<!--#{big}-->",
            ~s(<img src="data:image/png;base64,#{big}">),
            "<style>#{big}</style>"
          ] do
        assert CSP.stamp_styles(before <> "<style>b{}</style>", "n1") =~
                 ~s(<style nonce="n1">b{}</style>)
      end
    end

    # Each of these took seconds when every opener was tried to the end of the
    # input and given up: the time grew with the square of the size. The bound
    # is far above the milliseconds they take, for a slow machine.
    test "reads hostile input in linear time" do
      for {name, html} <- [
            tags: String.duplicate("<a", 8_000) <> ~s( x=">"),
            comments: String.duplicate("<!-- a>", 5_000),
            conditional_comments: String.duplicate("<!--[if mso]>", 4_000),
            bogus_comments: String.duplicate("<!x", 8_000),
            quotes: String.duplicate(~s(<a x=">), 5_000),
            stray_equals: "<a " <> String.duplicate(~s(=" ), 10_000)
          ] do
        {microseconds, _stamped} = :timer.tc(fn -> CSP.stamp_styles(html, "n1") end)

        assert microseconds < 2_000_000, "#{name}: #{div(microseconds, 1000)} ms"
      end
    end

    test "escapes the nonce it writes" do
      assert CSP.stamp_styles("<style></style>", ~s(a"><script>&)) ==
               ~s(<style nonce="a&quot;&gt;&lt;script&gt;&amp;"></style>)
    end

    test "changes nothing without a nonce" do
      html = "<style>a{}</style>"

      assert CSP.stamp_styles(html, nil) == html
      assert CSP.stamp_styles(html, "") == html
    end

    test "passes no HTML on as it is" do
      assert CSP.stamp_styles(nil, "n1") == nil
    end
  end
end
