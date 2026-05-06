# End-to-end test against real GitHub:
#   GitHub.Adapter -> Tracker -> AgentRunner -> ClaudeCode.Runner -> real claude.
#
# Requires:
#   - GITHUB_TOKEN env var
#   - REPO env var (format owner/name)
#
# Run from elixir/ dir:
#   GITHUB_TOKEN=$(gh auth token) REPO=owner/repo mise exec -- mix run scripts/smoke_e2e_github.exs

repo = System.get_env("REPO") || raise "REPO env var required"
unless System.get_env("GITHUB_TOKEN"), do: raise("GITHUB_TOKEN env var required")

alias SymphonyElixir.{AgentRunner, Tracker, Workflow, WorkflowStore}

workflow_root = Path.join(System.tmp_dir!(), "symphony-e2e-gh-#{System.unique_integer([:positive])}")
workspace_root = Path.join(workflow_root, "workspaces")
File.mkdir_p!(workspace_root)
workflow_path = Path.join(workflow_root, "WORKFLOW.md")

clone_url = "https://github.com/#{repo}.git"

File.write!(workflow_path, """
---
tracker:
  kind: github
  repo: #{repo}
  api_key: "${GITHUB_TOKEN}"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
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
    git clone --depth 1 #{clone_url} .
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

You are working on GitHub issue \#{{ issue.identifier }} in #{repo}.

Title: {{ issue.title }}

Description:
{{ issue.description }}

Do exactly what the issue asks. One file change is enough. Do NOT push, do NOT commit,
do NOT touch GitHub. Stop after the file change.
""")

Application.put_env(:symphony_elixir, :workflow_file_path, workflow_path)
Workflow.set_workflow_file_path(workflow_path)
if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

IO.puts("=== Step 1: GitHub adapter fetch ===")
{:ok, issues} = Tracker.fetch_candidate_issues()
IO.puts("Fetched #{length(issues)} candidate issue(s):")
Enum.each(issues, fn i ->
  IO.puts("  ##{i.identifier}  state=#{i.state}  labels=#{inspect(i.labels)}  title=#{i.title}")
end)

case issues do
  [] ->
    IO.puts("FAIL: no candidate issues. Did you label one with symphony:todo?")
    System.halt(1)

  [issue | _] ->
    IO.puts("\n=== Step 2: AgentRunner dispatching to Claude Code ===")

    result =
      try do
        AgentRunner.run(issue, self(),
          issue_state_fetcher: fn _ids ->
            {:ok, [%{issue | state: "Done"}]}
          end
        )
      catch
        kind, reason -> {:caught, kind, reason}
      end

    IO.inspect(result, label: "runner_result")

    workspace = Path.join(workspace_root, issue.identifier)
    IO.puts("\n=== Step 3: Workspace inspection (#{workspace}) ===")

    if File.dir?(workspace) do
      workspace
      |> File.ls!()
      |> Enum.sort()
      |> Enum.each(&IO.puts("  #{&1}"))
    else
      IO.puts("workspace dir does not exist (it should — workspace before_remove ran cleanup)")
    end
end

IO.puts("\n=== Done ===")
