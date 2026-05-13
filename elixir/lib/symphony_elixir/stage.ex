defmodule SymphonyElixir.Stage do
  @moduledoc """
  A stage in a `WorkItem`'s lifecycle.

  A stage bundles four pieces of dispatch context:

    * `:role` — which agent identity should run (`:implementer`,
      `:reviewer`, or `nil` for terminal stages awaiting human action).
    * `:prompt_variant` — variant key into `Workflow.current().prompts`
      (`:default` falls back to the default body).
    * `:max_turns` — optional override of the per-stage turn budget.
    * `:when_fun` — arity-1 predicate `(WorkItem.t() -> boolean())` that
      decides whether this stage applies to a given WorkItem. `nil`
      counts as "always applies" (useful as a catch-all final stage).

  Stages are pure data. `StageResolver.resolve/2` picks the first
  applicable stage from an ordered list. The orchestrator uses the
  resolved stage to drive role-aware dispatch.

  ## Built-in defaults

  `defaults/0` ships a canonical 8-stage list covering the full
  issue-then-PR lifecycle. The PR stages (`:pr_first_review` →
  `:pr_changes_requested` / `:pr_ci_failed` → `:pr_revalidate` →
  `:pr_record_proof` → `:pr_awaiting_merge`) make Symphony's
  review-loop autonomy explicit. Issue stages (`:issue_epic_plan`,
  `:issue_implement`) preserve the pre-existing
  `Orchestrator.build_run_opts/2` behavior — that parity is enforced
  by `StageResolverTest`.
  """

  alias SymphonyElixir.{PullRequest, WorkItem}

  # Mirrors `SymphonyElixir.Orchestrator.@epic_planner_max_turns`. PR2 will
  # consolidate this into a single source.
  @default_epic_planner_max_turns 4
  @default_reviewer_max_turns 2
  @default_proof_recorder_max_turns 3

  @doc """
  Configured login of the reviewer bot identity. The PR-stage predicates
  use this to detect when the reviewer has spoken (approved /
  requested changes / pushed comments).

  Override via application env (`:symphony_elixir, :reviewer_login`) or
  fall back to the WORKFLOW-typical default.
  """
  @spec reviewer_login() :: String.t()
  def reviewer_login do
    Application.get_env(:symphony_elixir, :reviewer_login, "reviewer-is-all-u-need")
  end

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
  first match. PR stages precede issue stages because a WorkItem with
  an attached PR has already left the implementation phase. The
  catch-all `:issue_implement` stage must remain last.

  Stage order (top wins):

    1. `:pr_awaiting_merge`     — proof artifact posted, waiting human merge (terminal, role=nil)
    2. `:pr_record_proof`       — review converged → record demo + tests
    3. `:pr_revalidate`         — author pushed since last reviewer review
    4. `:pr_ci_failed`          — CI failed on current head, no author push since
    5. `:pr_changes_requested`  — reviewer requested changes on current head
    6. `:pr_first_review`       — open PR with no reviewer review yet
    7. `:issue_epic_plan`       — issue has sub-issues, planner needed
    8. `:issue_implement`       — catch-all
  """
  @spec defaults() :: [t()]
  def defaults do
    [
      pr_awaiting_merge_stage(),
      pr_record_proof_stage(),
      pr_revalidate_stage(),
      pr_ci_failed_stage(),
      pr_changes_requested_stage(),
      pr_first_review_stage(),
      epic_plan_stage(),
      implement_stage()
    ]
  end

  @doc """
  True when this stage represents a no-dispatch terminal state (the
  orchestrator should observe it but not spawn any agent — typically
  awaiting human action). Identified by `role: nil`.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{role: nil}), do: true
  def terminal?(_), do: false

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

  # ---------------------------------------------------------------------------
  # PR stages
  # ---------------------------------------------------------------------------

  defp pr_first_review_stage do
    %__MODULE__{
      id: :pr_first_review,
      role: :reviewer,
      prompt_variant: :pr_first_review,
      max_turns: @default_reviewer_max_turns,
      when_fun: &pr_first_review_applies?/1,
      description: "PR is open and has no review yet from the configured reviewer identity. Spawn the reviewer to do the first pass."
    }
  end

  defp pr_changes_requested_stage do
    %__MODULE__{
      id: :pr_changes_requested,
      role: :implementer,
      prompt_variant: :pr_author_followup,
      max_turns: nil,
      when_fun: &pr_changes_requested_applies?/1,
      description: "Reviewer has CHANGES_REQUESTED on the current head and the author has not pushed since. Author follows up."
    }
  end

  defp pr_ci_failed_stage do
    %__MODULE__{
      id: :pr_ci_failed,
      role: :implementer,
      prompt_variant: :pr_author_followup,
      max_turns: nil,
      when_fun: &pr_ci_failed_applies?/1,
      description: "CI failed on the current head and the author has not pushed since. Author investigates and pushes a fix."
    }
  end

  defp pr_revalidate_stage do
    %__MODULE__{
      id: :pr_revalidate,
      role: :reviewer,
      prompt_variant: :pr_revalidate,
      max_turns: @default_reviewer_max_turns,
      when_fun: &pr_revalidate_applies?/1,
      description: "Author has pushed new commits since the last reviewer review. Reviewer revalidates the new head."
    }
  end

  defp pr_record_proof_stage do
    %__MODULE__{
      id: :pr_record_proof,
      role: :implementer,
      prompt_variant: :pr_record_proof,
      max_turns: @default_proof_recorder_max_turns,
      when_fun: &pr_record_proof_applies?/1,
      description: "Review converged (reviewer APPROVED current head, CI green). Implementer records demo + test summary on PR before human-merge handoff."
    }
  end

  defp pr_awaiting_merge_stage do
    %__MODULE__{
      id: :pr_awaiting_merge,
      role: nil,
      prompt_variant: :default,
      max_turns: nil,
      when_fun: &pr_awaiting_merge_applies?/1,
      description: "Review converged, proof artifact posted. Awaiting human merge — orchestrator should not dispatch."
    }
  end

  # Predicates. All are pure functions over WorkItem; IO must be done
  # upstream by the orchestrator (preloading the PullRequest struct + ci_status).

  defp pr_first_review_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{} = pr ->
        WorkItem.pr_open_for_review?(wi) and is_nil(PullRequest.latest_review_from(pr, reviewer_login())) and
          not proof_already_recorded?(wi)

      _ ->
        false
    end
  end

  defp pr_changes_requested_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{} = pr ->
        WorkItem.pr_open_for_review?(wi) and PullRequest.changes_requested_by?(pr, reviewer_login())

      _ ->
        false
    end
  end

  defp pr_ci_failed_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{ci_status: :failure} = pr ->
        # Author must not have already pushed a fix since the failure; we
        # approximate by checking the head hasn't changed since the latest
        # reviewer touch. If no reviewer has spoken yet, treat CI failure
        # as actionable for the author.
        case PullRequest.latest_review_from(pr, reviewer_login()) do
          nil -> WorkItem.pr_open_for_review?(wi)
          %PullRequest.Review{commit_id: sha} -> sha == pr.head_sha and WorkItem.pr_open_for_review?(wi)
        end

      _ ->
        false
    end
  end

  defp pr_revalidate_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{} = pr ->
        WorkItem.pr_open_for_review?(wi) and PullRequest.author_pushed_since?(pr, reviewer_login())

      _ ->
        false
    end
  end

  defp pr_record_proof_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{} = pr ->
        WorkItem.pr_open_for_review?(wi) and PullRequest.approved_by?(pr, reviewer_login()) and
          pr.ci_status in [:success, :neutral] and not proof_already_recorded?(wi)

      _ ->
        false
    end
  end

  defp pr_awaiting_merge_applies?(%WorkItem{} = wi) do
    case WorkItem.pull_request(wi) do
      %PullRequest{} = pr ->
        WorkItem.pr_open_for_review?(wi) and PullRequest.approved_by?(pr, reviewer_login()) and
          pr.ci_status in [:success, :neutral] and proof_already_recorded?(wi)

      _ ->
        false
    end
  end

  # PR4 uses a metadata flag `:proof_recorded` to short-circuit the proof
  # stage once the orchestrator has confirmed the proof comment is posted.
  defp proof_already_recorded?(%WorkItem{} = wi) do
    WorkItem.metadata(wi, :proof_recorded, false) == true
  end
end
