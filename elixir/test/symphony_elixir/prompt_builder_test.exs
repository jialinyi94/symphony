defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Issue, PromptBuilder, Workflow}

  defp write_workflow!(content) do
    path = Path.join(System.tmp_dir!(), "WORKFLOW-#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    Workflow.set_workflow_file_path(path)
    on_exit(fn ->
      _ = File.rm(path)
      Workflow.clear_workflow_file_path()
    end)
    path
  end

  defp issue, do: %Issue{id: "1", identifier: "1", title: "T", description: "D", labels: [], url: "u"}

  test "default variant renders the body prompt" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    Issue: {{ issue.identifier }}.
    """)

    assert PromptBuilder.build_prompt(issue()) =~ "Issue: 1."
  end

  test "epic_planner variant renders the named prompt and exposes :epic context" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    prompts:
      epic_planner: |
        Plan epic {{ issue.identifier }} with sub-issues: {{ epic.sub_issue_numbers | join: ', ' }}.
    ---
    default body
    """)

    out = PromptBuilder.build_prompt(issue(), variant: :epic_planner, epic: %{sub_issue_numbers: [134, 135]})
    assert out =~ "Plan epic 1 with sub-issues: 134, 135."
  end

  test "epic_planner variant raises a clear error when prompt is missing" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    default body only
    """)

    assert_raise RuntimeError, ~r/missing.*epic_planner/, fn ->
      PromptBuilder.build_prompt(issue(), variant: :epic_planner)
    end
  end

  test "AgentRunner-style call with variant and epic forwards correctly" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    prompts:
      epic_planner: |
        P {{ issue.identifier }} {{ epic.sub_issue_numbers | size }}.
    ---
    default
    """)

    assert "P 1 2." <> _ = PromptBuilder.build_prompt(issue(), variant: :epic_planner, epic: %{sub_issue_numbers: [1, 2]}, attempt: 1)
  end
end
