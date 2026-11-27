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

    test "does not take another attribute or a value for a nonce" do
      assert CSP.stamp_styles(~s(<style data-nonce="x" title="a nonce here">a{}</style>), "n1") ==
               ~s(<style nonce="n1" data-nonce="x" title="a nonce here">a{}</style>)
    end

    test "never touches <script>, its text included" do
      html = ~s|<script>document.write("<style>a{}</style>")</script>|

      assert CSP.stamp_styles(html, "n1") == html
      assert CSP.stamp_styles(~s(<script src="x.js"></script>), "n1") =~ ~s(<script src="x.js">)
      refute CSP.stamp_styles("<script></script><style></style>", "n1") =~ ~s(<script nonce)
      assert CSP.stamp_styles("<script></script><style></style>", "n1") =~ ~s(<style nonce="n1">)
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
