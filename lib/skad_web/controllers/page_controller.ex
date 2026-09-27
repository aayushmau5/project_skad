defmodule SkadWeb.PageController do
  use SkadWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
