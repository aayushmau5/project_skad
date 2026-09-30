defmodule Mix.Tasks.Skad.Moderator.CreateTest do
  use Skad.DataCase

  import ExUnit.CaptureIO

  alias Skad.Accounts

  test "creates a moderator with a generated password" do
    output =
      capture_io(fn ->
        Mix.Tasks.Skad.Moderator.Create.run([
          "cli-editor@example.com",
          "CLI",
          "Editor"
        ])
      end)

    assert output =~ "Created moderator cli-editor@example.com"

    [_, password] =
      Regex.run(~r/Generated password \(shown once\): ([A-Za-z0-9_-]+)/, output)

    assert {:ok, account} = Accounts.authenticate_moderator("cli-editor@example.com", password)
    assert account.display_name == "CLI Editor"
  end
end
