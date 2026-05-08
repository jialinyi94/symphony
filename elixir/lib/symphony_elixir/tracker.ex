defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.

  Adapters self-register here via `@adapters` and self-describe via the
  `kind/0`, `validate_config/1`, and (optional) `secret_env_var/0` callbacks.
  Adding a new tracker is a matter of writing one module + appending it to
  `@adapters`; the orchestrator and config layers do not branch on kind.
  """

  alias SymphonyElixir.Config

  @adapters [
    SymphonyElixir.Tracker.Memory,
    SymphonyElixir.Linear.Adapter,
    SymphonyElixir.GitHub.Adapter
  ]

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @callback fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}

  @callback kind() :: String.t()
  @callback validate_config(term()) :: :ok | {:error, term()}
  @callback secret_env_var() :: String.t() | nil

  @optional_callbacks secret_env_var: 0, fetch_sub_issues: 1

  @spec adapters() :: [module()]
  def adapters, do: @adapters

  @spec adapter_for_kind(String.t() | nil) ::
          {:ok, module()} | {:error, {:unsupported_tracker_kind, term()}}
  def adapter_for_kind(kind) when is_binary(kind) do
    case Enum.find(@adapters, fn mod -> mod.kind() == kind end) do
      nil -> {:error, {:unsupported_tracker_kind, kind}}
      mod -> {:ok, mod}
    end
  end

  def adapter_for_kind(other), do: {:error, {:unsupported_tracker_kind, other}}

  @doc """
  Returns the environment variable name an adapter falls back to for its
  api_key, or `nil` if it doesn't expose one.
  """
  @spec api_key_env_var(String.t() | nil) :: String.t() | nil
  def api_key_env_var(kind) do
    with {:ok, mod} <- adapter_for_kind(kind),
         true <- function_exported?(mod, :secret_env_var, 0) do
      mod.secret_env_var()
    else
      _ -> nil
    end
  end

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, mod} <- adapter(), do: mod.fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, mod} <- adapter(), do: mod.fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    with {:ok, mod} <- adapter(), do: mod.fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    with {:ok, mod} <- adapter(), do: mod.create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    with {:ok, mod} <- adapter(), do: mod.update_issue_state(issue_id, state_name)
  end

  @spec fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}
  def fetch_sub_issues(issue_id) do
    with {:ok, mod} <- adapter() do
      if function_exported?(mod, :fetch_sub_issues, 1) do
        mod.fetch_sub_issues(issue_id)
      else
        {:ok, []}
      end
    end
  end

  @doc """
  Returns the adapter module for the configured tracker kind, or an error
  tuple. Never raises — keeping the orchestrator alive when a workflow is
  edited to an unsupported kind is more important than failing fast here,
  since `Config.validate!/0` reports the same error in the polling loop.
  """
  @spec adapter() :: {:ok, module()} | {:error, {:unsupported_tracker_kind, term()}}
  def adapter do
    adapter_for_kind(Config.settings!().tracker.kind)
  end
end
