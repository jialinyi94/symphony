defmodule SymphonyElixir.GitHub.EpicPlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.EpicPlan

  defp comment(body, updated_at \\ ~U[2026-05-08 12:00:00Z]) do
    %{id: :erlang.unique_integer([:positive]), body: body, updated_at: updated_at}
  end

  defp valid_block(opts \\ []) do
    """
    Some explanatory prose for the human reader.

    <!-- symphony-plan:v1 -->
    schema: 1
    generated_at: #{Keyword.get(opts, :generated_at, "2026-05-08T12:34:56Z")}
    sub_issues:
      - id: 134
        blocked_by: []
        rationale: "Defines schema."
      - id: 135
        blocked_by: [134]
        rationale: "Migration after schema."
    <!-- /symphony-plan -->
    """
  end

  describe "extract/1" do
    test "returns :no_plan when no comments contain the marker" do
      assert {:error, :no_plan} = EpicPlan.extract([comment("hi"), comment("bye")])
    end

    test "parses a valid block" do
      assert {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert plan.schema == 1
      assert length(plan.sub_issues) == 2
      assert Enum.find(plan.sub_issues, &(&1.id == 135)).blocked_by == [134]
    end

    test "ignores prose before/after the markers" do
      body = "Plan v1 below.\n\n#{valid_block()}\n\n(updates as work progresses)"
      assert {:ok, _plan} = EpicPlan.extract([comment(body)])
    end

    test "returns the latest plan when multiple comments contain blocks" do
      old = comment(valid_block(generated_at: "2026-05-08T10:00:00Z"), ~U[2026-05-08 10:01:00Z])
      new = comment(valid_block(generated_at: "2026-05-08T13:00:00Z"), ~U[2026-05-08 13:01:00Z])
      assert {:ok, plan} = EpicPlan.extract([old, new])
      assert plan.generated_at == ~U[2026-05-08 13:00:00Z]
    end

    test "schema mismatch -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 99
      sub_issues: []
      <!-- /symphony-plan -->
      """

      assert {:error, {:schema_mismatch, 99}} = EpicPlan.extract([comment(bad)])
    end

    test "malformed YAML -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: [oops
      <!-- /symphony-plan -->
      """

      assert {:error, {:invalid_yaml, _}} = EpicPlan.extract([comment(bad)])
    end

    test "missing sub_issues field -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      <!-- /symphony-plan -->
      """

      assert {:error, {:missing_field, "sub_issues"}} = EpicPlan.extract([comment(bad)])
    end

    test "non-integer id -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: "not-a-number"
          blocked_by: []
      <!-- /symphony-plan -->
      """

      assert {:error, {:invalid_sub_issue, _}} = EpicPlan.extract([comment(bad)])
    end
  end

  describe "blockers_for/2" do
    test "returns the declared blocked_by list" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert EpicPlan.blockers_for(plan, 134) == []
      assert EpicPlan.blockers_for(plan, 135) == [134]
    end

    test "returns [] for an id not in the plan" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert EpicPlan.blockers_for(plan, 999) == []
    end
  end

  describe "validate_against_sub_issues/2" do
    test "passes when plan ids match sub_issue numbers" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert :ok = EpicPlan.validate_against_sub_issues(plan, [134, 135])
    end

    test "fails when plan references unknown id" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert {:error, {:plan_references_unknown_ids, [135]}} =
               EpicPlan.validate_against_sub_issues(plan, [134])
    end

    test "fails when plan misses a sub_issue" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert {:error, {:plan_missing_sub_issues, [136]}} =
               EpicPlan.validate_against_sub_issues(plan, [134, 135, 136])
    end
  end
end
