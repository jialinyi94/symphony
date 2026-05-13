defmodule SymphonyElixir.PullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PullRequest
  alias SymphonyElixir.PullRequest.Review

  defp review(login, state, commit_id) do
    %Review{
      author_login: login,
      state: state,
      commit_id: commit_id,
      submitted_at: ~U[2026-05-13 08:00:00Z]
    }
  end

  defp pr(opts \\ []) do
    %PullRequest{
      number: 149,
      head_sha: Keyword.get(opts, :head_sha, "sha-2"),
      head_ref: "symphony/issue-134",
      state: Keyword.get(opts, :state, :open),
      draft: Keyword.get(opts, :draft, false),
      url: "https://github.com/x/y/pull/149",
      latest_reviews_by_author: Keyword.get(opts, :reviews, %{}),
      ci_status: Keyword.get(opts, :ci_status, :unknown)
    }
  end

  describe "Review.normalize_state/1" do
    test "maps known states to atoms" do
      assert Review.normalize_state("APPROVED") == :approved
      assert Review.normalize_state("CHANGES_REQUESTED") == :changes_requested
      assert Review.normalize_state("COMMENTED") == :commented
      assert Review.normalize_state("DISMISSED") == :dismissed
      assert Review.normalize_state("PENDING") == :pending
    end

    test "unknown strings default to :commented" do
      assert Review.normalize_state("WAT") == :commented
    end

    test "non-string defaults to :commented" do
      assert Review.normalize_state(nil) == :commented
      assert Review.normalize_state(:approved) == :commented
    end
  end

  describe "latest_review_from/2" do
    test "returns the review keyed by login" do
      r = review("reviewer-is-all-u-need", :approved, "sha-2")
      pr = pr(reviews: %{"reviewer-is-all-u-need" => r})

      assert PullRequest.latest_review_from(pr, "reviewer-is-all-u-need") == r
    end

    test "returns nil when login is absent" do
      assert PullRequest.latest_review_from(pr(), "anyone") == nil
    end
  end

  describe "approved_by?/2 (head-aware)" do
    test "true when latest review is :approved on current head" do
      r = review("rev", :approved, "sha-2")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      assert PullRequest.approved_by?(pr, "rev")
    end

    test "false when latest review is :approved but on stale commit" do
      r = review("rev", :approved, "sha-1")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      refute PullRequest.approved_by?(pr, "rev")
    end

    test "false when latest review is not :approved" do
      r = review("rev", :changes_requested, "sha-2")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      refute PullRequest.approved_by?(pr, "rev")
    end

    test "false when there is no review" do
      refute PullRequest.approved_by?(pr(), "rev")
    end
  end

  describe "changes_requested_by?/2 (head-aware)" do
    test "true only when CHANGES_REQUESTED on the current head" do
      r = review("rev", :changes_requested, "sha-2")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      assert PullRequest.changes_requested_by?(pr, "rev")
    end

    test "false when on stale head (author pushed since)" do
      r = review("rev", :changes_requested, "sha-1")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      refute PullRequest.changes_requested_by?(pr, "rev")
    end
  end

  describe "author_pushed_since?/2" do
    test "true when latest review's commit differs from head_sha" do
      r = review("rev", :changes_requested, "sha-1")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      assert PullRequest.author_pushed_since?(pr, "rev")
    end

    test "false when latest review is on the current head" do
      r = review("rev", :approved, "sha-2")
      pr = pr(head_sha: "sha-2", reviews: %{"rev" => r})

      refute PullRequest.author_pushed_since?(pr, "rev")
    end

    test "false when there is no prior review" do
      refute PullRequest.author_pushed_since?(pr(), "rev")
    end
  end
end
