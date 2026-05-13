defmodule SymphonyElixir.WorkItemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Issue, WorkItem}

  defp issue(overrides \\ %{}) do
    base = %Issue{
      id: "i1",
      identifier: "134",
      title: "Cross-sectional panel infra",
      description: "Build panel framework.",
      state: "Todo",
      labels: ["priority/p1", "symphony:todo"]
    }

    struct!(base, overrides)
  end

  describe "from_issue/2" do
    test "wraps an Issue with sensible defaults" do
      wi = WorkItem.from_issue(issue())

      assert wi.issue.identifier == "134"
      assert wi.tracker_kind == nil
      assert wi.attached_pr == nil
      assert wi.metadata == %{}
    end

    test "honors :tracker_kind, :metadata, :attached_pr options" do
      wi =
        WorkItem.from_issue(issue(),
          tracker_kind: :github,
          metadata: %{has_sub_issues: true, sub_issue_count: 3},
          attached_pr: %{number: 149, head_sha: "abc123"}
        )

      assert wi.tracker_kind == :github
      assert wi.metadata.has_sub_issues == true
      assert wi.metadata.sub_issue_count == 3
      assert wi.attached_pr.number == 149
    end

    test "non-map :metadata is coerced to empty map" do
      wi = WorkItem.from_issue(issue(), metadata: nil)
      assert wi.metadata == %{}
    end
  end

  describe "issue_state/1 and normalized_issue_state/1" do
    test "returns raw and normalized issue state" do
      wi = WorkItem.from_issue(issue(state: "  In Progress  "))

      assert WorkItem.issue_state(wi) == "  In Progress  "
      assert WorkItem.normalized_issue_state(wi) == "in progress"
    end

    test "returns nil when no underlying issue" do
      empty = %WorkItem{}
      assert WorkItem.issue_state(empty) == nil
      assert WorkItem.normalized_issue_state(empty) == nil
    end

    test "handles non-binary state defensively" do
      wi = WorkItem.from_issue(issue(state: nil))
      assert WorkItem.normalized_issue_state(wi) == nil
    end
  end

  describe "has_attached_pr?/1" do
    test "false when no PR attached" do
      refute WorkItem.has_attached_pr?(WorkItem.from_issue(issue()))
    end

    test "true when PR metadata is present" do
      wi = WorkItem.from_issue(issue(), attached_pr: %{number: 1})
      assert WorkItem.has_attached_pr?(wi)
    end
  end

  describe "metadata/3" do
    test "reads from metadata map with default fallback" do
      wi = WorkItem.from_issue(issue(), metadata: %{has_sub_issues: true})

      assert WorkItem.metadata(wi, :has_sub_issues) == true
      assert WorkItem.metadata(wi, :missing) == nil
      assert WorkItem.metadata(wi, :missing, :fallback) == :fallback
    end
  end
end
