defmodule SymphonyElixir.OrchestratorTestHelper do
  @moduledoc """
  Test-only orchestration helper. Drives synchronous polling ticks and
  installs a fake agent runner that captures invocations and forwards them
  to the test process recorded via `:memory_tracker_recipient`.
  """

  alias SymphonyElixir.Orchestrator

  @doc """
  Runs `fun` with a stubbed agent runner module installed. The stub captures
  invocations and forwards them as `{:agent_run_invoked, issue_id, opts}`
  to whatever process is configured under
  `Application.get_env(:symphony_elixir, :memory_tracker_recipient)`.
  """
  def with_stubbed_agent_runner(fun) when is_function(fun, 0) do
    prev = Application.get_env(:symphony_elixir, :agent_runner_module)
    Application.put_env(:symphony_elixir, :agent_runner_module, __MODULE__.StubAgentRunner)

    try do
      fun.()
    after
      restore_agent_runner_module(prev)
    end
  end

  defp restore_agent_runner_module(nil),
    do: Application.delete_env(:symphony_elixir, :agent_runner_module)

  defp restore_agent_runner_module(module),
    do: Application.put_env(:symphony_elixir, :agent_runner_module, module)

  @doc """
  Drive one polling tick synchronously. Returns `:ok` once the orchestrator
  has finished processing the dispatch loop for this tick.
  """
  def tick do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) -> GenServer.call(pid, :force_tick, 15_000)
      nil -> raise "Orchestrator GenServer is not running"
    end
  end

  @doc """
  Inject a fake entry into the orchestrator's `running` map so tests can
  simulate an in-flight worker for `issue_id`. Uses `:sys.replace_state/2`
  to mutate the live GenServer state synchronously.
  """
  def set_running(issue_id, metadata \\ %{}) when is_binary(issue_id) and is_map(metadata) do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          %{state | running: Map.put(state.running, issue_id, metadata)}
        end)

        :ok

      nil ->
        raise "Orchestrator GenServer is not running"
    end
  end

  @doc """
  Simulates a successful planner run. Flips the epic's state to "Epic Tracking"
  in the memory_tracker_issues list, and injects a plan into :memory_tracker_plans
  so the next polling tick sees blocked_by populated on children.

  Also re-derives blocked_by on all issues based on the plan so that the
  orchestrator's gating logic sees correct blocker states from the start.
  """
  def simulate_planner_completion(opts) do
    epic_id = Keyword.fetch!(opts, :epic_id)
    raw_plan = Keyword.fetch!(opts, :plan)

    # Convert raw_plan (list of %{id: int, blocked_by: [int]}) to the EpicPlan shape
    # that GitHub.EpicPlan.extract/1 returns.
    plan = %{
      schema: 1,
      generated_at: nil,
      sub_issues: Enum.map(raw_plan, fn entry ->
        %{
          id: Map.fetch!(entry, :id),
          blocked_by: Map.fetch!(entry, :blocked_by),
          rationale: Map.get(entry, :rationale)
        }
      end)
    }

    # Inject the plan
    plans = Application.get_env(:symphony_elixir, :memory_tracker_plans, %{})
    new_plans = Map.put(plans, epic_id, plan)
    Application.put_env(:symphony_elixir, :memory_tracker_plans, new_plans)

    # Flip the epic's state to Epic Tracking
    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])

    updated_issues =
      Enum.map(issues, fn issue ->
        if issue.id == epic_id do
          %{issue | state: "Epic Tracking", labels: ["symphony:epic-tracking"]}
        else
          issue
        end
      end)

    # Re-derive blocked_by for all issues based on the updated plan and states
    final_issues = recompute_blocked_by(updated_issues, new_plans)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, final_issues)
  end

  @doc """
  Mutates one issue's state in :memory_tracker_issues, then re-derives
  blocked_by for all issues based on the current plan so that any issues
  blocked by this one see the updated blocker state.
  """
  def set_state(issue_id, new_state, opts \\ []) do
    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
    plans = Application.get_env(:symphony_elixir, :memory_tracker_plans, %{})

    new_labels =
      Keyword.get(
        opts,
        :labels_for_state,
        [SymphonyElixir.GitHub.StateMapping.state_to_label(new_state)]
      )

    updated_issues =
      Enum.map(issues, fn issue ->
        if issue.id == issue_id do
          %{issue | state: new_state, labels: new_labels}
        else
          issue
        end
      end)

    # Re-derive blocked_by for all issues so blockers of this issue reflect new state
    final_issues = recompute_blocked_by(updated_issues, plans)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, final_issues)
  end

  # Recomputes the blocked_by list for every issue by consulting the plan
  # stored in :memory_tracker_plans. Each blocker entry becomes %{state: <current_state>}
  # based on the live issue list.
  defp recompute_blocked_by(issues, plans) do
    state_by_id = Map.new(issues, &{&1.id, &1.state})

    Enum.map(issues, fn issue ->
      blockers = blockers_for_issue(issue.id, plans, state_by_id)

      if blockers == [] and issue.blocked_by == [] do
        issue
      else
        %{issue | blocked_by: blockers}
      end
    end)
  end

  # Returns a list of %{state: blocker_state} maps for a given issue_id,
  # derived from all plans in the plans map.
  defp blockers_for_issue(issue_id, plans, state_by_id) do
    plans
    |> Enum.flat_map(fn {_epic_id, plan} ->
      case Enum.find(plan.sub_issues, &(Integer.to_string(&1.id) == issue_id)) do
        nil ->
          []

        %{blocked_by: blocker_ids} ->
          Enum.map(blocker_ids, fn n ->
            %{state: Map.get(state_by_id, Integer.to_string(n), "Todo")}
          end)
      end
    end)
  end

  defmodule StubAgentRunner do
    @moduledoc false

    # Mirrors `SymphonyElixir.AgentRunner.run/3`:
    #   run(issue, codex_update_recipient \\ nil, opts \\ [])
    def run(issue, codex_update_recipient \\ nil, opts \\ [])

    def run(%{id: issue_id} = _issue, _codex_update_recipient, opts) when is_binary(issue_id) do
      send(test_pid(), {:agent_run_invoked, issue_id, opts})
      :ok
    end

    def run(issue, _codex_update_recipient, opts) do
      send(test_pid(), {:agent_run_invoked, inspect(issue), opts})
      :ok
    end

    defp test_pid do
      case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
        pid when is_pid(pid) ->
          pid

        _ ->
          raise "OrchestratorTestHelper.StubAgentRunner: no test recipient pid configured"
      end
    end
  end
end
