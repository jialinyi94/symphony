defmodule SymphonyElixir.StageTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Issue, Stage, WorkItem}

  defp work_item(state, metadata \\ %{}) do
    WorkItem.from_issue(
      %Issue{id: "i1", identifier: "134", state: state, labels: []},
      metadata: metadata
    )
  end

  describe "applies?/2" do
    test "nil :when_fun is treated as unconditional match" do
      assert Stage.applies?(%Stage{when_fun: nil}, work_item("Todo"))
    end

    test "function predicate's return value is the answer" do
      truthy = %Stage{when_fun: fn _wi -> true end}
      falsy = %Stage{when_fun: fn _wi -> false end}

      assert Stage.applies?(truthy, work_item("Todo"))
      refute Stage.applies?(falsy, work_item("Todo"))
    end

    test "non-boolean return values do not match (only literal `true`)" do
      flaky = %Stage{when_fun: fn _wi -> :maybe end}
      refute Stage.applies?(flaky, work_item("Todo"))
    end

    test "non-function predicate returns false defensively" do
      bogus = %Stage{when_fun: "not-a-function"}
      refute Stage.applies?(bogus, work_item("Todo"))
    end
  end

  defp stage_by_id(id) do
    Enum.find(Stage.defaults(), &(&1.id == id))
  end

  describe "defaults/0" do
    test "includes issue_epic_plan and issue_implement" do
      ids = Enum.map(Stage.defaults(), & &1.id)
      assert :issue_epic_plan in ids
      assert :issue_implement in ids
    end

    test "issue_implement is the last (catch-all) entry" do
      assert List.last(Stage.defaults()).id == :issue_implement
    end

    test "issue_epic_plan has :epic_planner variant, role implementer, max_turns 4" do
      epic_plan = stage_by_id(:issue_epic_plan)

      assert epic_plan.role == :implementer
      assert epic_plan.prompt_variant == :epic_planner
      assert epic_plan.max_turns == 4
    end

    test "issue_implement is a catch-all with :default variant and no turn override" do
      implement = stage_by_id(:issue_implement)

      assert implement.role == :implementer
      assert implement.prompt_variant == :default
      assert implement.max_turns == nil
      assert implement.when_fun == nil
    end
  end

  describe "issue_epic_plan predicate (Orchestrator parity)" do
    setup do
      {:ok, stage: stage_by_id(:issue_epic_plan)}
    end

    test "matches Todo + has_sub_issues", %{stage: stage} do
      assert Stage.applies?(stage, work_item("Todo", %{has_sub_issues: true}))
    end

    test "matches In Progress + has_sub_issues", %{stage: stage} do
      assert Stage.applies?(stage, work_item("In Progress", %{has_sub_issues: true}))
    end

    test "does NOT match Epic Tracking (planner already ran)", %{stage: stage} do
      refute Stage.applies?(stage, work_item("Epic Tracking", %{has_sub_issues: true}))
    end

    test "does NOT match when has_sub_issues is missing or false", %{stage: stage} do
      refute Stage.applies?(stage, work_item("Todo"))
      refute Stage.applies?(stage, work_item("Todo", %{has_sub_issues: false}))
    end

    test "case-insensitive state matching", %{stage: stage} do
      refute Stage.applies?(stage, work_item("EPIC TRACKING", %{has_sub_issues: true}))
      assert Stage.applies?(stage, work_item("TODO", %{has_sub_issues: true}))
    end
  end
end
