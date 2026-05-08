defmodule SymphonyElixir.OrchestratorTestHelper do
  @moduledoc """
  Test-only orchestration helper. Drives synchronous polling ticks and
  installs a fake agent runner that captures invocations and forwards them
  to the test process recorded via `:memory_tracker_recipient`.
  """

  alias SymphonyElixir.Orchestrator

  @doc """
  Runs `fun` with a stubbed agent runner module installed. The stub captures
  invocations and forwards them as `{:agent_run_invoked, issue_id, opts}`
  to whatever process is configured under
  `Application.get_env(:symphony_elixir, :memory_tracker_recipient)`.
  """
  def with_stubbed_agent_runner(fun) when is_function(fun, 0) do
    prev = Application.get_env(:symphony_elixir, :agent_runner_module)
    Application.put_env(:symphony_elixir, :agent_runner_module, __MODULE__.StubAgentRunner)

    try do
      fun.()
    after
      restore_agent_runner_module(prev)
    end
  end

  defp restore_agent_runner_module(nil),
    do: Application.delete_env(:symphony_elixir, :agent_runner_module)

  defp restore_agent_runner_module(module),
    do: Application.put_env(:symphony_elixir, :agent_runner_module, module)

  @doc """
  Drive one polling tick synchronously. Returns `:ok` once the orchestrator
  has finished processing the dispatch loop for this tick.
  """
  def tick do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) -> GenServer.call(pid, :force_tick, 15_000)
      nil -> raise "Orchestrator GenServer is not running"
    end
  end

  @doc """
  Inject a fake entry into the orchestrator's `running` map so tests can
  simulate an in-flight worker for `issue_id`. Uses `:sys.replace_state/2`
  to mutate the live GenServer state synchronously.
  """
  def set_running(issue_id, metadata \\ %{}) when is_binary(issue_id) and is_map(metadata) do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          %{state | running: Map.put(state.running, issue_id, metadata)}
        end)

        :ok

      nil ->
        raise "Orchestrator GenServer is not running"
    end
  end

  defmodule StubAgentRunner do
    @moduledoc false

    # Mirrors `SymphonyElixir.AgentRunner.run/3`:
    #   run(issue, codex_update_recipient \\ nil, opts \\ [])
    def run(issue, codex_update_recipient \\ nil, opts \\ [])

    def run(%{id: issue_id} = _issue, _codex_update_recipient, opts) when is_binary(issue_id) do
      send(test_pid(), {:agent_run_invoked, issue_id, opts})
      :ok
    end

    def run(issue, _codex_update_recipient, opts) do
      send(test_pid(), {:agent_run_invoked, inspect(issue), opts})
      :ok
    end

    defp test_pid do
      case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
        pid when is_pid(pid) ->
          pid

        _ ->
          raise "OrchestratorTestHelper.StubAgentRunner: no test recipient pid configured"
      end
    end
  end
end
