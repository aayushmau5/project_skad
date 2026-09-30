defmodule Skad.Contributions.Revision do
  use Ecto.Schema

  import Ecto.Changeset

  @actions [:create, :update, :archive, :restore, :merge, :withdraw]
  @actor_types [:moderator, :system, :importer]

  schema "revisions" do
    field :target_type, :string
    field :target_public_id, Ecto.UUID
    field :action, Ecto.Enum, values: @actions
    field :before_state, :map, redact: true
    field :after_state, :map, redact: true
    field :actor_type, Ecto.Enum, values: @actor_types
    field :source, :map, redact: true
    field :reason, :string

    belongs_to :moderator_account, Skad.Accounts.ModeratorAccount
    belongs_to :submission, Skad.Contributions.Submission

    field :inserted_at, :utc_datetime, autogenerate: {DateTime, :utc_now, [:second]}
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:before_state, :after_state, :source, :reason])
    |> validate_required([:target_type, :target_public_id, :action, :actor_type])
    |> check_constraint(:target_type, name: :revisions_target_type_must_not_be_empty)
    |> check_constraint(:action, name: :revisions_action_must_be_valid)
    |> check_constraint(:before_state, name: :revisions_before_state_must_be_json)
    |> check_constraint(:after_state, name: :revisions_after_state_must_be_json)
    |> check_constraint(:actor_type, name: :revisions_actor_type_must_be_valid)
    |> check_constraint(:source, name: :revisions_source_must_be_json)
    |> foreign_key_constraint(:moderator_account_id)
    |> foreign_key_constraint(:submission_id)
  end
end
