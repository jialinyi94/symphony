defmodule SymphonyElixir.StageDispatchOptionsTest do
  @moduledoc """
  `Stage.dispatch_options/3` is the single bridge between the stage
  abstraction and `AgentRunner.run/3`'s keyword-list opts. The
  orchestrator integration depends on it being deterministic and
  forwarding base_opts faithfully.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.{Issue, PullRequest, Stage, WorkItem}
  alias SymphonyElixir.PullRequest.Review

  defp issue_wi(state, metadata \\ %{}) do
    WorkItem.from_issue(
      %Issue{id: "134", identifier: "134", state: state, labels: []},
      metadata: metadata
    )
  end

  defp pr_wi(opts) do
    issue = %Issue{id: "134", identifier: "134", state: "In Progress", labels: []}

    pr = %PullRequest{
      number: 149,
      head_sha: Keyword.get(opts, :head_sha, "sha"),
      state: :open,
      draft: false,
      latest_reviews_by_author: Keyword.get(opts, :reviews, %{}),
      ci_status: Keyword.get(opts, :ci_status, :unknown)
    }

    WorkItem.from_issue(issue, metadata: Keyword.get(opts, :metadata, %{}), attached_pr: pr)
  end

  describe "issue stages → dispatch_options" do
    test "issue_implement returns {:ok, opts} with :default variant + implementer role" do
      wi = issue_wi("Todo")
      stage = Enum.find(Stage.defaults(), &(&1.id == :issue_implement))

      assert {:ok, opts} = Stage.dispatch_options(stage, wi)
      assert Keyword.fetch!(opts, :variant) == :default
      assert Keyword.fetch!(opts, :role) == :implementer
      assert Keyword.fetch!(opts, :stage_id) == :issue_implement
      refute Keyword.has_key?(opts, :max_turns)
    end

    test "issue_epic_plan returns :epic_planner variant + max_turns 4 + epic context when sub_issue_numbers present" do
      wi = issue_wi("Todo", %{has_sub_issues: true, sub_issue_numbers: [134, 135]})
      stage = Enum.find(Stage.defaults(), &(&1.id == :issue_epic_plan))

      assert {:ok, opts} = Stage.dispatch_options(stage, wi)
      assert Keyword.fetch!(opts, :variant) == :epic_planner
      assert Keyword.fetch!(opts, :max_turns) == 4
      assert Keyword.fetch!(opts, :epic) == %{sub_issue_numbers: [134, 135]}
    end

    test "epic_plan stage omits :epic when sub_issue_numbers missing" do
      wi = issue_wi("Todo", %{has_sub_issues: true})
      stage = Enum.find(Stage.defaults(), &(&1.id == :issue_epic_plan))

      assert {:ok, opts} = Stage.dispatch_options(stage, wi)
      refute Keyword.has_key?(opts, :epic)
    end
  end

  describe "PR stages → dispatch_options" do
    test "pr_first_review → reviewer role + :pr_first_review variant + 2 turn budget" do
      wi = pr_wi([])
      stage = Enum.find(Stage.defaults(), &(&1.id == :pr_first_review))

      assert {:ok, opts} = Stage.dispatch_options(stage, wi)
      assert opts[:role] == :reviewer
      assert opts[:variant] == :pr_first_review
      assert opts[:max_turns] == 2
    end

    test "pr_record_proof → implementer role + :pr_record_proof variant + 3 turn budget" do
      wi =
        pr_wi(
          head_sha: "h",
          reviews: %{"reviewer-is-all-u-need" => %Review{author_login: "reviewer-is-all-u-need", state: :approved, commit_id: "h"}},
          ci_status: :success
        )

      stage = Enum.find(Stage.defaults(), &(&1.id == :pr_record_proof))
      assert {:ok, opts} = Stage.dispatch_options(stage, wi)
      assert opts[:role] == :implementer
      assert opts[:variant] == :pr_record_proof
      assert opts[:max_turns] == 3
    end
  end

  describe "terminal stages" do
    test "pr_awaiting_merge → {:skip, stage}" do
      wi = pr_wi([])
      stage = Enum.find(Stage.defaults(), &(&1.id == :pr_awaiting_merge))

      assert {:skip, ^stage} = Stage.dispatch_options(stage, wi)
    end

    test "any stage with role=nil is treated as terminal" do
      wi = pr_wi([])
      stage = %Stage{id: :custom_terminal, role: nil}

      assert {:skip, ^stage} = Stage.dispatch_options(stage, wi)
    end
  end

  describe "base_opts forwarding" do
    test "preserves :attempt and :worker_host from base_opts" do
      wi = issue_wi("Todo")
      stage = Enum.find(Stage.defaults(), &(&1.id == :issue_implement))

      base = [attempt: 2, worker_host: "host-1.example"]
      assert {:ok, opts} = Stage.dispatch_options(stage, wi, base)

      assert Keyword.fetch!(opts, :attempt) == 2
      assert Keyword.fetch!(opts, :worker_host) == "host-1.example"
    end

    test "stage-derived keys override base_opts when they conflict" do
      wi = pr_wi([])
      stage = Enum.find(Stage.defaults(), &(&1.id == :pr_first_review))

      base = [variant: :wrong, role: :wrong, max_turns: 999]
      assert {:ok, opts} = Stage.dispatch_options(stage, wi, base)

      assert Keyword.fetch!(opts, :variant) == :pr_first_review
      assert Keyword.fetch!(opts, :role) == :reviewer
      assert Keyword.fetch!(opts, :max_turns) == 2
    end
  end
end
