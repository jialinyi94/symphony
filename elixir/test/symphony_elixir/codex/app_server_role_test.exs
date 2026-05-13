defmodule SymphonyElixir.Codex.AppServerRoleTest do
  @moduledoc """
  Coverage for `Codex.AppServer`'s `Role` integration.

  Asserts that a `%Role{}` threaded through `start_session/2` actually
  reshapes the spawn args and env. Tests the pure helpers
  (`local_port_opts/2`, `remote_launch_command/2`) so we don't need to
  spawn a real codex process.

  Companion to `role_test.exs` (which covers `Role` itself) and the
  end-to-end `app_server_test.exs` (which covers the protocol layer).
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Role

  @reviewer_token_env "SYMP_TEST_REVIEWER_TOKEN"
  @reviewer_token_value "tkn-reviewer-fixture"

  setup do
    previous = System.get_env(@reviewer_token_env)
    on_exit(fn -> restore_env(@reviewer_token_env, previous) end)
    :ok
  end

  describe "local_port_opts/2" do
    test "without a role: uses configured codex.command, no :env injection" do
      opts = AppServer.local_port_opts("/some/workspace", nil)

      assert opts_args(opts) == [~c"-lc", ~c"codex app-server"]
      refute Keyword.has_key?(opts, :env)
    end

    test "role with :command: overrides codex.command in args" do
      role = %Role{id: "reviewer", agent_kind: "codex", command: "codex exec --skill gh-review-bot"}

      opts = AppServer.local_port_opts("/some/workspace", role)

      assert opts_args(opts) == [~c"-lc", ~c"codex exec --skill gh-review-bot"]
    end

    test "role with :github_token_env set + parent env populated: injects GITHUB_TOKEN" do
      System.put_env(@reviewer_token_env, @reviewer_token_value)
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      opts = AppServer.local_port_opts("/some/workspace", role)

      assert Keyword.get(opts, :env) == [{~c"GITHUB_TOKEN", to_charlist(@reviewer_token_value)}]
    end

    test "role with :github_token_env set but parent env unset: no injection (BC-safe)" do
      System.delete_env(@reviewer_token_env)
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      opts = AppServer.local_port_opts("/some/workspace", role)

      refute Keyword.has_key?(opts, :env)
    end

    test "role with :github_token_env set but parent env empty string: no injection" do
      System.put_env(@reviewer_token_env, "")
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      opts = AppServer.local_port_opts("/some/workspace", role)

      refute Keyword.has_key?(opts, :env)
    end

    test "role with both :command and :github_token_env: both apply" do
      System.put_env(@reviewer_token_env, @reviewer_token_value)

      role = %Role{
        id: "reviewer",
        agent_kind: "codex",
        command: "codex exec --skill gh-review-bot",
        github_token_env: @reviewer_token_env
      }

      opts = AppServer.local_port_opts("/some/workspace", role)

      assert opts_args(opts) == [~c"-lc", ~c"codex exec --skill gh-review-bot"]
      assert Keyword.get(opts, :env) == [{~c"GITHUB_TOKEN", to_charlist(@reviewer_token_value)}]
    end
  end

  describe "remote_launch_command/2" do
    test "without a role: emits cd + exec only" do
      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", nil)

      assert command == "cd '/remote/workspaces/MT-1' && exec codex app-server"
      refute command =~ "export GITHUB_TOKEN"
    end

    test "role.command: substituted in exec clause" do
      role = %Role{id: "reviewer", agent_kind: "codex", command: "codex exec --skill gh-review-bot"}

      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", role)

      assert command =~ "exec codex exec --skill gh-review-bot"
      refute command =~ "exec codex app-server"
    end

    test "role + token in env: prepends export GITHUB_TOKEN with shell-escaped value" do
      System.put_env(@reviewer_token_env, @reviewer_token_value)
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", role)

      assert String.starts_with?(command, "export GITHUB_TOKEN='#{@reviewer_token_value}' && cd ")
    end

    test "role with token containing a single quote: shell-escaped safely" do
      tricky = "tkn'with-quote"
      System.put_env(@reviewer_token_env, tricky)
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", role)

      assert command =~ ~s|export GITHUB_TOKEN='tkn'"'"'with-quote'|
    end

    test "role with token env unset: no export prepended (BC-safe)" do
      System.delete_env(@reviewer_token_env)
      role = %Role{id: "reviewer", agent_kind: "codex", github_token_env: @reviewer_token_env}

      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", role)

      refute command =~ "export GITHUB_TOKEN"
      assert command == "cd '/remote/workspaces/MT-1' && exec codex app-server"
    end
  end

  defp opts_args(opts) do
    Keyword.fetch!(opts, :args)
  end
end
