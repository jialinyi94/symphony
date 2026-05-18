defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST API client for issue polling and writes.

  Uses `tracker.repo` (format: "owner/name"), `tracker.endpoint` (defaults to
  https://api.github.com), and `tracker.api_key` (a personal access token or
  fine-grained token with `repo` scope) from the orchestrator config.
  """

  require Logger
  alias SymphonyElixir.{Config, GitHub.StateMapping, Issue, PullRequest}

  @per_page 100
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers(),
         {:ok, raw_issues} <- list_issues(repo!(settings), headers, state: "open") do
      {:ok, normalize_and_filter(raw_issues, settings.active_states, settings)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers(),
         {:ok, raw_issues} <- list_issues(repo!(settings), headers, state: "all") do
      {:ok, normalize_and_filter(raw_issues, state_names, settings)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      ids = Enum.uniq(issue_ids)
      results = Enum.map(ids, &fetch_one(repo!(settings), headers, &1, settings))

      case Enum.split_with(results, &match?({:ok, _}, &1)) do
        {oks, []} -> {:ok, Enum.flat_map(oks, fn {:ok, issue} -> List.wrap(issue) end)}
        {_oks, [{:error, reason} | _]} -> {:error, reason}
      end
    end
  end

  @doc """
  Fetch all open PRs on the configured repo as `PullRequest` structs.

  Reviews and CI status are NOT preloaded here — callers compose those
  via `fetch_pull_request_reviews/1` and `fetch_combined_status/1` to
  keep this function's API surface predictable.
  """
  @spec fetch_open_pull_requests() :: {:ok, [PullRequest.t()]} | {:error, term()}
  def fetch_open_pull_requests do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers(),
         {:ok, raw_prs} <- do_paginate("#{api_base()}/repos/#{repo!(settings)}/pulls", headers, [state: "open"], 1, []) do
      {:ok, Enum.map(raw_prs, &normalize_pull_request/1)}
    end
  end

  @doc """
  Fetch the list of reviews on a PR. Returned in chronological order so
  callers can build a "latest review per author" view trivially.
  """
  @spec fetch_pull_request_reviews(pos_integer() | String.t()) ::
          {:ok, [PullRequest.Review.t()]} | {:error, term()}
  def fetch_pull_request_reviews(pr_number) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      url = "#{api_base()}/repos/#{repo!(settings)}/pulls/#{pr_number}/reviews"

      case do_paginate(url, headers, [], 1, []) do
        {:ok, raw} -> {:ok, Enum.map(raw, &normalize_review/1)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Fetch the canonical CI status for a given commit sha.

  GitHub today exposes CI through two parallel protocols and **neither
  alone** covers all repos:

    * Combined commit statuses (`GET /commits/:sha/status`) — the legacy
      protocol used by external CI integrations (Travis CI, Render,
      CircleCI via app, etc.). Returns `state ∈ success | failure |
      pending`.
    * Check runs (`GET /commits/:sha/check-runs`) — used by GitHub
      Actions and modern Apps. Each run has a separate
      `conclusion ∈ success | failure | neutral | skipped | cancelled |
      timed_out | action_required | null` (null = in progress).

  This function fetches BOTH and merges them via `merge_ci_signals/2`:

    * `:failure` from either side dominates → `:failure`
    * `:pending` from either side dominates over `:success` → `:pending`
    * `:unknown` defers to the other signal

  This is the single function callers should use for "is CI green?".
  `fetch_combined_status/1` and `fetch_check_runs_conclusion/1` are
  exposed individually for testing + special cases but production code
  should compose via `fetch_ci_status/1`.
  """
  @spec fetch_ci_status(String.t()) :: {:ok, PullRequest.ci_status()} | {:error, term()}
  def fetch_ci_status(sha) when is_binary(sha) do
    combined = fetch_combined_status(sha)
    checks = fetch_check_runs_conclusion(sha)

    case {combined, checks} do
      {{:ok, c}, {:ok, k}} -> {:ok, merge_ci_signals(c, k)}
      {{:error, _} = err, _} -> err
      {_, {:error, _} = err} -> err
    end
  end

  @doc """
  Fetch the combined commit-status state (legacy protocol). See
  `fetch_ci_status/1` for the canonical CI signal that also covers
  check runs.
  """
  @spec fetch_combined_status(String.t()) :: {:ok, PullRequest.ci_status()} | {:error, term()}
  def fetch_combined_status(sha) when is_binary(sha) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      url = "#{api_base()}/repos/#{repo!(settings)}/commits/#{sha}/status"

      case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
        # Empty `statuses` list means no legacy commit-status integration
        # is reporting on this commit at all. The endpoint still returns
        # state: "pending" in that case (verified empirically on
        # Actions-only repos), but that "pending" is a phantom signal —
        # there are no underlying statuses to wait on. Treat as :unknown
        # so `merge_ci_signals/2` defers to the check-runs side.
        {:ok, %{status: 200, body: %{"statuses" => []}}} ->
          {:ok, :unknown}

        {:ok, %{status: 200, body: %{"state" => state}}} ->
          {:ok, normalize_ci_state(state)}

        {:ok, %{status: 200}} ->
          {:ok, :unknown}

        {:ok, %{status: 404}} ->
          {:ok, :unknown}

        {:ok, response} ->
          {:error, {:github_http_error, response.status, summarize(response)}}

        {:error, reason} ->
          {:error, {:github_request_failed, reason}}
      end
    end
  end

  @doc """
  Fetch GitHub Actions / Apps check-run conclusions for a commit sha and
  aggregate them into a single `PullRequest.ci_status()` atom.

  Aggregation rules (mirror `merge_ci_signals/2` in shape but operate on
  per-run conclusion strings):

    * Any failure-class conclusion (`failure`, `timed_out`,
      `action_required`, `cancelled`) → `:failure`
    * Any run still in progress (`conclusion == null`) → `:pending`
    * All conclusions in non-failing set (`success`, `neutral`,
      `skipped`) → `:success`
    * Empty list (no check runs at all) → `:unknown`
  """
  @spec fetch_check_runs_conclusion(String.t()) ::
          {:ok, PullRequest.ci_status()} | {:error, term()}
  def fetch_check_runs_conclusion(sha) when is_binary(sha) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      url = "#{api_base()}/repos/#{repo!(settings)}/commits/#{sha}/check-runs"

      case Req.get(url,
             headers: headers,
             params: [per_page: @per_page],
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: 200, body: %{"check_runs" => runs}}} when is_list(runs) ->
          {:ok, aggregate_check_runs(runs)}

        {:ok, %{status: 200}} ->
          {:ok, :unknown}

        {:ok, %{status: 404}} ->
          {:ok, :unknown}

        {:ok, response} ->
          {:error, {:github_http_error, response.status, summarize(response)}}

        {:error, reason} ->
          {:error, {:github_request_failed, reason}}
      end
    end
  end

  defp aggregate_check_runs([]), do: :unknown

  defp aggregate_check_runs(runs) when is_list(runs) do
    conclusions = Enum.map(runs, &Map.get(&1, "conclusion"))

    cond do
      Enum.any?(conclusions, &(&1 in ["failure", "timed_out", "action_required", "cancelled"])) ->
        :failure

      Enum.any?(conclusions, &is_nil/1) ->
        :pending

      Enum.all?(conclusions, &(&1 in ["success", "neutral", "skipped"])) ->
        :success

      true ->
        :unknown
    end
  end

  # Failure dominates; pending dominates success; unknown defers to the other signal.
  defp merge_ci_signals(:failure, _), do: :failure
  defp merge_ci_signals(_, :failure), do: :failure
  defp merge_ci_signals(:pending, _), do: :pending
  defp merge_ci_signals(_, :pending), do: :pending
  defp merge_ci_signals(:unknown, x), do: x
  defp merge_ci_signals(x, :unknown), do: x
  defp merge_ci_signals(x, _), do: x

  defp normalize_pull_request(raw) when is_map(raw) do
    head = raw["head"] || %{}

    %PullRequest{
      number: raw["number"],
      head_sha: head["sha"],
      head_ref: head["ref"],
      state: normalize_pr_state(raw["state"], raw["merged_at"]),
      draft: raw["draft"] == true,
      url: raw["html_url"],
      title: raw["title"],
      body: raw["body"],
      author_login: PullRequest.normalize_login(get_in(raw, ["user", "login"])),
      linked_issue_number: extract_linked_issue_number(raw["body"]),
      latest_reviews_by_author: %{},
      reviews: [],
      ci_status: :unknown,
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

  defp normalize_pr_state(_state, merged_at) when is_binary(merged_at), do: :merged
  defp normalize_pr_state("open", _), do: :open
  defp normalize_pr_state("closed", _), do: :closed
  defp normalize_pr_state(_, _), do: :open

  defp normalize_review(raw) when is_map(raw) do
    %PullRequest.Review{
      author_login: PullRequest.normalize_login(get_in(raw, ["user", "login"])),
      state: PullRequest.Review.normalize_state(raw["state"]),
      commit_id: raw["commit_id"],
      submitted_at: parse_datetime(raw["submitted_at"]),
      body: raw["body"]
    }
  end

  defp normalize_ci_state("success"), do: :success
  defp normalize_ci_state("failure"), do: :failure
  defp normalize_ci_state("error"), do: :failure
  defp normalize_ci_state("pending"), do: :pending
  defp normalize_ci_state(_), do: :unknown

  # Best-effort extraction of `Closes #N` / `Fixes #N` from PR body.
  # Falls back to `nil` when the PR body doesn't reference an issue —
  # the adapter then attaches the PR only when it can resolve the link
  # via a branch-name heuristic instead.
  @link_regex ~r/(?:closes|fixes|resolves)\s+#(\d+)/i
  defp extract_linked_issue_number(body) when is_binary(body) do
    case Regex.run(@link_regex, body) do
      [_, num_str] ->
        case Integer.parse(num_str) do
          {n, _} -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_linked_issue_number(_), do: nil

  @spec fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}
  def fetch_sub_issues(issue_id) when is_binary(issue_id) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      url = "#{api_base()}/repos/#{repo!(settings)}/issues/#{issue_id}/sub_issues"

      case Req.get(url, headers: headers, params: [per_page: @per_page], connect_options: [timeout: 30_000]) do
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          {:ok, body |> Enum.map(& &1["number"]) |> Enum.reject(&is_nil/1)}

        {:ok, response} ->
          {:error, {:github_http_error, response.status, summarize(response)}}

        {:error, reason} ->
          {:error, {:github_request_failed, reason}}
      end
    end
  end

  @spec fetch_issue_comments(String.t()) ::
          {:ok, [%{id: integer(), body: String.t(), updated_at: DateTime.t() | nil}]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers() do
      url = "#{api_base()}/repos/#{repo!(settings)}/issues/#{issue_id}/comments"

      do_paginate_comments(url, headers, [], 1, [])
    end
  end

  defp do_paginate_comments(url, headers, params, page, acc) do
    full_params = Keyword.merge(params, per_page: @per_page, page: page)

    case Req.get(url, headers: headers, params: full_params, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        normalized = Enum.map(body, &normalize_comment/1)
        new_acc = acc ++ normalized

        if length(body) < @per_page do
          {:ok, new_acc}
        else
          do_paginate_comments(url, headers, params, page + 1, new_acc)
        end

      {:ok, response} ->
        {:error, {:github_http_error, response.status, summarize(response)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end

  defp normalize_comment(%{"id" => id, "body" => body} = raw) do
    %{
      id: id,
      body: body || "",
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    settings = Config.settings!().tracker

    with {:ok, headers} <- request_headers(),
         {:ok, _} <-
           post_json(
             "#{api_base()}/repos/#{repo!(settings)}/issues/#{issue_id}/comments",
             headers,
             %{body: body}
           ) do
      :ok
    end
  end

  @spec set_labels_and_state(String.t(), [String.t()], :open | :closed | :keep) ::
          :ok | {:error, term()}
  def set_labels_and_state(issue_id, labels, state) when is_binary(issue_id) and is_list(labels) do
    settings = Config.settings!().tracker
    payload = %{labels: labels} |> maybe_put_state(state)

    with {:ok, headers} <- request_headers(),
         {:ok, _} <-
           patch_json(
             "#{api_base()}/repos/#{repo!(settings)}/issues/#{issue_id}",
             headers,
             payload
           ) do
      :ok
    end
  end

  defp maybe_put_state(payload, :keep), do: payload
  defp maybe_put_state(payload, state) when state in [:open, :closed], do: Map.put(payload, :state, Atom.to_string(state))

  defp list_issues(repo, headers, params) do
    do_paginate("#{api_base()}/repos/#{repo}/issues", headers, params, 1, [])
  end

  defp do_paginate(url, headers, params, page, acc) do
    full_params = Keyword.merge(params, per_page: @per_page, page: page)

    case Req.get(url, headers: headers, params: full_params, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        if length(body) < @per_page do
          {:ok, Enum.reverse(body, acc) |> Enum.reverse()}
        else
          do_paginate(url, headers, params, page + 1, body ++ acc)
        end

      {:ok, response} ->
        {:error, {:github_http_error, response.status, summarize(response)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end

  defp fetch_one(repo, headers, issue_id, settings) do
    url = "#{api_base()}/repos/#{repo}/issues/#{issue_id}"

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, normalize_issue(body, settings.active_states, settings.terminal_states)}

      {:ok, %{status: 404}} ->
        {:ok, nil}

      {:ok, response} ->
        {:error, {:github_http_error, response.status, summarize(response)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end

  defp post_json(url, headers, payload) do
    case Req.post(url, headers: headers, json: payload, connect_options: [timeout: 30_000]) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response.body}
      {:ok, response} -> {:error, {:github_http_error, response.status, summarize(response)}}
      {:error, reason} -> {:error, {:github_request_failed, reason}}
    end
  end

  defp patch_json(url, headers, payload) do
    case Req.patch(url, headers: headers, json: payload, connect_options: [timeout: 30_000]) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response.body}
      {:ok, response} -> {:error, {:github_http_error, response.status, summarize(response)}}
      {:error, reason} -> {:error, {:github_request_failed, reason}}
    end
  end

  defp normalize_and_filter(raw_issues, allowed_states, settings) do
    raw_issues
    |> Enum.reject(&pull_request?/1)
    |> Enum.map(&normalize_issue(&1, settings.active_states, settings.terminal_states))
    |> Enum.filter(&(&1.state in allowed_states))
  end

  defp pull_request?(%{"pull_request" => pr}) when is_map(pr), do: true
  defp pull_request?(_), do: false

  defp normalize_issue(raw, active_states, terminal_states) when is_map(raw) do
    labels = extract_labels(raw)
    github_state = raw["state"] || "open"
    state_name = StateMapping.state_from_labels(labels, github_state, active_states, terminal_states)

    %Issue{
      id: to_string(raw["number"]),
      identifier: to_string(raw["number"]),
      title: raw["title"],
      description: raw["body"],
      priority: nil,
      state: state_name,
      branch_name: nil,
      url: raw["html_url"],
      assignee_id: get_in(raw, ["assignee", "login"]),
      labels: labels,
      assigned_to_worker: assigned_to_worker_for_state(state_name),
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

  defp assigned_to_worker_for_state("Epic Tracking"), do: false
  defp assigned_to_worker_for_state(_), do: true

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp request_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Accept", "application/vnd.github+json"},
           {"X-GitHub-Api-Version", "2022-11-28"},
           {"User-Agent", "symphony-elixir"}
         ]}
    end
  end

  defp repo!(%{repo: repo}) when is_binary(repo) and repo != "", do: repo

  defp repo!(_),
    do: raise(ArgumentError, "tracker.repo must be set (format: \"owner/name\") for github tracker")

  defp api_base do
    Application.get_env(:symphony_elixir, :github_api_base, "https://api.github.com")
  end

  defp summarize(response) do
    body =
      response
      |> Map.get(:body)
      |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
      |> String.slice(0, @max_error_body_log_bytes)

    "status=#{response.status} body=#{body}"
  end
end
