defmodule SymphonyElixir.StageResolver do
  @moduledoc """
  Pure stage-selection function over a WorkItem and an ordered list of
  Stages.

  Resolution rules:

    * Stages are evaluated in list order. The first stage whose
      predicate returns `true` wins (or whose `:when_fun` is `nil` —
      treated as an unconditional catch-all).
    * If no stage matches, returns `{:error, :no_matching_stage}`.
      Callers should typically include a final catch-all stage to
      avoid this branch in production.

  Resolution is intentionally IO-free: every predicate input must be
  carried on the `WorkItem` (via `issue`, `attached_pr`, `metadata`).
  This keeps the resolver cheap to call inside dispatch hot paths and
  trivial to unit-test.
  """

  alias SymphonyElixir.{Stage, WorkItem}

  @spec resolve(WorkItem.t(), [Stage.t()]) ::
          {:ok, Stage.t()} | {:error, :no_matching_stage}
  def resolve(%WorkItem{} = wi, stages) when is_list(stages) do
    case Enum.find(stages, &Stage.applies?(&1, wi)) do
      nil -> {:error, :no_matching_stage}
      %Stage{} = stage -> {:ok, stage}
    end
  end
end
