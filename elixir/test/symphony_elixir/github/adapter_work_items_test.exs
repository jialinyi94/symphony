defmodule SymphonyElixir.GitHub.AdapterWorkItemsTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{PullRequest, WorkItem}
  alias SymphonyElixir.GitHub.{Adapter, ClientStub}
  alias SymphonyElixir.PullRequest.Review

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/name",
      tracker_api_token: "test"
    )

    prev_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, ClientStub)

    on_exit(fn ->
      if prev_client do
        Application.put_env(:symphony_elixir, :github_client_module, prev_client)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  defp issue(id, opts \\ []) do
    ClientStub.sample_issue(Keyword.merge([id: id, identifier: id, state: "Todo", labels: ["symphony:todo"]], opts))
  end

  defp pr(opts) do
    %PullRequest{
      number: Keyword.fetch!(opts, :number),
      head_sha: Keyword.fetch!(opts, :head_sha),
      head_ref: Keyword.get(opts, :head_ref, "symphony/issue-#{Keyword.fetch!(opts, :linked_issue)}"),
      state: :open,
      draft: false,
      url: "https://github.com/owner/name/pull/#{Keyword.fetch!(opts, :number)}",
      author_login: "jialinyi94",
      linked_issue_number: Keyword.fetch!(opts, :linked_issue),
      latest_reviews_by_author: %{},
      reviews: [],
      ci_status: :unknown
    }
  end

  test "fetch_work_items returns issue-only WorkItems when there are no open PRs" do
    ClientStub.set(:fetch_candidate_issues, {:ok, [issue("134"), issue("142")]})
    ClientStub.set(:fetch_open_pull_requests, {:ok, []})
    ClientStub.set(:fetch_sub_issues, {:ok, []})

    assert {:ok, items} = Adapter.fetch_work_items()
    assert length(items) == 2
    assert Enum.all?(items, fn %WorkItem{} = wi -> wi.attached_pr == nil end)
    assert Enum.all?(items, fn wi -> wi.tracker_kind == :github end)
    assert Enum.all?(items, fn wi -> WorkItem.metadata(wi, :has_sub_issues) == false end)
  end

  test "fetch_work_items attaches a PR to its linked issue with reviews + CI preloaded" do
    ClientStub.set(:fetch_candidate_issues, {:ok, [issue("134"), issue("142")]})

    ClientStub.set(
      :fetch_open_pull_requests,
      {:ok, [pr(number: 149, head_sha: "sha-A", linked_issue: 134)]}
    )

    ClientStub.set(
      :fetch_pull_request_reviews,
      {:ok,
       [
         %Review{author_login: "reviewer-is-all-u-need", state: :approved, commit_id: "sha-A", submitted_at: ~U[2026-05-13 08:00:00Z]}
       ]}
    )

    ClientStub.set(:fetch_combined_status, {:ok, :success})
    ClientStub.set(:fetch_sub_issues, {:ok, []})

    assert {:ok, items} = Adapter.fetch_work_items()
    assert length(items) == 2

    issue134 = Enum.find(items, &(&1.issue.id == "134"))
    issue142 = Enum.find(items, &(&1.issue.id == "142"))

    assert %PullRequest{number: 149, ci_status: :success} = WorkItem.pull_request(issue134)
    assert WorkItem.pr_open_for_review?(issue134)
    assert PullRequest.approved_by?(WorkItem.pull_request(issue134), "reviewer-is-all-u-need")
    assert WorkItem.pull_request(issue142) == nil
  end

  test "fetch_work_items falls back to issue-only when fetch_open_pull_requests fails" do
    ClientStub.set(:fetch_candidate_issues, {:ok, [issue("134")]})
    ClientStub.set(:fetch_open_pull_requests, {:error, {:github_http_error, 500, "boom"}})
    ClientStub.set(:fetch_sub_issues, {:ok, []})

    assert {:ok, [%WorkItem{attached_pr: nil} = wi]} = Adapter.fetch_work_items()
    assert wi.issue.id == "134"
  end

  test "fetch_work_items pre-populates :has_sub_issues for epic detection" do
    ClientStub.set(:fetch_candidate_issues, {:ok, [issue("100", state: "Todo")]})
    ClientStub.set(:fetch_open_pull_requests, {:ok, []})
    ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})

    assert {:ok, [wi]} = Adapter.fetch_work_items()
    assert WorkItem.metadata(wi, :has_sub_issues) == true
  end

  test "associate_prs_to_issues: branch-name fallback when PR body has no Closes link" do
    ClientStub.set(:fetch_candidate_issues, {:ok, [issue("134")]})

    pr_no_link = %PullRequest{
      number: 149,
      head_sha: "sha-A",
      head_ref: "symphony/issue-134",
      state: :open,
      draft: false,
      linked_issue_number: nil,
      latest_reviews_by_author: %{},
      reviews: []
    }

    ClientStub.set(:fetch_open_pull_requests, {:ok, [pr_no_link]})
    ClientStub.set(:fetch_pull_request_reviews, {:ok, []})
    ClientStub.set(:fetch_combined_status, {:ok, :pending})
    ClientStub.set(:fetch_sub_issues, {:ok, []})

    assert {:ok, [wi]} = Adapter.fetch_work_items()
    assert %PullRequest{number: 149} = WorkItem.pull_request(wi)
  end
end
