defmodule SkadWeb.ModeratorController do
  use SkadWeb, :controller

  def home(conn, _params), do: render(conn, :home, page_title: gettext("Moderator workspace"))
end
