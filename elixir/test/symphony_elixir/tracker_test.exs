defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: false
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Tracker, Workflow}

  describe "fetch_sub_issues/1 wrapper" do
    test "delegates to the Memory adapter's implementation" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"42" => [43, 44]})
      on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_sub_issues) end)

      assert {:ok, [43, 44]} = Tracker.fetch_sub_issues("42")
    end
  end

  describe "Memory adapter fetch_sub_issues/1" do
    alias SymphonyElixir.Issue
    alias SymphonyElixir.Tracker.Memory

    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      issues = [
        %Issue{id: "100", identifier: "100", title: "Epic", state: "Todo"},
        %Issue{id: "101", identifier: "101", title: "Child A", state: "Todo"},
        %Issue{id: "102", identifier: "102", title: "Child B", state: "Todo"}
      ]

      prev_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
      prev_subs = Application.get_env(:symphony_elixir, :memory_tracker_sub_issues)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
      Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"100" => [101, 102]})

      on_exit(fn ->
        restore_or_delete(:memory_tracker_issues, prev_issues)
        restore_or_delete(:memory_tracker_sub_issues, prev_subs)
      end)

      :ok
    end

    test "returns sub_issue numbers for an epic id" do
      assert {:ok, [101, 102]} = Memory.fetch_sub_issues("100")
    end

    test "returns empty list for an issue with no children" do
      assert {:ok, []} = Memory.fetch_sub_issues("101")
    end
  end

  defp restore_or_delete(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_or_delete(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
