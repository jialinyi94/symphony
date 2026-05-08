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
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  describe "epic dispatch" do
    test "orchestrator dispatches planner variant for an epic with no plan yet" do
      SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn ->
        :ok = SymphonyElixir.OrchestratorTestHelper.tick()
        assert_receive {:agent_run_invoked, "100", opts}, 5_000
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

      assert_receive {:memory_tracker_state_update, "600", "Human Review"}, 5_000
      assert_receive {:memory_tracker_comment, "600", body}, 5_000
      assert body =~ "planner"
    end
  end
end
