defmodule SkadWeb.ErrorHTMLTest do
  use SkadWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "renders an accessible not-found page in Hindi" do
    document =
      render_to_string(SkadWeb.ErrorHTML, "404", "html", []) |> LazyHTML.from_document()

    assert LazyHTML.attribute(LazyHTML.query(document, "html"), "lang") == ["hi"]
    assert Enum.count(LazyHTML.query_by_id(document, "request-error-search")) == 1

    assert String.trim(LazyHTML.text(LazyHTML.query(document, "#request-error h1"))) ==
             "यह पेज उपलब्ध नहीं है"
  end

  test "server errors explain recovery without claiming an unconfirmed save" do
    document =
      render_to_string(SkadWeb.ErrorHTML, "500", "html", locale: "en") |> LazyHTML.from_document()

    assert Enum.count(LazyHTML.query_by_id(document, "request-error")) == 1

    assert LazyHTML.text(LazyHTML.query(document, "#request-error p")) =~
             "If you received a receipt"

    assert Enum.count(LazyHTML.query_by_id(document, "skip-to-content")) == 1
  end
end
