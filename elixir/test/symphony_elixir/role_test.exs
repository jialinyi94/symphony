defmodule SymphonyElixir.RoleTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.Role

  describe "from_config/2" do
    test "nil raw config yields just the id" do
      assert %Role{id: "reviewer", agent_kind: "claude_code", command: nil, github_token_env: nil} =
               Role.from_config("reviewer", nil)
    end

    test "string-keyed map (YAML decoded)" do
      raw = %{
        "agent_kind" => "codex",
        "command" => "codex exec --skill gh-review-bot",
        "github_token_env" => "REVIEWER_BOT_TOKEN"
      }

      assert %Role{
               id: "reviewer",
               agent_kind: "codex",
               command: "codex exec --skill gh-review-bot",
               github_token_env: "REVIEWER_BOT_TOKEN"
             } = Role.from_config("reviewer", raw)
    end

    test "atom-keyed map (programmatic construction)" do
      raw = %{agent_kind: "codex", github_token_env: "BOT_TOKEN"}

      assert %Role{agent_kind: "codex", github_token_env: "BOT_TOKEN"} =
               Role.from_config("reviewer", raw)
    end
  end

  describe "resolve_token/1" do
    test "returns nil when github_token_env is unset" do
      assert Role.resolve_token(%Role{id: "implementer"}) == nil
    end

    test "returns nil when the named env var is missing" do
      var = "SYMPHONY_TEST_ROLE_TOKEN_MISSING_#{System.unique_integer([:positive])}"
      System.delete_env(var)

      assert Role.resolve_token(%Role{id: "reviewer", github_token_env: var}) == nil
    end

    test "returns nil when the env var is an empty string" do
      var = "SYMPHONY_TEST_ROLE_TOKEN_EMPTY_#{System.unique_integer([:positive])}"
      System.put_env(var, "")
      on_exit(fn -> System.delete_env(var) end)

      assert Role.resolve_token(%Role{id: "reviewer", github_token_env: var}) == nil
    end

    test "returns the env var value when set" do
      var = "SYMPHONY_TEST_ROLE_TOKEN_SET_#{System.unique_integer([:positive])}"
      System.put_env(var, "ghp_reviewer_bot_secret")
      on_exit(fn -> System.delete_env(var) end)

      assert Role.resolve_token(%Role{id: "reviewer", github_token_env: var}) ==
               "ghp_reviewer_bot_secret"
    end
  end

  describe "Config.role/1 — defaults when roles: block absent in WORKFLOW" do
    test "implementer defaults pick up agent.kind from existing config; command stays nil" do
      role = Config.role("implementer")
      assert role.id == "implementer"
      # Test workflow defaults to agent.kind=codex (see TestSupport workflow_content),
      # so the implementer role inherits that.
      assert role.agent_kind in ["claude_code", "codex"]
      assert role.github_token_env == nil

      # Regression guard for the bug surfaced by Codex.AppServer role
      # wiring: previously this populated `claude_code.command`
      # unconditionally, even when `agent.kind: "codex"`, silently
      # asking the codex runner to spawn `"claude"`. The fix is to
      # leave `command: nil` — both runners fall back to their own
      # `settings.<runner>.command` when role.command is unset.
      assert role.command == nil
    end

    test "reviewer defaults to codex agent kind with no token override" do
      role = Config.role("reviewer")
      assert role.id == "reviewer"
      assert role.agent_kind == "codex"
      assert role.github_token_env == nil
    end

    test "unknown role id yields a generic claude_code default" do
      role = Config.role("ghost")
      assert role.id == "ghost"
      assert role.agent_kind == "claude_code"
    end

    test "atom role id is accepted (normalized to string)" do
      assert Config.role(:reviewer).id == "reviewer"
    end
  end

  describe "Config.role/1 — explicit roles: block in WORKFLOW" do
    test "configured reviewer is returned over defaults" do
      yaml_roles = ~s({reviewer: {agent_kind: "codex", command: "codex exec --skill gh-review-bot", github_token_env: "REVIEWER_BOT_TOKEN"}})
      override_workflow_with_roles(yaml_roles)

      role = Config.role("reviewer")
      assert role.agent_kind == "codex"
      assert role.command == "codex exec --skill gh-review-bot"
      assert role.github_token_env == "REVIEWER_BOT_TOKEN"
    end
  end

  defp override_workflow_with_roles(yaml_roles_value) do
    path = Workflow.workflow_file_path()

    content = """
    ---
    tracker:
      kind: memory
    roles: #{yaml_roles_value}
    ---
    body
    """

    File.write!(path, content)

    if Process.whereis(Workflow.WorkflowStore) ||
         Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    :ok
  end
end
