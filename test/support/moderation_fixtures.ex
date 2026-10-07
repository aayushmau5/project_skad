defmodule Skad.ModerationFixtures do
  alias Skad.Accounts
  alias Skad.Accounts.Scope
  alias Skad.Archive

  def records do
    {:ok, moderator} =
      Accounts.create_moderator_account(%{
        email: "archive-editor@example.test",
        display_name: "Archive Editor",
        password: "test-editor-password",
        password_confirmation: "test-editor-password"
      })

    {:ok, language} =
      Archive.create_language(%{slug: "english", name: "English", code: "en", direction: :ltr})

    {:ok, water} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "WATER"},
        entry: %{
          definitions: [
            %{language: "english", text: "A clear liquid."},
            %{language: "hindi", text: "पानी"}
          ],
          usage_note: "For drinking."
        },
        forms: [
          %{text: "Water", kind: :spelling, is_primary: true},
          %{text: "H₂O", kind: :alias, is_primary: false}
        ]
      })

    {:ok, drink} =
      Archive.publish_new_meaning(language, %{
        concept: %{editorial_label: "DRINK"},
        entry: %{definitions: [%{language: "english", text: "Consume a liquid."}]},
        forms: [%{text: "Drink", kind: :spelling, is_primary: true}]
      })

    {:ok, example} =
      Archive.publish_usage_example(language, %{
        example: %{text: "Drink water.", translations: [%{language: "hindi", text: "पानी पिएँ।"}]},
        links: [
          %{entry_public_id: drink.public_id, start_offset: 0, end_offset: 5, role: :focus},
          %{entry_public_id: water.public_id, start_offset: 6, end_offset: 11, role: :focus}
        ]
      })

    %{
      moderator: moderator,
      scope: Scope.for_moderator(moderator),
      water: water,
      drink: drink,
      example: example
    }
  end

  def deletion, do: %{"reason" => "Duplicate or outdated record", "confirmed" => "true"}

  def log_in(conn, moderator) do
    {:ok, token} = Accounts.create_moderator_session(moderator)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:moderator_session_token, token)
  end
end
