defmodule SymphonyElixir.GitHub.StateMappingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.StateMapping

  @active ["Todo", "In Progress", "Human Review"]
  @terminal ["Done", "Cancelled"]

  describe "state_to_label/1" do
    test "lowercases and hyphenates with prefix" do
      assert StateMapping.state_to_label("In Progress") == "symphony:in-progress"
      assert StateMapping.state_to_label("Todo") == "symphony:todo"
      assert StateMapping.state_to_label("Human Review") == "symphony:human-review"
    end

    test "collapses internal whitespace runs" do
      assert StateMapping.state_to_label("Human  Review") == "symphony:human-review"
    end
  end

  describe "state_from_labels/4 (conservative policy)" do
    test "decodes a present symphony:* label" do
      labels = ["bug", "symphony:in-progress"]
      assert StateMapping.state_from_labels(labels, "open", @active, @terminal) == "In Progress"
    end

    test "no symphony label -> first terminal state" do
      labels = ["bug", "p1"]
      assert StateMapping.state_from_labels(labels, "open", @active, @terminal) == "Done"
    end

    test "open vs closed does not matter when no symphony label" do
      labels = []
      assert StateMapping.state_from_labels(labels, "closed", @active, @terminal) == "Done"
    end

    test "deterministic when multiple symphony labels present (sorted)" do
      labels = ["symphony:todo", "symphony:in-progress"]
      assert StateMapping.state_from_labels(labels, "open", @active, @terminal) == "In Progress"
    end

    test "unknown symphony label falls back to first terminal" do
      labels = ["symphony:weirdo"]
      assert StateMapping.state_from_labels(labels, "open", @active, @terminal) == "Done"
    end
  end

  describe "label_ops_for_state/2" do
    test "from no labels: only adds target" do
      ops = StateMapping.label_ops_for_state("In Progress", [])
      assert ops == [{:add, "symphony:in-progress"}]
    end

    test "removes other symphony labels and adds target" do
      ops = StateMapping.label_ops_for_state("Done", ["symphony:in-progress", "bug"])
      assert {:remove, "symphony:in-progress"} in ops
      assert {:add, "symphony:done"} in ops
      refute Enum.any?(ops, &match?({:remove, "bug"}, &1))
    end

    test "no-op when target label already present and no other symphony labels" do
      ops = StateMapping.label_ops_for_state("In Progress", ["symphony:in-progress", "bug"])
      assert ops == []
    end
  end

  describe "symphony_label?/1" do
    test "matches prefix" do
      assert StateMapping.symphony_label?("symphony:todo")
      refute StateMapping.symphony_label?("bug")
      refute StateMapping.symphony_label?("symphonyplus")
    end
  end
end
