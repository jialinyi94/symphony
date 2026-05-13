defmodule SymphonyElixir.StagePRTest do
  @moduledoc """
  Truth tables for the PR-aware stages. Each test constructs a WorkItem
  with a precise `PullRequest` state and asserts which stage matches
  (via `StageResolver.resolve/2` against `Stage.defaults()`).

  Together these tests guard the full review-loop state machine.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.{Issue, PullRequest, Stage, StageResolver, WorkItem}
  alias SymphonyElixir.PullRequest.Review

  @reviewer "reviewer-is-all-u-need"

  defp work_item(pr_opts, wi_opts \\ []) do
    issue = %Issue{id: "134", identifier: "134", state: "In Progress", labels: []}

    pr = %PullRequest{
      number: 149,
      head_sha: Keyword.get(pr_opts, :head_sha, "sha-current"),
      state: :open,
      draft: false,
      latest_reviews_by_author: Keyword.get(pr_opts, :reviews, %{}),
      ci_status: Keyword.get(pr_opts, :ci_status, :unknown)
    }

    WorkItem.from_issue(
      issue,
      metadata: Keyword.get(wi_opts, :metadata, %{}),
      attached_pr: pr
    )
  end

  defp review(state, commit_id) do
    %Review{
      author_login: @reviewer,
      state: state,
      commit_id: commit_id,
      submitted_at: ~U[2026-05-13 08:00:00Z]
    }
  end

  defp resolve(wi), do: StageResolver.resolve(wi, Stage.defaults())

  describe "pr_first_review" do
    test "matches an open PR with no review yet" do
      wi = work_item([])
      assert {:ok, %Stage{id: :pr_first_review, role: :reviewer}} = resolve(wi)
    end

    test "does NOT match when reviewer has already reviewed" do
      wi = work_item(reviews: %{@reviewer => review(:commented, "sha-current")})
      {:ok, stage} = resolve(wi)
      refute stage.id == :pr_first_review
    end

    test "does NOT match a draft PR" do
      issue = %Issue{id: "134", identifier: "134", state: "In Progress", labels: []}

      pr = %PullRequest{
        number: 149,
        head_sha: "sha",
        state: :open,
        draft: true,
        latest_reviews_by_author: %{}
      }

      wi = WorkItem.from_issue(issue, attached_pr: pr)
      {:ok, stage} = resolve(wi)
      refute stage.id == :pr_first_review
    end
  end

  describe "pr_changes_requested" do
    test "matches when reviewer requested changes on the current head" do
      wi = work_item(reviews: %{@reviewer => review(:changes_requested, "sha-current")})
      assert {:ok, %Stage{id: :pr_changes_requested, role: :implementer}} = resolve(wi)
    end

    test "does NOT match when the change-request is on a stale commit" do
      wi =
        work_item(
          head_sha: "sha-current",
          reviews: %{@reviewer => review(:changes_requested, "sha-old")}
        )

      {:ok, stage} = resolve(wi)
      refute stage.id == :pr_changes_requested
    end
  end

  describe "pr_ci_failed" do
    test "matches when CI is failing and there is no review (author may not have reviewer feedback yet)" do
      wi = work_item(ci_status: :failure)
      assert {:ok, %Stage{id: :pr_ci_failed, role: :implementer}} = resolve(wi)
    end

    test "matches when CI fails and the reviewer's last review is on the same head" do
      wi =
        work_item(
          head_sha: "sha-current",
          ci_status: :failure,
          reviews: %{@reviewer => review(:approved, "sha-current")}
        )

      # Note: pr_ci_failed wins over pr_record_proof because pr_record_proof
      # requires ci_status ∈ [:success, :neutral].
      assert {:ok, %Stage{id: :pr_ci_failed}} = resolve(wi)
    end

    test "does NOT match when CI is green" do
      wi = work_item(ci_status: :success)
      {:ok, stage} = resolve(wi)
      refute stage.id == :pr_ci_failed
    end
  end

  describe "pr_revalidate" do
    test "matches when author has pushed since the last review" do
      wi =
        work_item(
          head_sha: "sha-new",
          reviews: %{@reviewer => review(:changes_requested, "sha-old")}
        )

      assert {:ok, %Stage{id: :pr_revalidate, role: :reviewer}} = resolve(wi)
    end

    test "does NOT match if the head still equals the last reviewed commit" do
      wi =
        work_item(
          head_sha: "sha-same",
          reviews: %{@reviewer => review(:changes_requested, "sha-same")}
        )

      {:ok, stage} = resolve(wi)
      refute stage.id == :pr_revalidate
    end
  end

  describe "pr_record_proof" do
    test "matches when reviewer approved current head + CI is green + proof not recorded" do
      wi =
        work_item(
          head_sha: "sha-current",
          ci_status: :success,
          reviews: %{@reviewer => review(:approved, "sha-current")}
        )

      assert {:ok, %Stage{id: :pr_record_proof, role: :implementer, max_turns: 3}} = resolve(wi)
    end

    test "does NOT match when proof is already recorded (falls through to pr_awaiting_merge)" do
      wi =
        work_item(
          [
            head_sha: "sha-current",
            ci_status: :success,
            reviews: %{@reviewer => review(:approved, "sha-current")}
          ],
          metadata: %{proof_recorded: true}
        )

      assert {:ok, %Stage{id: :pr_awaiting_merge, role: nil}} = resolve(wi)
    end

    test "neutral CI counts as converged" do
      wi =
        work_item(
          head_sha: "sha-current",
          ci_status: :neutral,
          reviews: %{@reviewer => review(:approved, "sha-current")}
        )

      assert {:ok, %Stage{id: :pr_record_proof}} = resolve(wi)
    end
  end

  describe "pr_awaiting_merge (terminal)" do
    test "matches after proof recorded and no further action needed" do
      wi =
        work_item(
          [
            head_sha: "sha-current",
            ci_status: :success,
            reviews: %{@reviewer => review(:approved, "sha-current")}
          ],
          metadata: %{proof_recorded: true}
        )

      assert {:ok, %Stage{id: :pr_awaiting_merge} = stage} = resolve(wi)
      assert Stage.terminal?(stage)
      assert stage.role == nil
    end
  end

  describe "issue-only WorkItems (no attached PR)" do
    test "fall through PR stages to issue_implement" do
      issue = %Issue{id: "1", identifier: "1", state: "Todo", labels: []}
      wi = WorkItem.from_issue(issue)
      assert {:ok, %Stage{id: :issue_implement}} = resolve(wi)
    end

    test "fall through PR stages to issue_epic_plan when sub-issues present" do
      issue = %Issue{id: "1", identifier: "1", state: "Todo", labels: []}
      wi = WorkItem.from_issue(issue, metadata: %{has_sub_issues: true})
      assert {:ok, %Stage{id: :issue_epic_plan}} = resolve(wi)
    end
  end

  describe "Stage.terminal?/1" do
    test "true only for role=nil stages" do
      assert Stage.terminal?(%Stage{role: nil})
      refute Stage.terminal?(%Stage{role: :implementer})
      refute Stage.terminal?(%Stage{role: :reviewer})
    end
  end
end
