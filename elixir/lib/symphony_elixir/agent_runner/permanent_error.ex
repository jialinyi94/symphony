defmodule SymphonyElixir.AgentRunner.PermanentError do
  @moduledoc """
  Raised by `SymphonyElixir.AgentRunner` when an agent task hits an
  error that retrying cannot fix — typically an agent binary missing
  from the daemon's PATH (`{:port_exit, 127}` or a pre-spawn
  `ArgumentError` from `Agent.BinaryResolver`).

  The orchestrator pattern-matches this exception type in its
  `{:DOWN, ...}` handler and routes the issue to
  `symphony:human-review` instead of looping through `schedule_issue_retry`.
  Without this signal a config error (e.g. systemd-user PATH lacking
  `~/.local/bin`) causes the issue to backoff-retry indefinitely,
  burning daemon cycles and obscuring the failure.

  `:reason` holds the structured underlying reason (the original
  `:port_exit` tuple or the rescued exception) so the escalation
  comment can report it verbatim instead of relying on string
  scraping of the message.
  """

  defexception [:message, :reason]

  @impl true
  def exception(opts) when is_list(opts) do
    %__MODULE__{
      message: Keyword.fetch!(opts, :message),
      reason: Keyword.get(opts, :reason)
    }
  end

  @doc """
  True when a `:DOWN` exit `reason` came from a Task raising
  `PermanentError`. Task supervisor packages a raised exception as
  `{%PermanentError{}, stacktrace}`, so the orchestrator can call this
  helper from its `handle_info({:DOWN, ...}, _)` callback to decide
  between fast-fail escalation and retry-with-backoff.
  """
  @spec from_exit?(term()) :: boolean()
  def from_exit?({%__MODULE__{}, stacktrace}) when is_list(stacktrace), do: true
  def from_exit?(_), do: false
end
