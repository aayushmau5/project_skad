defmodule Skad.Accounts.Scope do
  alias Skad.Accounts.ModeratorAccount

  defstruct moderator_account: nil

  def for_moderator(%ModeratorAccount{} = account) do
    %__MODULE__{moderator_account: account}
  end

  def for_moderator(nil), do: nil
end
