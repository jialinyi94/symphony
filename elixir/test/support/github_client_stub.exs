defmodule SymphonyElixir.GitHub.ClientStub do
  @moduledoc """
  Test-only stub for SymphonyElixir.GitHub.Client. Each function looks up a
  per-process value via Process.put/get; tests configure responses with
  `set/2` in their `setup` block. Default response if unset is an error so
  tests fail loudly when they forget to configure a function.
  """

  alias SymphonyElixir.Issue

  @callback_keys [
    :fetch_candidate_issues,
    :fetch_issues_by_states,
    :fetch_issue_states_by_ids,
    :fetch_sub_issues,
    :fetch_issue_comments,
    :create_comment,
    :set_labels_and_state,
    :fetch_open_pull_requests,
    :fetch_pull_request_reviews,
    :fetch_combined_status,
    :fetch_check_runs_conclusion,
    :fetch_ci_status
  ]

  @spec set(atom(), term()) :: :ok
  def set(key, value) when key in @callback_keys do
    Process.put({__MODULE__, key}, value)
    :ok
  end

  @spec lookup!(atom()) :: term()
  defp lookup!(key) do
    case Process.get({__MODULE__, key}, :__client_stub_unset__) do
      :__client_stub_unset__ -> raise "ClientStub: no response configured for #{inspect(key)}"
      value -> value
    end
  end

  def fetch_candidate_issues, do: lookup!(:fetch_candidate_issues)
  def fetch_issues_by_states(_states), do: lookup!(:fetch_issues_by_states)
  def fetch_issue_states_by_ids(_ids), do: lookup!(:fetch_issue_states_by_ids)
  def fetch_sub_issues(_issue_id), do: lookup!(:fetch_sub_issues)
  def fetch_issue_comments(_issue_id), do: lookup!(:fetch_issue_comments)
  def create_comment(_id, _body), do: lookup!(:create_comment)
  def set_labels_and_state(_id, _labels, _state), do: lookup!(:set_labels_and_state)
  def fetch_open_pull_requests, do: lookup!(:fetch_open_pull_requests)
  def fetch_pull_request_reviews(_pr_number), do: lookup!(:fetch_pull_request_reviews)
  def fetch_combined_status(_sha), do: lookup!(:fetch_combined_status)
  def fetch_check_runs_conclusion(_sha), do: lookup!(:fetch_check_runs_conclusion)
  def fetch_ci_status(_sha), do: lookup!(:fetch_ci_status)

  @spec sample_issue(keyword()) :: Issue.t()
  def sample_issue(overrides \\ []) do
    base = %Issue{
      id: "100",
      identifier: "100",
      title: "stub issue",
      description: "",
      priority: nil,
      state: "Todo",
      branch_name: nil,
      url: "https://github.com/example/example/issues/100",
      assignee_id: nil,
      labels: [],
      blocked_by: [],
      assigned_to_worker: true,
      created_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    struct!(base, overrides)
  end
end
