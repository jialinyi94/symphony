defmodule SymphonyElixir.StageResolverTest do
  @moduledoc """
  Behavior parity guard: combinations of (issue state × has_sub_issues)
  must produce the same dispatch variant + max_turns as the current
  `Orchestrator.build_run_opts/2` logic. When PR2 wires the resolver in,
  this test prevents the two code paths from drifting.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.{Issue, Stage, StageResolver, WorkItem}

  defp work_item(state, metadata \\ %{}) do
    WorkItem.from_issue(
      %Issue{id: "i1", identifier: "134", state: state, labels: []},
      metadata: metadata
    )
  end

  describe "resolve/2 against custom stage lists" do
    test "picks first applicable stage in list order" do
      stages = [
        %Stage{id: :a, when_fun: fn _ -> false end, prompt_variant: :a_v},
        %Stage{id: :b, when_fun: fn _ -> true end, prompt_variant: :b_v},
        %Stage{id: :c, when_fun: fn _ -> true end, prompt_variant: :c_v}
      ]

      assert {:ok, %Stage{id: :b}} = StageResolver.resolve(work_item("Todo"), stages)
    end

    test "falls through to a nil-predicate catch-all" do
      stages = [
        %Stage{id: :selective, when_fun: fn _ -> false end},
        %Stage{id: :catch_all, when_fun: nil}
      ]

      assert {:ok, %Stage{id: :catch_all}} = StageResolver.resolve(work_item("Todo"), stages)
    end

    test "returns :no_matching_stage when nothing applies" do
      stages = [%Stage{id: :selective, when_fun: fn _ -> false end}]
      assert StageResolver.resolve(work_item("Todo"), stages) == {:error, :no_matching_stage}
    end

    test "returns :no_matching_stage for empty list" do
      assert StageResolver.resolve(work_item("Todo"), []) == {:error, :no_matching_stage}
    end
  end

  describe "resolve/2 against Stage.defaults() — Orchestrator parity" do
    # See test names below for the full (state × has_sub_issues) truth
    # table; it mirrors `Orchestrator.epic_classification/1` exactly.

    test "Todo + has_sub_issues → issue_epic_plan (variant :epic_planner, max_turns 4)" do
      wi = work_item("Todo", %{has_sub_issues: true})
      assert {:ok, stage} = StageResolver.resolve(wi, Stage.defaults())
      assert stage.id == :issue_epic_plan
      assert stage.prompt_variant == :epic_planner
      assert stage.max_turns == 4
    end

    test "In Progress + has_sub_issues → issue_epic_plan" do
      wi = work_item("In Progress", %{has_sub_issues: true})
      assert {:ok, %Stage{id: :issue_epic_plan}} = StageResolver.resolve(wi, Stage.defaults())
    end

    test "Epic Tracking + has_sub_issues → issue_implement (planner already ran)" do
      wi = work_item("Epic Tracking", %{has_sub_issues: true})
      assert {:ok, stage} = StageResolver.resolve(wi, Stage.defaults())
      assert stage.id == :issue_implement
      assert stage.prompt_variant == :default
    end

    test "Todo without sub-issues → issue_implement" do
      wi = work_item("Todo", %{has_sub_issues: false})
      assert {:ok, %Stage{id: :issue_implement}} = StageResolver.resolve(wi, Stage.defaults())
    end

    test "Todo with no metadata at all → issue_implement (default has_sub_issues=false)" do
      wi = work_item("Todo")
      assert {:ok, %Stage{id: :issue_implement}} = StageResolver.resolve(wi, Stage.defaults())
    end

    test "defaults() never returns :no_matching_stage (catch-all guarantee)" do
      for state <- ["Todo", "In Progress", "Epic Tracking", "Done", "Canceled", "weird-state", ""] do
        for meta <- [%{}, %{has_sub_issues: true}, %{has_sub_issues: false}] do
          wi = work_item(state, meta)

          assert match?({:ok, %Stage{}}, StageResolver.resolve(wi, Stage.defaults())),
                 "expected match for state=#{inspect(state)} meta=#{inspect(meta)}"
        end
      end
    end
  end
end
