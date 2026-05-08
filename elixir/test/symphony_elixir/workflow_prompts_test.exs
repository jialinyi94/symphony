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
end
