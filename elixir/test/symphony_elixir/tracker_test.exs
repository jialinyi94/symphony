defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Tracker, Workflow}

  describe "fetch_sub_issues/1 with adapter that doesn't implement it" do
    test "falls back to {:ok, []} for the Memory adapter" do
      # Memory tracker is the default for tests; before subsequent tasks it
      # doesn't implement fetch_sub_issues. The Tracker module's wrapper
      # should detect the missing callback and return {:ok, []}.
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      assert {:ok, []} = Tracker.fetch_sub_issues("any-id")
    end
  end
end
