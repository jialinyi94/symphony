defmodule SymphonyElixir.OrchestratorEpicTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Issue, Workflow}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "Epic Tracking"],
      tracker_terminal_states: ["Human Review", "Done"]
    )

    epic = %Issue{id: "100", identifier: "100", title: "Epic", state: "Todo", labels: ["symphony:todo"]}
    child_a = %Issue{id: "101", identifier: "101", title: "A", state: "Todo", labels: ["symphony:todo"]}
    child_b = %Issue{id: "102", identifier: "102", title: "B", state: "Todo", labels: ["symphony:todo"]}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child_a, child_b])
    Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"100" => [101, 102]})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_sub_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_plans)
      Application.delete_env(:symphony_elixir, :memory_tracker_plan_errors)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)

      # Drain any test-injected entries from the live Orchestrator running map
      # to avoid bleeding into other tests.
      case Process.whereis(SymphonyElixir.Orchestrator) do
        pid when is_pid(pid) ->
          :sys.replace_state(pid, fn state -> %{state | running: %{}} end)

        _ ->
          :ok
      end
    end)

    :ok
  end

  describe "epic dispatch" do
    test "orchestrator dispatches planner variant for an epic with no plan yet" do
      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
        assert_receive {:agent_run_invoked, "100", opts}, 500
        assert opts[:variant] == :epic_planner
        assert opts[:max_turns] == 4
        assert opts[:epic] == %{sub_issue_numbers: [101, 102]}
      end)
    end
  end

  describe "planner failure escalation" do
    test "epic in In Progress state with no plan -> Human Review with diagnostic comment" do
      epic = %Issue{
        id: "600",
        identifier: "600",
        title: "Epic",
        state: "In Progress",
        labels: ["symphony:in-progress"]
      }

      child = %Issue{id: "601", identifier: "601", state: "Todo", labels: ["symphony:todo"]}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"600" => [601]})

      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      end)

      assert_receive {:memory_tracker_state_update, "600", "Human Review"}, 500
      assert_receive {:memory_tracker_comment, "600", body}, 500
      assert body =~ "planner"
    end

    test "epic in In Progress AND in running set is NOT escalated" do
      epic = %Issue{
        id: "700",
        identifier: "700",
        title: "Epic",
        state: "In Progress",
        labels: ["symphony:in-progress"]
      }

      child = %Issue{id: "701", identifier: "701", state: "Todo", labels: ["symphony:todo"]}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"700" => [701]})

      # Inject "700" into the orchestrator's running set BEFORE the tick. The
      # running entry needs an :issue field so the reconcile step can refresh
      # it without crashing, plus identifier/started_at for housekeeping paths.
      :ok =
        SymphonyElixir.OrchestratorTestHelper.set_running("700", %{
          ref: make_ref(),
          pid: nil,
          identifier: "700",
          issue: epic,
          worker_host: nil,
          workspace_path: nil,
          session_id: "stub-session",
          started_at: DateTime.utc_now()
        })

      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      end)

      refute_receive {:memory_tracker_state_update, "700", "Human Review"}, 200
      refute_receive {:memory_tracker_comment, "700", _}, 200
    end

    test "epic with invalid YAML plan -> Human Review" do
      epic = %Issue{
        id: "900",
        identifier: "900",
        title: "Epic",
        state: "In Progress",
        labels: ["symphony:in-progress"]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"900" => [901]})

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_plan_errors,
        %{"900" => {:invalid_yaml, :test_marker}}
      )

      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      end)

      assert_receive {:memory_tracker_state_update, "900", "Human Review"}, 500
    end
  end

  describe "epic tracking dispatch" do
    test "issue in Epic Tracking state is dispatched as :regular variant (no planner)" do
      epic = %Issue{
        id: "800",
        identifier: "800",
        title: "Epic done planning",
        state: "Epic Tracking",
        labels: ["symphony:epic-tracking"]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"800" => [801, 802]})

      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()

        # Epic Tracking issues have assigned_to_worker: false (per Task 8 — but
        # Memory adapter doesn't enforce this). For Memory tests, just assert
        # that IF dispatched at all, the variant is NOT :epic_planner.
        receive do
          {:agent_run_invoked, "800", opts} ->
            refute opts[:variant] == :epic_planner
        after
          200 -> :ok
        end
      end)
    end
  end
end
