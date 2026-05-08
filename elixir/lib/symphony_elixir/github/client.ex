defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST API client for issue polling and writes.

  Uses `tracker.repo` (format: "owner/name"), `tracker.endpoint` (defaults to
  https://api.github.com), and `tracker.api_key` (a personal access token or
  fine-grained token with `repo` scope) from the orchestrator config.
  """

  require Logger
  alias SymphonyElixir.{Config, GitHub.StateMapping, Issue}

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

        if length(body) < @per_page do
          {:ok, Enum.reverse(acc) ++ normalized}
        else
          do_paginate_comments(url, headers, params, page + 1, acc ++ normalized)
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

    %Issue{
      id: to_string(raw["number"]),
      identifier: to_string(raw["number"]),
      title: raw["title"],
      description: raw["body"],
      priority: nil,
      state: StateMapping.state_from_labels(labels, github_state, active_states, terminal_states),
      branch_name: nil,
      url: raw["html_url"],
      assignee_id: get_in(raw, ["assignee", "login"]),
      labels: labels,
      assigned_to_worker: true,
      created_at: parse_datetime(raw["created_at"]),
      updated_at: parse_datetime(raw["updated_at"])
    }
  end

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
