defmodule SymphonyElixir.Stage do
  @moduledoc """
  A stage in a `WorkItem`'s lifecycle.

  A stage bundles four pieces of dispatch context:

    * `:role` — which agent identity should run (e.g. `:implementer`,
      `:reviewer`). PR1 only ships `:implementer`; later PRs add reviewer.
    * `:prompt_variant` — variant key into `Workflow.current().prompts`
      (`:default` falls back to the default body).
    * `:max_turns` — optional override of the per-stage turn budget.
    * `:when_fun` — arity-1 predicate `(WorkItem.t() -> boolean())` that
      decides whether this stage applies to a given WorkItem. `nil`
      counts as "always applies" (useful as a catch-all final stage).

  Stages are pure data. `StageResolver.resolve/2` picks the first
  applicable stage from an ordered list. The orchestrator (PR2) then
  uses the resolved stage to drive role-aware dispatch.

  ## Built-in defaults

  `defaults/0` returns the canonical two-stage list that mirrors the
  current `Orchestrator.build_run_opts/2` behavior exactly:

    1. `:issue_epic_plan` — if WorkItem has sub-issues and is not yet in
       Epic Tracking state → `:epic_planner` variant, 4 turn budget.
    2. `:issue_implement` — catch-all → `:default` variant, no override.

  This list is the source of truth that PR2 will start consuming in
  `Orchestrator`. Until then, both code paths must produce equivalent
  dispatch parameters; the test suite enforces this invariant.
  """

  alias SymphonyElixir.WorkItem

  # Mirrors `SymphonyElixir.Orchestrator.@epic_planner_max_turns`. PR2 will
  # consolidate this into a single source.
  @default_epic_planner_max_turns 4

  defstruct [
    :id,
    :description,
    :when_fun,
    :max_turns,
    role: :implementer,
    prompt_variant: :default
  ]

  @type role :: :implementer | :reviewer | atom()
  @type prompt_variant :: atom()
  @type predicate :: (WorkItem.t() -> boolean())

  @type t :: %__MODULE__{
          id: atom() | nil,
          description: String.t() | nil,
          when_fun: predicate() | nil,
          max_turns: pos_integer() | nil,
          role: role(),
          prompt_variant: prompt_variant()
        }

  @doc """
  Returns `true` when the stage's predicate (or its absence) matches
  the given WorkItem.

  A `:when_fun` of `nil` always matches and is the recommended way to
  terminate a stages list with a catch-all.
  """
  @spec applies?(t(), WorkItem.t()) :: boolean()
  def applies?(%__MODULE__{when_fun: nil}, %WorkItem{}), do: true

  def applies?(%__MODULE__{when_fun: fun}, %WorkItem{} = wi) when is_function(fun, 1) do
    fun.(wi) == true
  end

  def applies?(_stage, _wi), do: false

  @doc """
  Canonical built-in stages list.

  The list is order-sensitive: `StageResolver.resolve/2` returns the
  first match. The catch-all `:issue_implement` stage must remain last.
  """
  @spec defaults() :: [t()]
  def defaults do
    [
      epic_plan_stage(),
      implement_stage()
    ]
  end

  defp epic_plan_stage do
    %__MODULE__{
      id: :issue_epic_plan,
      role: :implementer,
      prompt_variant: :epic_planner,
      max_turns: @default_epic_planner_max_turns,
      when_fun: &epic_plan_applies?/1,
      description: "Plan an epic. Triggered when the WorkItem has open sub-issues and the issue is not yet in Epic Tracking state."
    }
  end

  defp implement_stage do
    %__MODULE__{
      id: :issue_implement,
      role: :implementer,
      prompt_variant: :default,
      max_turns: nil,
      when_fun: nil,
      description: "Default implementation stage. Catch-all for any issue not matched by an earlier stage."
    }
  end

  # Mirrors `Orchestrator.epic_classification/1`:
  #   * state == "Epic Tracking"   → :regular  (planner already ran)
  #   * has sub-issues             → :epic     (run planner)
  #   * else                        → :regular  (run default)
  #
  # The `:has_sub_issues` metadata flag must be pre-populated by the
  # WorkItem builder (PR2 wires this in Orchestrator before resolution).
  defp epic_plan_applies?(%WorkItem{} = wi) do
    state = WorkItem.normalized_issue_state(wi)
    state not in [nil, "epic tracking"] and WorkItem.metadata(wi, :has_sub_issues, false) == true
  end
end
