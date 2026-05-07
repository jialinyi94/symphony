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

  @callback kind() :: String.t()
  @callback validate_config(term()) :: :ok | {:error, term()}
  @callback secret_env_var() :: String.t() | nil

  @optional_callbacks secret_env_var: 0

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
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec adapter() :: module()
  def adapter do
    kind = Config.settings!().tracker.kind

    case adapter_for_kind(kind) do
      {:ok, mod} ->
        mod

      {:error, _} ->
        raise ArgumentError,
          message: "Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}"
    end
  end
end
