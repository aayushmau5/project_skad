defmodule Skad.Contributions.Submission do
  use Ecto.Schema

  import Ecto.Changeset

  @kinds [:new_entry, :correction, :example, :audio, :image, :addition]
  @statuses [:pending, :reviewing, :clarification_needed, :approved, :rejected, :withdrawn]

  schema "submissions" do
    field :public_id, Ecto.UUID, autogenerate: true
    field :client_submission_id, Ecto.UUID
    field :kind, Ecto.Enum, values: @kinds
    field :target_type, :string
    field :target_public_id, Ecto.UUID
    field :payload, :map, redact: true
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :review_history, {:array, :map}, default: [], redact: true
    field :reviewed_at, :utc_datetime
    field :review_note, :string, redact: true

    belongs_to :reviewed_by_account, Skad.Accounts.ModeratorAccount
    has_many :revisions, Skad.Contributions.Revision

    field :received_at, :utc_datetime, autogenerate: {DateTime, :utc_now, [:second]}
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [:client_submission_id, :payload])
    |> validate_required([:client_submission_id, :kind, :payload, :status])
    |> unique_constraint(:public_id)
    |> unique_constraint(:client_submission_id)
    |> check_constraint(:target_public_id,
      name: :submissions_target_must_be_complete,
      message: "must be present with target type"
    )
    |> check_constraint(:payload, name: :submissions_payload_must_be_json)
  end

  def moderation_changeset(submission, attrs) do
    submission
    |> cast(attrs, [:status, :review_history, :reviewed_at, :review_note])
    |> validate_required([:status, :review_history, :reviewed_at])
    |> check_constraint(:review_history, name: :submissions_review_history_must_be_array)
    |> foreign_key_constraint(:reviewed_by_account_id)
  end
end
