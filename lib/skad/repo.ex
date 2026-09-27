defmodule Skad.Repo do
  use Ecto.Repo,
    otp_app: :skad,
    adapter: Ecto.Adapters.SQLite3
end
