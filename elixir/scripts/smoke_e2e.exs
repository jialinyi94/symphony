# End-to-end smoke test for the agent-agnostic fork:
# Memory tracker -> AgentRunner -> Agent dispatcher -> ClaudeCode.Runner -> real claude binary.
#
# Run from elixir/ dir:
#   mise exec -- mix run scripts/smoke_e2e.exs

alias SymphonyElixir.{AgentRunner, Issue, WorkflowStore}

workflow_root = Path.join(System.tmp_dir!(), "symphony-smoke-#{System.unique_integer([:positive])}")
workspace_root = Path.join(workflow_root, "workspaces")
File.mkdir_p!(workspace_root)

workflow_path = Path.join(workflow_root, "WORKFLOW.md")

File.write!(workflow_path, """
---
tracker:
  kind: memory
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done"]
polling:
  interval_ms: 60000
workspace:
  root: #{workspace_root}
worker:
  ssh_hosts: []
agent:
  kind: claude_code
  max_concurrent_agents: 1
  max_turns: 1
claude_code:
  command: claude
hooks:
  after_create: |
    echo 'hello world' > NOTE.md
  before_run: |
    true
  after_run: |
    true
  before_remove: |
    true
observability:
  dashboard_enabled: false
server: {}
---

You are working on issue {{ issue.identifier }}.

Title: {{ issue.title }}

Reply with the single word DONE and nothing else. Do not edit any files.
""")

Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)
SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

issue = %Issue{
  id: "smoke-1",
  identifier: "smoke-1",
  title: "Smoke test",
  description: "End-to-end smoke",
  state: "Todo",
  labels: [],
  url: "https://example.invalid/smoke-1"
}

Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

IO.puts("=== Smoke e2e starting ===")
IO.puts("workflow=#{workflow_path}")
IO.puts("workspace_root=#{workspace_root}")

result =
  try do
    AgentRunner.run(issue, self(),
      issue_state_fetcher: fn _ids ->
        # Pretend the issue moved to terminal so AgentRunner stops after 1 turn.
        {:ok, [%{issue | state: "Done"}]}
      end
    )
  catch
    kind, reason ->
      {:caught, kind, reason}
  end

IO.puts("=== Smoke e2e result ===")
IO.inspect(result, label: "result")

# Drain any agent update messages we accumulated.
events =
  Stream.repeatedly(fn ->
    receive do
      msg -> msg
    after
      0 -> :no_more
    end
  end)
  |> Enum.take_while(&(&1 != :no_more))

IO.puts("Captured #{length(events)} runner messages")
Enum.each(events, fn msg -> IO.inspect(msg, label: "msg", limit: 5) end)

# Cleanup: delete the workspace dir we created
File.rm_rf!(workflow_root)
IO.puts("=== Smoke e2e done ===")
