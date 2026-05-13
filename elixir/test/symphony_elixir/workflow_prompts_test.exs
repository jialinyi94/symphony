defmodule SymphonyElixir.WorkflowPromptsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  defp write_workflow!(content) do
    path = Path.join(System.tmp_dir!(), "WORKFLOW-#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    Workflow.set_workflow_file_path(path)
    on_exit_unlink(path)
    path
  end

  defp on_exit_unlink(path) do
    ExUnit.Callbacks.on_exit(fn ->
      _ = File.rm(path)
      Workflow.clear_workflow_file_path()
    end)
  end

  test "loads epic_planner prompt from frontmatter when present" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    prompts:
      epic_planner: |
        Plan the epic.
    ---
    Default prompt body.
    """)

    {:ok, loaded} = Workflow.load()
    assert loaded.prompt_template == "Default prompt body."
    assert loaded.prompts.epic_planner == "Plan the epic.\n"
  end

  test "loaded.prompts is an empty map when frontmatter has no prompts:" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    Default prompt body.
    """)

    {:ok, loaded} = Workflow.load()
    assert loaded.prompts == %{}
  end

  describe "prompt_available?/1" do
    test ":default is always available regardless of WORKFLOW content" do
      write_workflow!("""
      ---
      tracker:
        kind: memory
      ---
      Default prompt body.
      """)

      assert Workflow.prompt_available?(:default) == true
    end

    test "returns true when prompts.<variant> exists in frontmatter" do
      write_workflow!("""
      ---
      tracker:
        kind: memory
      prompts:
        pr_first_review: |
          Review this PR.
      ---
      Default prompt body.
      """)

      assert Workflow.prompt_available?(:pr_first_review) == true
    end

    test "returns false when prompts: block exists but lacks the named variant" do
      write_workflow!("""
      ---
      tracker:
        kind: memory
      prompts:
        epic_planner: |
          Plan the epic.
      ---
      Default prompt body.
      """)

      refute Workflow.prompt_available?(:pr_first_review)
    end

    test "returns false when frontmatter has no prompts: block" do
      write_workflow!("""
      ---
      tracker:
        kind: memory
      ---
      Default prompt body.
      """)

      refute Workflow.prompt_available?(:pr_first_review)
    end

    test "returns false for non-atom variants (guards against caller bugs)" do
      refute Workflow.prompt_available?("pr_first_review")
      refute Workflow.prompt_available?(nil)
    end
  end
end
