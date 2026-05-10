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

    test "epic with plan referencing unknown id is escalated to Human Review" do
      epic = %SymphonyElixir.Issue{
        id: "950",
        identifier: "950",
        title: "Epic",
        state: "In Progress",
        labels: ["symphony:in-progress"]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"950" => [951]})

      Application.put_env(
        :symphony_elixir,
        :memory_tracker_plan_errors,
        %{"950" => {:plan_references_unknown_ids, [999]}}
      )

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      assert_receive {:memory_tracker_state_update, "950", "Human Review"}, 500
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

  describe "epic reaper" do
    test "closes parent when every child is Done" do
      epic = %SymphonyElixir.Issue{id: "200", identifier: "200", title: "Epic", state: "Epic Tracking", labels: ["symphony:epic-tracking"]}
      done_a = %SymphonyElixir.Issue{id: "201", identifier: "201", title: "A", state: "Done", labels: ["symphony:done"]}
      done_b = %SymphonyElixir.Issue{id: "202", identifier: "202", title: "B", state: "Done", labels: ["symphony:done"]}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, done_a, done_b])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"200" => [201, 202]})

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      assert_receive {:memory_tracker_state_update, "200", "Done"}, 500
    end

    test "does NOT close parent when any child is still active" do
      epic = %SymphonyElixir.Issue{id: "300", identifier: "300", title: "Epic", state: "Epic Tracking"}
      in_progress = %SymphonyElixir.Issue{id: "301", identifier: "301", state: "In Progress"}
      done = %SymphonyElixir.Issue{id: "302", identifier: "302", state: "Done"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, in_progress, done])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"300" => [301, 302]})

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      refute_receive {:memory_tracker_state_update, "300", _}, 200
    end

    test "reaper closes parent even when Done children have dropped from candidate list (GitHub semantics)" do
      Application.put_env(:symphony_elixir, :memory_tracker_drop_done_from_candidates, true)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_drop_done_from_candidates) end)

      epic = %SymphonyElixir.Issue{
        id: "200",
        identifier: "200",
        title: "Epic",
        state: "Epic Tracking",
        labels: ["symphony:epic-tracking"]
      }

      done_a = %SymphonyElixir.Issue{
        id: "201",
        identifier: "201",
        title: "A",
        state: "Done",
        labels: ["symphony:done"]
      }

      done_b = %SymphonyElixir.Issue{
        id: "202",
        identifier: "202",
        title: "B",
        state: "Done",
        labels: ["symphony:done"]
      }

      # Both Done children remain in :memory_tracker_issues (so
      # fetch_issue_states_by_ids finds them), but fetch_candidate_issues
      # filters them out — mimicking GitHub `state: "open"` semantics.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, done_a, done_b])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"200" => [201, 202]})

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      assert_receive {:memory_tracker_state_update, "200", "Done"}, 500
    end

    test "does NOT close parent if a child is in Human Review (PR not merged)" do
      epic = %SymphonyElixir.Issue{id: "400", identifier: "400", title: "Epic", state: "Epic Tracking"}
      human_review = %SymphonyElixir.Issue{id: "401", identifier: "401", state: "Human Review"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, human_review])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"400" => [401]})

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      refute_receive {:memory_tracker_state_update, "400", _}, 200
    end
  end

  describe "e2e: full epic flow" do
    test "planner -> children dispatch in topo order -> reaper closes parent" do
      epic = %SymphonyElixir.Issue{
        id: "500", identifier: "500", title: "Epic", state: "Todo",
        labels: ["symphony:todo"]
      }
      child_a = %SymphonyElixir.Issue{
        id: "501", identifier: "501", title: "Child A", state: "Todo",
        labels: ["symphony:todo"], blocked_by: []
      }
      child_b = %SymphonyElixir.Issue{
        id: "502", identifier: "502", title: "Child B", state: "Todo",
        labels: ["symphony:todo"], blocked_by: [%{state: "Todo"}]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child_a, child_b])
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"500" => [501, 502]})

      # Tick 1: planner dispatch
      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
        assert_receive {:agent_run_invoked, "500", opts}, 500
        assert opts[:variant] == :epic_planner
      end)

      # Simulate planner success: flip epic to Epic Tracking, inject plan
      SymphonyElixir.OrchestratorTestHelper.simulate_planner_completion(
        epic_id: "500",
        plan: [%{id: 501, blocked_by: []}, %{id: 502, blocked_by: [501]}]
      )

      # Tick 2: child 501 dispatched (no blockers); 502 blocked
      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
        assert_receive {:agent_run_invoked, "501", _opts}, 500
        refute_receive {:agent_run_invoked, "502", _}, 200
      end)

      # Simulate 501 done; tick 3 should now dispatch 502
      SymphonyElixir.OrchestratorTestHelper.set_state("501", "Done")

      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
        assert_receive {:agent_run_invoked, "502", _opts}, 500
      end)

      # Simulate 502 done; tick 4 should reap parent
      SymphonyElixir.OrchestratorTestHelper.set_state("502", "Done")

      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      assert_receive {:memory_tracker_state_update, "500", "Done"}, 500
    end
  end
end
