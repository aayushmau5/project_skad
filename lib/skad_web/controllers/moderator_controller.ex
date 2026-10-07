defmodule SkadWeb.ModeratorController do
  use SkadWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      page_title: gettext("Moderator workspace"),
      pending_review_count:
        Skad.Contributions.count_submissions_for_review(conn.assigns.current_scope)
    )
  end
end
