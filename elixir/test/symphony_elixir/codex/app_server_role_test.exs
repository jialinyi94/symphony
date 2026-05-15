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

  # Codex.AppServer now runs the configured command through
  # `Agent.BinaryResolver.resolve!/2` so the spawned binary path is
  # absolute (decouples agent dispatch from systemd's stripped PATH).
  # Tests must therefore use a binary that is guaranteed to exist on
  # PATH across dev/CI environments — /bin/echo qualifies on Linux
  # and macOS and is the conventional placeholder elsewhere in this
  # repo's test suite.
  @codex_binary "/bin/echo"
  @global_codex_command @codex_binary <> " app-server"
  @role_codex_command @codex_binary <> " exec --skill gh-review-bot"

  setup do
    previous = System.get_env(@reviewer_token_env)
    workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    write_workflow_file!(workflow_path, codex_command: @global_codex_command)
    on_exit(fn -> restore_env(@reviewer_token_env, previous) end)
    :ok
  end

  describe "local_port_opts/2" do
    test "without a role: uses configured codex.command (binary resolved to absolute path), no :env injection" do
      opts = AppServer.local_port_opts("/some/workspace", nil)

      assert opts_args(opts) == [~c"-lc", String.to_charlist(@global_codex_command)]
      refute Keyword.has_key?(opts, :env)
    end

    test "role with :command: overrides codex.command in args (binary resolved)" do
      role = %Role{id: "reviewer", agent_kind: "codex", command: @role_codex_command}

      opts = AppServer.local_port_opts("/some/workspace", role)

      assert opts_args(opts) == [~c"-lc", String.to_charlist(@role_codex_command)]
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
        command: @role_codex_command,
        github_token_env: @reviewer_token_env
      }

      opts = AppServer.local_port_opts("/some/workspace", role)

      assert opts_args(opts) == [~c"-lc", String.to_charlist(@role_codex_command)]
      assert Keyword.get(opts, :env) == [{~c"GITHUB_TOKEN", to_charlist(@reviewer_token_value)}]
    end

    test "missing codex binary in command raises ArgumentError at dispatch time" do
      workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
      write_workflow_file!(workflow_path, codex_command: "definitely-not-a-codex-xyzzy app-server")

      assert_raise ArgumentError, ~r/codex binary .* not found on PATH/, fn ->
        AppServer.local_port_opts("/some/workspace", nil)
      end
    end
  end

  describe "remote_launch_command/2" do
    test "without a role: emits cd + exec only (command shipped verbatim — remote PATH is authoritative)" do
      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", nil)

      assert command == "cd '/remote/workspaces/MT-1' && exec #{@global_codex_command}"
      refute command =~ "export GITHUB_TOKEN"
    end

    test "role.command: substituted in exec clause (command shipped verbatim)" do
      role = %Role{id: "reviewer", agent_kind: "codex", command: @role_codex_command}

      command = AppServer.remote_launch_command("/remote/workspaces/MT-1", role)

      assert command =~ "exec #{@role_codex_command}"
      refute command =~ "exec #{@global_codex_command}"
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
      assert command == "cd '/remote/workspaces/MT-1' && exec #{@global_codex_command}"
    end
  end

  defp opts_args(opts) do
    Keyword.fetch!(opts, :args)
  end
end
