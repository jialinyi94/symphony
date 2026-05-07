defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.

  State is encoded as `symphony:*` labels per `SymphonyElixir.GitHub.StateMapping`.
  Terminal states additionally close the issue on GitHub; non-terminal active
  states reopen if needed.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.Client, GitHub.StateMapping}

  @impl true
  def kind, do: "github"

  @impl true
  def secret_env_var, do: "GITHUB_TOKEN"

  @impl true
  def validate_config(tracker) do
    if is_binary(tracker.api_key) do
      :ok
    else
      {:error, :missing_github_token}
    end
  end

  @impl true
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @impl true
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @impl true
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    settings = Config.settings!().tracker

    with {:ok, [issue]} <- client_module().fetch_issue_states_by_ids([issue_id]) do
      target_label = StateMapping.state_to_label(state_name)
      ops = StateMapping.label_ops_for_state(state_name, issue.labels)
      next_labels = apply_label_ops(issue.labels, ops, target_label)
      next_state = github_state_for(state_name, settings.terminal_states)

      client_module().set_labels_and_state(issue_id, next_labels, next_state)
    else
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_label_ops(current, ops, target_label) do
    after_removes =
      Enum.reduce(ops, current, fn
        {:remove, label}, acc -> List.delete(acc, label)
        _, acc -> acc
      end)

    if target_label in after_removes, do: after_removes, else: [target_label | after_removes]
  end

  defp github_state_for(state_name, terminal_states) do
    if state_name in terminal_states, do: :closed, else: :open
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
