defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.

  State is encoded as `symphony:*` labels per `SymphonyElixir.GitHub.StateMapping`.
  Terminal states additionally close the issue on GitHub; non-terminal active
  states reopen if needed.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.Client, GitHub.EpicPlan, GitHub.StateMapping, Issue, PullRequest, WorkItem}

  @impl true
  def kind, do: "github"

  @impl true
  def secret_env_var, do: "GITHUB_TOKEN"

  @impl true
  def validate_config(tracker) do
    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_github_token}
      not is_binary(tracker.repo) or tracker.repo == "" -> {:error, :missing_github_repo}
      true -> :ok
    end
  end

  @impl true
  def fetch_sub_issues(issue_id) when is_binary(issue_id) do
    client_module().fetch_sub_issues(issue_id)
  end

  @impl true
  def fetch_plan(epic_id) when is_binary(epic_id) do
    with {:ok, comments} <- client_module().fetch_issue_comments(epic_id) do
      case EpicPlan.extract(comments) do
        {:ok, plan} ->
          validate_plan_against_actual_sub_issues(plan, epic_id)

        {:error, :no_plan} ->
          {:ok, nil}

        {:error, _reason} = err ->
          err
      end
    end
  end

  # Note: this calls `fetch_sub_issues` once per epic per polling tick on top of
  # the candidate-list fetch and the orchestrator's epic_classification lookup.
  # At single-digit-epics-per-repo scale this is fine; if it ever becomes a
  # bottleneck, cache `fetch_sub_issues` results in the process dictionary for
  # the duration of a single polling tick.
  defp validate_plan_against_actual_sub_issues(plan, epic_id) do
    case client_module().fetch_sub_issues(epic_id) do
      {:ok, sub_numbers} ->
        case EpicPlan.validate_against_sub_issues(plan, sub_numbers) do
          :ok -> {:ok, plan}
          {:error, _} = err -> err
        end

      {:error, _reason} = err ->
        # If we can't fetch sub_issues to validate, propagate that error
        # rather than silently accepting an unvalidated plan.
        err
    end
  end

  @impl true
  def fetch_candidate_issues do
    with {:ok, raw_issues} <- client_module().fetch_candidate_issues() do
      {:ok, populate_blocked_by_from_plans(raw_issues)}
    end
  end

  @doc """
  Build the work-item stream: each candidate issue is paired with its
  open PR (if any) and the PR's review + CI signals are preloaded.

  Best-effort:

    * If `fetch_open_pull_requests` fails, fall back to issue-only
      WorkItems and log the error so the orchestrator can still make
      progress on the issue side.
    * If per-PR review/CI fetch fails, attach the PR with empty review
      map / `:unknown` CI status — stage predicates degrade gracefully.

  Pre-populates `metadata.has_sub_issues` so the epic-plan stage
  predicate can fire without further IO during stage resolution.
  """
  @impl true
  def fetch_work_items do
    with {:ok, issues} <- fetch_candidate_issues() do
      prs = fetch_open_prs_or_warn()
      pr_by_issue_id = associate_prs_to_issues(prs, issues)

      work_items =
        Enum.map(issues, fn issue ->
          attached_pr =
            case Map.get(pr_by_issue_id, issue.id) do
              %PullRequest{} = pr -> preload_pr_signals(pr)
              _ -> nil
            end

          metadata = build_work_item_metadata(issue)

          WorkItem.from_issue(issue,
            tracker_kind: :github,
            metadata: metadata,
            attached_pr: attached_pr
          )
        end)

      {:ok, work_items}
    end
  end

  defp fetch_open_prs_or_warn do
    case client_module().fetch_open_pull_requests() do
      {:ok, prs} ->
        prs

      {:error, reason} ->
        require Logger
        Logger.warning("GitHub: fetch_open_pull_requests failed (#{inspect(reason)}); continuing with issue-only work items")
        []
    end
  end

  # Associate PRs to issues using two heuristics, in priority order:
  #   1. `linked_issue_number` from PR body (Closes #N / Fixes #N)
  #   2. branch-name pattern `symphony/issue-<N>` matches issue.identifier
  defp associate_prs_to_issues(prs, issues) when is_list(prs) and is_list(issues) do
    issue_ids_set = MapSet.new(issues, & &1.id)

    Enum.reduce(prs, %{}, fn pr, acc ->
      case associate_pr_to_issue_id(pr, issue_ids_set) do
        nil -> acc
        issue_id -> Map.put_new(acc, issue_id, pr)
      end
    end)
  end

  defp associate_pr_to_issue_id(%PullRequest{linked_issue_number: n}, issue_ids_set)
       when is_integer(n) do
    candidate = Integer.to_string(n)
    if MapSet.member?(issue_ids_set, candidate), do: candidate, else: nil
  end

  defp associate_pr_to_issue_id(%PullRequest{head_ref: ref}, issue_ids_set) when is_binary(ref) do
    case Regex.run(~r{^symphony/issue-(\d+)$}, ref) do
      [_, num_str] ->
        if MapSet.member?(issue_ids_set, num_str), do: num_str, else: nil

      _ ->
        nil
    end
  end

  defp associate_pr_to_issue_id(_pr, _set), do: nil

  defp preload_pr_signals(%PullRequest{number: number, head_sha: head_sha} = pr) do
    reviews = fetch_reviews_or_empty(number)
    latest_by_author = latest_reviews_by_author(reviews)
    ci_status = fetch_ci_status_or_unknown(head_sha)

    %{pr | reviews: reviews, latest_reviews_by_author: latest_by_author, ci_status: ci_status}
  end

  defp fetch_reviews_or_empty(nil), do: []

  defp fetch_reviews_or_empty(number) do
    case client_module().fetch_pull_request_reviews(number) do
      {:ok, reviews} ->
        reviews

      {:error, reason} ->
        require Logger
        Logger.warning("GitHub: fetch_pull_request_reviews(#{number}) failed (#{inspect(reason)})")
        []
    end
  end

  defp fetch_ci_status_or_unknown(nil), do: :unknown

  defp fetch_ci_status_or_unknown(sha) do
    case client_module().fetch_ci_status(sha) do
      {:ok, status} ->
        status

      {:error, reason} ->
        require Logger
        Logger.warning("GitHub: fetch_ci_status(#{sha}) failed (#{inspect(reason)})")
        :unknown
    end
  end

  defp latest_reviews_by_author(reviews) when is_list(reviews) do
    reviews
    |> Enum.reduce(%{}, fn
      %PullRequest.Review{author_login: nil}, acc ->
        acc

      %PullRequest.Review{author_login: login} = r, acc ->
        Map.update(acc, login, r, fn prev -> if newer_review?(r, prev), do: r, else: prev end)
    end)
  end

  defp newer_review?(%PullRequest.Review{submitted_at: a}, %PullRequest.Review{submitted_at: b})
       when not is_nil(a) and not is_nil(b),
       do: DateTime.compare(a, b) == :gt

  defp newer_review?(%PullRequest.Review{submitted_at: a}, %PullRequest.Review{submitted_at: nil})
       when not is_nil(a),
       do: true

  defp newer_review?(_, _), do: false

  defp build_work_item_metadata(%Issue{id: id} = _issue) when is_binary(id) do
    case client_module().fetch_sub_issues(id) do
      {:ok, numbers} when is_list(numbers) ->
        %{has_sub_issues: numbers != [], sub_issue_numbers: numbers}

      _ ->
        %{has_sub_issues: false, sub_issue_numbers: []}
    end
  end

  defp build_work_item_metadata(_issue), do: %{has_sub_issues: false, sub_issue_numbers: []}

  @impl true
  def fetch_issues_by_states(states) do
    with {:ok, raw_issues} <- client_module().fetch_issues_by_states(states) do
      {:ok, populate_blocked_by_from_plans(raw_issues)}
    end
  end

  defp populate_blocked_by_from_plans(issues) do
    state_by_number = build_state_by_number(issues)
    epics = Enum.filter(issues, &(&1.state == "Epic Tracking"))

    # Cache the plan once per epic so we don't double-fetch (once for blocker
    # discovery, once for blocker computation).
    plans_by_epic = Enum.into(epics, %{}, fn epic -> {epic.id, fetch_plan_safe(epic.id)} end)

    # Augment state_by_number with any plan-referenced ids that are not in
    # `issues` (e.g., Done children that have been closed and dropped from
    # the open candidate list returned by GitHub's `state: "open"` filter).
    augmented_state_by_number =
      augment_with_terminal_states(plans_by_epic, state_by_number)

    blockers_by_child =
      epics
      |> Enum.flat_map(fn epic ->
        blockers_for_epic(plans_by_epic[epic.id], augmented_state_by_number)
      end)
      |> Enum.into(%{})

    Enum.map(issues, fn issue ->
      case Map.get(blockers_by_child, issue.id) do
        nil -> issue
        blockers -> %{issue | blocked_by: blockers}
      end
    end)
  end

  defp build_state_by_number(issues) do
    issues
    |> Enum.into(%{}, fn issue ->
      case Integer.parse(issue.id || "") do
        {n, _} -> {n, issue.state}
        :error -> {nil, issue.state}
      end
    end)
    |> Map.delete(nil)
  end

  defp fetch_plan_safe(epic_id) do
    case fetch_plan(epic_id) do
      {:ok, %{sub_issues: _} = plan} -> plan
      _ -> nil
    end
  end

  defp augment_with_terminal_states(plans_by_epic, state_by_number) do
    referenced_ids =
      plans_by_epic
      |> Map.values()
      |> Enum.flat_map(&plan_referenced_ids/1)
      |> Enum.uniq()

    missing_ids = Enum.reject(referenced_ids, &Map.has_key?(state_by_number, &1))

    if missing_ids == [] do
      state_by_number
    else
      merge_fetched_states(state_by_number, missing_ids)
    end
  end

  defp merge_fetched_states(state_by_number, missing_ids) do
    case client_module().fetch_issue_states_by_ids(Enum.map(missing_ids, &Integer.to_string/1)) do
      {:ok, fetched} -> Enum.reduce(fetched, state_by_number, &put_state_by_number/2)
      _ -> state_by_number
    end
  end

  defp put_state_by_number(issue, acc) do
    case Integer.parse(issue.id || "") do
      {n, _} -> Map.put(acc, n, issue.state)
      :error -> acc
    end
  end

  defp plan_referenced_ids(nil), do: []

  defp plan_referenced_ids(%{sub_issues: subs}) do
    Enum.flat_map(subs, fn sub -> [sub.id | sub.blocked_by] end)
  end

  defp blockers_for_epic(nil, _state_by_number), do: []

  defp blockers_for_epic(%{sub_issues: subs}, state_by_number) do
    Enum.map(subs, &sub_to_blocker_entry(&1, state_by_number))
  end

  defp sub_to_blocker_entry(sub, state_by_number) do
    blockers = Enum.map(sub.blocked_by, &%{state: Map.get(state_by_number, &1, "Todo")})
    {Integer.to_string(sub.id), blockers}
  end

  @impl true
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @impl true
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @impl true
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    settings = Config.settings!().tracker

    with {:ok, [issue]} <- client_module().fetch_issue_states_by_ids([issue_id]) do
      target_label = StateMapping.state_to_label(state_name)
      ops = StateMapping.label_ops_for_state(state_name, issue.labels)
      next_labels = apply_label_ops(issue.labels, ops, target_label)
      next_state = github_state_for(state_name, settings.terminal_states)

      client_module().set_labels_and_state(issue_id, next_labels, next_state)
    else
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_label_ops(current, ops, target_label) do
    after_removes =
      Enum.reduce(ops, current, fn
        {:remove, label}, acc -> List.delete(acc, label)
        _, acc -> acc
      end)

    if target_label in after_removes, do: after_removes, else: [target_label | after_removes]
  end

  defp github_state_for(state_name, terminal_states) do
    if state_name in terminal_states, do: :closed, else: :open
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
