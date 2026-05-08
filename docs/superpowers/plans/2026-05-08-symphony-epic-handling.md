# Symphony Epic Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Symphony detect GitHub epic issues, run a planner agent that emits a YAML dependency plan, then dispatch each sub-issue as an independent unit of work in topo order.

**Architecture:** When polling picks up a `Todo` issue, Symphony calls GitHub's sub-issues REST API. If non-empty, it dispatches a planner agent (variant of the existing single-issue agent run) that posts a YAML plan as a comment on the parent and labels children `symphony:todo`. On subsequent polls, the GitHub adapter parses the plan to populate `blocked_by` on each child; the existing orchestrator dispatch gate (`orchestrator.ex:614-629`) handles topo ordering for free. A reaper closes the parent once every child is `Done`.

**Tech Stack:** Elixir 1.17+, OTP 26, Phoenix 1.8, Req 0.5, YamlElixir 2.12, Solid 1.2, ExUnit (async), GitHub REST API v2022-11-28.

**Pre-requisites:** Spec at `docs/superpowers/specs/2026-05-08-symphony-epic-handling-design.md` must be read.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `elixir/lib/symphony_elixir/github/epic_plan.ex` | YAML plan extraction, validation, blockers lookup. Pure functions, no I/O. |
| `elixir/test/symphony_elixir/github/epic_plan_test.exs` | Unit tests for plan parsing edge cases. |
| `elixir/test/symphony_elixir/github/adapter_test.exs` | Tests for adapter: epic detection, `blocked_by` population, `assigned_to_worker` gating. Uses a stub Client module. |
| `elixir/test/symphony_elixir/github/client_stub.ex` | Test-only stub for `GitHub.Client` configurable per test via process dict. Exposes the same API. |
| `elixir/test/symphony_elixir/orchestrator_epic_test.exs` | End-to-end Memory-tracker-driven epic flow test. |

### Modified files

| Path | Change |
|---|---|
| `elixir/lib/symphony_elixir/github/client.ex` | + `fetch_sub_issues/1`, `fetch_issue_comments/1` |
| `elixir/lib/symphony_elixir/github/adapter.ex` | epic detection in fetch path, `assigned_to_worker` for Epic Tracking, `blocked_by` from plans |
| `elixir/lib/symphony_elixir/tracker.ex` | + optional `c:fetch_sub_issues/1` callback (default returns `{:ok, []}`) |
| `elixir/lib/symphony_elixir/tracker/memory.ex` | implement `fetch_sub_issues/1` for tests |
| `elixir/lib/symphony_elixir/workflow.ex` | parse `prompts.epic_planner` from frontmatter |
| `elixir/lib/symphony_elixir/prompt_builder.ex` | `:variant` keyword option (`:default \| :epic_planner`) |
| `elixir/lib/symphony_elixir/orchestrator.ex` | epic dispatch trigger + reaper pass |
| `elixir/lib/symphony_elixir/agent_runner.ex` | thread `:variant` and `:max_turns` overrides through |
| `elixir/SPEC.md` | new section "Epic handling" |
| `elixir/WORKFLOW.alpha.md` (operator-facing example) | Add `Epic Tracking` to active_states + epic_planner prompt body |

### Boundary recap (one-liners)

- `EpicPlan` knows YAML and the `<!-- symphony-plan:v1 -->` markers, knows nothing about GitHub or HTTP.
- `Client` knows GitHub HTTP, knows nothing about plans or labels.
- `Adapter` glues them: turns raw issues + plan comments into `%Issue{}` structs with proper `blocked_by` and `assigned_to_worker`.
- `Orchestrator` decides *when* to spawn the planner agent and *when* to close the parent. It does not parse YAML.
- `Workflow + PromptBuilder` decide *which* prompt template to render given a variant.

---

## Task 1: Add stubbing seam to `GitHub.Client` for new functions

The existing adapter already has a `client_module/0` swap point (`github/adapter.ex:73-75`). We need to extend that pattern so the new client functions can be stubbed in adapter tests without HTTP.

**Files:**
- Test: `elixir/test/symphony_elixir/github/client_stub.ex`

- [ ] **Step 1: Create the stub module**

```elixir
# elixir/test/symphony_elixir/github/client_stub.ex
defmodule SymphonyElixir.GitHub.ClientStub do
  @moduledoc """
  Test-only stub for SymphonyElixir.GitHub.Client. Each function looks up a
  per-process value via Process.put/get; tests configure responses with
  `set/2` in their `setup` block. Default response if unset is an error so
  tests fail loudly when they forget to configure a function.
  """

  alias SymphonyElixir.Issue

  @callback_keys [
    :fetch_candidate_issues,
    :fetch_issues_by_states,
    :fetch_issue_states_by_ids,
    :fetch_sub_issues,
    :fetch_issue_comments,
    :create_comment,
    :set_labels_and_state
  ]

  @spec set(atom(), term()) :: :ok
  def set(key, value) when key in @callback_keys do
    Process.put({__MODULE__, key}, value)
    :ok
  end

  @spec lookup!(atom()) :: term()
  defp lookup!(key) do
    case Process.get({__MODULE__, key}) do
      nil -> raise "ClientStub: no response configured for #{inspect(key)}"
      value -> value
    end
  end

  def fetch_candidate_issues, do: lookup!(:fetch_candidate_issues)
  def fetch_issues_by_states(_states), do: lookup!(:fetch_issues_by_states)
  def fetch_issue_states_by_ids(_ids), do: lookup!(:fetch_issue_states_by_ids)
  def fetch_sub_issues(_issue_id), do: lookup!(:fetch_sub_issues)
  def fetch_issue_comments(_issue_id), do: lookup!(:fetch_issue_comments)
  def create_comment(_id, _body), do: lookup!(:create_comment)
  def set_labels_and_state(_id, _labels, _state), do: lookup!(:set_labels_and_state)

  @spec sample_issue(keyword()) :: Issue.t()
  def sample_issue(overrides \\ []) do
    base = %Issue{
      id: "100",
      identifier: "100",
      title: "stub issue",
      description: "",
      state: "Todo",
      url: "https://github.com/example/example/issues/100",
      labels: [],
      blocked_by: [],
      assigned_to_worker: true,
      created_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    struct!(base, overrides)
  end
end
```

- [ ] **Step 2: Verify the stub file compiles via mix**

Run: `cd elixir && mix compile 2>&1 | tail -5`
Expected: no errors. (The file lives under `test/`; `mix.exs` already includes `test/support` style paths if `test_helper.exs` requires it. If it does NOT compile from `test/`, move into `test/support/` instead.)

- [ ] **Step 3: Commit**

```bash
git add elixir/test/symphony_elixir/github/client_stub.ex
git commit -m "test(github): add Client stub for adapter tests"
```

---

## Task 2: `GitHub.Client.fetch_sub_issues/1` — REST call to sub-issues endpoint

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Test: `elixir/test/symphony_elixir/github/client_test.exs` (new)

- [ ] **Step 1: Write the failing test**

```elixir
# elixir/test/symphony_elixir/github/client_test.exs
defmodule SymphonyElixir.GitHub.ClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, GitHub.Client}

  setup do
    settings = %{tracker: %{kind: "github", repo: "owner/name", api_key: "test-token", endpoint: nil}}
    :ok = Application.put_env(:symphony_elixir, :test_settings_override, settings)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :test_settings_override) end)
    :ok
  end

  describe "fetch_sub_issues/1" do
    test "returns the parsed list of issue numbers from a 200 response" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        body = Jason.encode!([
          %{"number" => 134, "title" => "schema"},
          %{"number" => 135, "title" => "migration"}
        ])
        Plug.Conn.resp(conn, 200, body)
      end)

      assert {:ok, [134, 135]} = Client.fetch_sub_issues("133")
    end

    test "returns empty list when GitHub returns 200 with []" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        Plug.Conn.resp(conn, 200, "[]")
      end)

      assert {:ok, []} = Client.fetch_sub_issues("133")
    end

    test "returns error tuple on HTTP error" do
      bypass = Bypass.open()
      Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

      Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/sub_issues", fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message":"not found"}))
      end)

      assert {:error, {:github_http_error, 404, _}} = Client.fetch_sub_issues("133")
    end
  end
end
```

- [ ] **Step 2: Add Bypass to deps and the api_base override**

Modify `elixir/mix.exs` deps list — add `{:bypass, "~> 2.1", only: :test}`.

Modify `elixir/lib/symphony_elixir/github/client.ex` — replace the hardcoded `api_base/0`:

```elixir
defp api_base do
  Application.get_env(:symphony_elixir, :github_api_base, "https://api.github.com")
end
```

Then run:
```bash
cd elixir && mix deps.get
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs:14 --max-failures 1`
Expected: FAIL — `Client.fetch_sub_issues/1` is undefined.

- [ ] **Step 4: Write the minimal implementation**

Add to `elixir/lib/symphony_elixir/github/client.ex`:

```elixir
@spec fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}
def fetch_sub_issues(issue_id) when is_binary(issue_id) do
  settings = Config.settings!().tracker

  with {:ok, headers} <- request_headers() do
    url = "#{api_base()}/repos/#{repo!(settings)}/issues/#{issue_id}/sub_issues"

    case Req.get(url, headers: headers, params: [per_page: @per_page], connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, & &1["number"]) |> Enum.reject(&is_nil/1)}

      {:ok, response} ->
        {:error, {:github_http_error, response.status, summarize(response)}}

      {:error, reason} ->
        {:error, {:github_request_failed, reason}}
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add elixir/mix.exs elixir/mix.lock elixir/lib/symphony_elixir/github/client.ex elixir/test/symphony_elixir/github/client_test.exs
git commit -m "feat(github): fetch_sub_issues/1 calls /issues/N/sub_issues"
```

---

## Task 3: `GitHub.Client.fetch_issue_comments/1` — list comments

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex`
- Test: `elixir/test/symphony_elixir/github/client_test.exs`

- [ ] **Step 1: Add the failing test**

Add to the existing test file:

```elixir
describe "fetch_issue_comments/1" do
  test "returns comments with id, body, updated_at" do
    bypass = Bypass.open()
    Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues/133/comments", fn conn ->
      body = Jason.encode!([
        %{"id" => 1, "body" => "first comment", "updated_at" => "2026-05-08T10:00:00Z"},
        %{"id" => 2, "body" => "second comment", "updated_at" => "2026-05-08T11:00:00Z"}
      ])
      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, comments} = Client.fetch_issue_comments("133")
    assert [%{id: 1, body: "first comment"}, %{id: 2, body: "second comment"}] = comments
    assert %DateTime{} = hd(comments).updated_at
  end

  test "paginates when needed" do
    bypass = Bypass.open()
    Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

    page1 = for n <- 1..100, do: %{"id" => n, "body" => "c#{n}", "updated_at" => "2026-05-08T10:00:00Z"}
    page2 = [%{"id" => 101, "body" => "c101", "updated_at" => "2026-05-08T11:00:00Z"}]

    Bypass.expect(bypass, "GET", "/repos/owner/name/issues/133/comments", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["page"] || "1")
      payload = if page == 1, do: page1, else: page2
      Plug.Conn.resp(conn, 200, Jason.encode!(payload))
    end)

    assert {:ok, comments} = Client.fetch_issue_comments("133")
    assert length(comments) == 101
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs --only describe:"fetch_issue_comments/1"`
Expected: FAIL — function undefined.

- [ ] **Step 3: Write the implementation**

Add to `elixir/lib/symphony_elixir/github/client.ex`:

```elixir
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
        {:ok, Enum.reverse(normalized, acc) |> Enum.reverse()}
      else
        do_paginate_comments(url, headers, params, page + 1, normalized ++ acc)
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs`
Expected: 5 tests, 0 failures (3 from Task 2 + 2 from Task 3).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github/client.ex elixir/test/symphony_elixir/github/client_test.exs
git commit -m "feat(github): fetch_issue_comments/1 with pagination"
```

---

## Task 4: `GitHub.EpicPlan` — extract YAML block from comments

**Files:**
- Create: `elixir/lib/symphony_elixir/github/epic_plan.ex`
- Test: `elixir/test/symphony_elixir/github/epic_plan_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# elixir/test/symphony_elixir/github/epic_plan_test.exs
defmodule SymphonyElixir.GitHub.EpicPlanTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.EpicPlan

  defp comment(body, updated_at \\ ~U[2026-05-08 12:00:00Z]) do
    %{id: :erlang.unique_integer([:positive]), body: body, updated_at: updated_at}
  end

  defp valid_block(opts \\ []) do
    """
    Some explanatory prose for the human reader.

    <!-- symphony-plan:v1 -->
    schema: 1
    generated_at: #{Keyword.get(opts, :generated_at, "2026-05-08T12:34:56Z")}
    sub_issues:
      - id: 134
        blocked_by: []
        rationale: "Defines schema."
      - id: 135
        blocked_by: [134]
        rationale: "Migration after schema."
    <!-- /symphony-plan -->
    """
  end

  describe "extract/1" do
    test "returns :no_plan when no comments contain the marker" do
      assert {:error, :no_plan} = EpicPlan.extract([comment("hi"), comment("bye")])
    end

    test "parses a valid block" do
      assert {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert plan.schema == 1
      assert length(plan.sub_issues) == 2
      assert Enum.find(plan.sub_issues, &(&1.id == 135)).blocked_by == [134]
    end

    test "ignores prose before/after the markers" do
      body = "Plan v1 below.\n\n#{valid_block()}\n\n(updates as work progresses)"
      assert {:ok, _plan} = EpicPlan.extract([comment(body)])
    end

    test "returns the latest plan when multiple comments contain blocks" do
      old = comment(valid_block(generated_at: "2026-05-08T10:00:00Z"), ~U[2026-05-08 10:01:00Z])
      new = comment(valid_block(generated_at: "2026-05-08T13:00:00Z"), ~U[2026-05-08 13:01:00Z])
      assert {:ok, plan} = EpicPlan.extract([old, new])
      assert plan.generated_at == ~U[2026-05-08 13:00:00Z]
    end

    test "schema mismatch -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 99
      sub_issues: []
      <!-- /symphony-plan -->
      """

      assert {:error, {:schema_mismatch, 99}} = EpicPlan.extract([comment(bad)])
    end

    test "malformed YAML -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: 134
          blocked_by: [oops
      <!-- /symphony-plan -->
      """

      assert {:error, {:invalid_yaml, _}} = EpicPlan.extract([comment(bad)])
    end

    test "missing sub_issues field -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      <!-- /symphony-plan -->
      """

      assert {:error, {:missing_field, "sub_issues"}} = EpicPlan.extract([comment(bad)])
    end

    test "non-integer id -> error" do
      bad = """
      <!-- symphony-plan:v1 -->
      schema: 1
      sub_issues:
        - id: "not-a-number"
          blocked_by: []
      <!-- /symphony-plan -->
      """

      assert {:error, {:invalid_sub_issue, _}} = EpicPlan.extract([comment(bad)])
    end
  end

  describe "blockers_for/2" do
    test "returns the declared blocked_by list" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert EpicPlan.blockers_for(plan, 134) == []
      assert EpicPlan.blockers_for(plan, 135) == [134]
    end

    test "returns [] for an id not in the plan" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert EpicPlan.blockers_for(plan, 999) == []
    end
  end

  describe "validate_against_sub_issues/2" do
    test "passes when plan ids match sub_issue numbers" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert :ok = EpicPlan.validate_against_sub_issues(plan, [134, 135])
    end

    test "fails when plan references unknown id" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert {:error, {:plan_references_unknown_ids, [135]}} =
               EpicPlan.validate_against_sub_issues(plan, [134])
    end

    test "fails when plan misses a sub_issue" do
      {:ok, plan} = EpicPlan.extract([comment(valid_block())])
      assert {:error, {:plan_missing_sub_issues, [136]}} =
               EpicPlan.validate_against_sub_issues(plan, [134, 135, 136])
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/github/epic_plan_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write the implementation**

```elixir
# elixir/lib/symphony_elixir/github/epic_plan.ex
defmodule SymphonyElixir.GitHub.EpicPlan do
  @moduledoc """
  Parses the YAML dependency plan that the planner agent comments on a parent
  epic. Pure functions — no I/O.

  Plan format (lives between markers in a single comment body):

      <!-- symphony-plan:v1 -->
      schema: 1
      generated_at: 2026-05-08T12:34:56Z
      sub_issues:
        - id: 134
          blocked_by: []
          rationale: "..."
      <!-- /symphony-plan -->
  """

  @start_marker "<!-- symphony-plan:v1 -->"
  @end_marker "<!-- /symphony-plan -->"

  @type sub_issue :: %{id: integer(), blocked_by: [integer()], rationale: String.t() | nil}
  @type plan :: %{schema: 1, generated_at: DateTime.t() | nil, sub_issues: [sub_issue()]}

  @spec extract([%{id: term(), body: String.t(), updated_at: DateTime.t() | nil}]) ::
          {:ok, plan()}
          | {:error,
             :no_plan
             | {:schema_mismatch, term()}
             | {:invalid_yaml, term()}
             | {:missing_field, String.t()}
             | {:invalid_sub_issue, term()}}
  def extract(comments) when is_list(comments) do
    candidates =
      comments
      |> Enum.filter(&contains_marker?/1)
      |> Enum.sort_by(&comment_sort_key/1, {:desc, DateTime})

    case candidates do
      [] -> {:error, :no_plan}
      [latest | _] -> parse_block(latest.body)
    end
  end

  @spec blockers_for(plan(), integer()) :: [integer()]
  def blockers_for(%{sub_issues: subs}, child_id) when is_integer(child_id) do
    case Enum.find(subs, &(&1.id == child_id)) do
      nil -> []
      %{blocked_by: bs} -> bs
    end
  end

  @spec validate_against_sub_issues(plan(), [integer()]) ::
          :ok
          | {:error,
             {:plan_references_unknown_ids, [integer()]}
             | {:plan_missing_sub_issues, [integer()]}}
  def validate_against_sub_issues(%{sub_issues: plan_subs}, actual_ids) when is_list(actual_ids) do
    plan_ids = MapSet.new(plan_subs, & &1.id)
    actual_set = MapSet.new(actual_ids)

    extra = plan_ids |> MapSet.difference(actual_set) |> Enum.sort()
    missing = actual_set |> MapSet.difference(plan_ids) |> Enum.sort()

    cond do
      extra != [] -> {:error, {:plan_references_unknown_ids, extra}}
      missing != [] -> {:error, {:plan_missing_sub_issues, missing}}
      true -> :ok
    end
  end

  defp contains_marker?(%{body: body}) when is_binary(body) do
    String.contains?(body, @start_marker) and String.contains?(body, @end_marker)
  end

  defp contains_marker?(_), do: false

  defp comment_sort_key(%{updated_at: %DateTime{} = dt}), do: dt
  defp comment_sort_key(_), do: ~U[1970-01-01 00:00:00Z]

  defp parse_block(body) do
    with {:ok, yaml} <- slice_between_markers(body),
         {:ok, decoded} <- decode_yaml(yaml),
         {:ok, schema} <- check_schema(decoded),
         {:ok, sub_issues} <- parse_sub_issues(decoded) do
      {:ok,
       %{
         schema: schema,
         generated_at: parse_iso_datetime(decoded["generated_at"]),
         sub_issues: sub_issues
       }}
    end
  end

  defp slice_between_markers(body) do
    [_, after_start] = String.split(body, @start_marker, parts: 2)
    [yaml, _] = String.split(after_start, @end_marker, parts: 2)
    {:ok, String.trim(yaml)}
  rescue
    _ -> {:error, :no_plan}
  end

  defp decode_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_yaml, :not_a_map}}
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp check_schema(%{"schema" => 1}), do: {:ok, 1}
  defp check_schema(%{"schema" => other}), do: {:error, {:schema_mismatch, other}}
  defp check_schema(_), do: {:error, {:missing_field, "schema"}}

  defp parse_sub_issues(%{"sub_issues" => list}) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_one(raw) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      err -> err
    end
  end

  defp parse_sub_issues(_), do: {:error, {:missing_field, "sub_issues"}}

  defp parse_one(%{"id" => id, "blocked_by" => blocked} = raw)
       when is_integer(id) and is_list(blocked) do
    if Enum.all?(blocked, &is_integer/1) do
      {:ok, %{id: id, blocked_by: blocked, rationale: raw["rationale"]}}
    else
      {:error, {:invalid_sub_issue, raw}}
    end
  end

  defp parse_one(raw), do: {:error, {:invalid_sub_issue, raw}}

  defp parse_iso_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_iso_datetime(_), do: nil
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/epic_plan_test.exs`
Expected: ~12 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github/epic_plan.ex elixir/test/symphony_elixir/github/epic_plan_test.exs
git commit -m "feat(github): EpicPlan parses YAML dependency plan from comments"
```

---

## Task 5: Tracker behaviour: optional `fetch_sub_issues/1` callback

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`

- [ ] **Step 1: Write the failing test**

Append to a new file `elixir/test/symphony_elixir/tracker_test.exs`:

```elixir
defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: true

  test "fetch_sub_issues/1 falls back to {:ok, []} when adapter doesn't implement it" do
    # Memory tracker is the default for tests; before this task it doesn't
    # implement fetch_sub_issues. The Tracker module wraps the call.
    Application.put_env(:symphony_elixir, :test_settings_override,
      %{tracker: %{kind: "memory"}})

    on_exit(fn -> Application.delete_env(:symphony_elixir, :test_settings_override) end)

    assert {:ok, []} = SymphonyElixir.Tracker.fetch_sub_issues("any-id")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs`
Expected: FAIL — `fetch_sub_issues/1` not defined on Tracker.

- [ ] **Step 3: Implement**

Modify `elixir/lib/symphony_elixir/tracker.ex` — add the callback, the optional declaration, and the wrapper:

```elixir
@callback fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}

@optional_callbacks secret_env_var: 0, fetch_sub_issues: 1

@spec fetch_sub_issues(String.t()) :: {:ok, [integer()]} | {:error, term()}
def fetch_sub_issues(issue_id) do
  with {:ok, mod} <- adapter() do
    if function_exported?(mod, :fetch_sub_issues, 1) do
      mod.fetch_sub_issues(issue_id)
    else
      {:ok, []}
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker.ex elixir/test/symphony_elixir/tracker_test.exs
git commit -m "feat(tracker): optional fetch_sub_issues/1 callback"
```

---

## Task 6: Memory tracker: implement `fetch_sub_issues/1` for tests

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker/memory.ex`

- [ ] **Step 1: Write failing tests**

Append to `elixir/test/symphony_elixir/tracker_test.exs`:

```elixir
describe "Memory adapter fetch_sub_issues/1" do
  alias SymphonyElixir.Issue
  alias SymphonyElixir.Tracker.Memory

  test "returns sub_of children for an issue id" do
    issues = [
      %Issue{id: "100", identifier: "100", title: "Epic", state: "Todo"},
      %Issue{id: "101", identifier: "101", title: "Child A", state: "Todo"},
      %Issue{id: "102", identifier: "102", title: "Child B", state: "Todo"}
    ]

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"100" => [101, 102]})
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_sub_issues)
    end)

    assert {:ok, [101, 102]} = Memory.fetch_sub_issues("100")
    assert {:ok, []} = Memory.fetch_sub_issues("101")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs --only describe:"Memory adapter fetch_sub_issues/1"`
Expected: FAIL — undefined function.

- [ ] **Step 3: Implement**

Append to `elixir/lib/symphony_elixir/tracker/memory.ex`:

```elixir
@impl true
def fetch_sub_issues(parent_id) when is_binary(parent_id) do
  map = Application.get_env(:symphony_elixir, :memory_tracker_sub_issues, %{})
  {:ok, Map.get(map, parent_id, [])}
end
```

Also remove `:fetch_sub_issues` from the optional callbacks list in Memory by NOT adding `@impl true` carelessly — the fact that we now provide an impl is fine; nothing else changes.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/tracker_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker/memory.ex elixir/test/symphony_elixir/tracker_test.exs
git commit -m "feat(tracker/memory): support sub_issues for tests"
```

---

## Task 7: GitHub Adapter: implement `fetch_sub_issues/1`

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/adapter.ex`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/github/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.GitHub.AdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.GitHub.{Adapter, ClientStub}

  setup do
    Application.put_env(:symphony_elixir, :github_client_module, ClientStub)
    Application.put_env(:symphony_elixir, :test_settings_override,
      %{tracker: %{
        kind: "github",
        repo: "owner/name",
        api_key: "test",
        active_states: ["Todo", "In Progress", "Epic Tracking"],
        terminal_states: ["Human Review", "Done"]
      }})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :github_client_module)
      Application.delete_env(:symphony_elixir, :test_settings_override)
    end)

    :ok
  end

  describe "fetch_sub_issues/1" do
    test "delegates to the configured Client module" do
      ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
      assert {:ok, [134, 135]} = Adapter.fetch_sub_issues("133")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/github/adapter_test.exs`
Expected: FAIL — Adapter.fetch_sub_issues/1 undefined.

- [ ] **Step 3: Implement**

Add to `elixir/lib/symphony_elixir/github/adapter.ex`:

```elixir
@impl true
def fetch_sub_issues(issue_id) when is_binary(issue_id) do
  client_module().fetch_sub_issues(issue_id)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/adapter_test.exs`
Expected: 1 test, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github/adapter.ex elixir/test/symphony_elixir/github/adapter_test.exs
git commit -m "feat(github): adapter delegates fetch_sub_issues to Client"
```

---

## Task 8: GitHub adapter: `assigned_to_worker = false` for `Epic Tracking`

This makes the existing orchestrator gate (`issue_routable_to_worker?`, `orchestrator.ex:608-612`) skip parent epics from dispatch.

**Files:**
- Modify: `elixir/lib/symphony_elixir/github/client.ex` (it's `normalize_issue/3` that builds the struct)

- [ ] **Step 1: Add a failing test**

Add to `elixir/test/symphony_elixir/github/client_test.exs`:

```elixir
describe "normalize_issue (via fetch_candidate_issues)" do
  test "Epic Tracking issues get assigned_to_worker: false" do
    bypass = Bypass.open()
    Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues", fn conn ->
      payload =
        Jason.encode!([
          %{
            "number" => 1,
            "title" => "epic",
            "body" => "",
            "state" => "open",
            "html_url" => "https://x",
            "labels" => [%{"name" => "symphony:epic-tracking"}],
            "created_at" => "2026-05-08T10:00:00Z",
            "updated_at" => "2026-05-08T10:00:00Z"
          }
        ])

      Plug.Conn.resp(conn, 200, payload)
    end)

    Application.put_env(:symphony_elixir, :test_settings_override,
      %{tracker: %{
        kind: "github",
        repo: "owner/name",
        api_key: "test",
        active_states: ["Todo", "In Progress", "Epic Tracking"],
        terminal_states: ["Human Review", "Done"]
      }})

    {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.state == "Epic Tracking"
    assert issue.assigned_to_worker == false
  end

  test "non-Epic Tracking issues retain assigned_to_worker: true" do
    bypass = Bypass.open()
    Application.put_env(:symphony_elixir, :github_api_base, "http://localhost:#{bypass.port}")

    Bypass.expect_once(bypass, "GET", "/repos/owner/name/issues", fn conn ->
      payload =
        Jason.encode!([
          %{
            "number" => 2,
            "title" => "regular",
            "body" => "",
            "state" => "open",
            "html_url" => "https://x",
            "labels" => [%{"name" => "symphony:todo"}],
            "created_at" => "2026-05-08T10:00:00Z",
            "updated_at" => "2026-05-08T10:00:00Z"
          }
        ])

      Plug.Conn.resp(conn, 200, payload)
    end)

    Application.put_env(:symphony_elixir, :test_settings_override,
      %{tracker: %{
        kind: "github",
        repo: "owner/name",
        api_key: "test",
        active_states: ["Todo", "In Progress", "Epic Tracking"],
        terminal_states: ["Human Review", "Done"]
      }})

    {:ok, [issue]} = Client.fetch_candidate_issues()
    assert issue.state == "Todo"
    assert issue.assigned_to_worker == true
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs --only describe:"normalize_issue (via fetch_candidate_issues)"`
Expected: FAIL on the Epic Tracking case (assigned_to_worker is `true` because nothing flips it).

- [ ] **Step 3: Implement**

Modify `normalize_issue/3` in `elixir/lib/symphony_elixir/github/client.ex` to compute `assigned_to_worker` based on resolved state:

```elixir
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/client_test.exs`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/github/client.ex elixir/test/symphony_elixir/github/client_test.exs
git commit -m "feat(github): Epic Tracking issues are not routable to workers"
```

---

## Task 9: `Tracker.fetch_plan/1` callback + GitHub adapter populates `blocked_by`

This is the integration of `EpicPlan` into the read path. We push the plan-lookup behind a new optional `Tracker` callback (`fetch_plan/1`) so the orchestrator depends only on the abstract interface; GitHub implements it via comments + EpicPlan, Memory implements it via app env (Task 17 will exercise the Memory side).

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex` (callback declaration + wrapper)
- Modify: `elixir/lib/symphony_elixir/github/adapter.ex` (impl + populate_blocked_by_from_plans)
- Modify: `elixir/lib/symphony_elixir/tracker/memory.ex` (test-only impl reading app env)

- [ ] **Step 1: Write the failing test**

Add to `elixir/test/symphony_elixir/github/adapter_test.exs`:

```elixir
describe "fetch_candidate_issues with epic plan" do
  test "children inherit blocked_by from the parent epic's plan comment" do
    epic = ClientStub.sample_issue(
      id: "100",
      identifier: "100",
      state: "Epic Tracking",
      assigned_to_worker: false,
      labels: ["symphony:epic-tracking"]
    )

    child134 = ClientStub.sample_issue(id: "134", identifier: "134", state: "Todo", labels: ["symphony:todo"])
    child135 = ClientStub.sample_issue(id: "135", identifier: "135", state: "Todo", labels: ["symphony:todo"])

    plan_body = """
    <!-- symphony-plan:v1 -->
    schema: 1
    sub_issues:
      - id: 134
        blocked_by: []
      - id: 135
        blocked_by: [134]
    <!-- /symphony-plan -->
    """

    ClientStub.set(:fetch_candidate_issues, {:ok, [epic, child134, child135]})
    ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
    ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: plan_body, updated_at: ~U[2026-05-08 12:00:00Z]}]})

    {:ok, issues} = Adapter.fetch_candidate_issues()

    by_id = Map.new(issues, &{&1.id, &1})
    assert by_id["134"].blocked_by == []
    assert [%{state: "Todo"}] = by_id["135"].blocked_by
  end

  test "child whose blocker is Done is unblocked" do
    epic = ClientStub.sample_issue(id: "100", state: "Epic Tracking", assigned_to_worker: false, labels: ["symphony:epic-tracking"])
    child134 = ClientStub.sample_issue(id: "134", state: "Done", labels: ["symphony:done"])
    child135 = ClientStub.sample_issue(id: "135", state: "Todo", labels: ["symphony:todo"])

    plan_body = """
    <!-- symphony-plan:v1 -->
    schema: 1
    sub_issues:
      - id: 134
        blocked_by: []
      - id: 135
        blocked_by: [134]
    <!-- /symphony-plan -->
    """

    ClientStub.set(:fetch_candidate_issues, {:ok, [epic, child134, child135]})
    ClientStub.set(:fetch_sub_issues, {:ok, [134, 135]})
    ClientStub.set(:fetch_issue_comments, {:ok, [%{id: 1, body: plan_body, updated_at: ~U[2026-05-08 12:00:00Z]}]})

    {:ok, issues} = Adapter.fetch_candidate_issues()
    by_id = Map.new(issues, &{&1.id, &1})
    assert [%{state: "Done"}] = by_id["135"].blocked_by
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/github/adapter_test.exs`
Expected: FAIL — `blocked_by` is `[]` because nothing populates it yet.

- [ ] **Step 3: Add the `fetch_plan/1` callback to the Tracker behaviour**

Modify `elixir/lib/symphony_elixir/tracker.ex`:

```elixir
@callback fetch_plan(String.t()) :: {:ok, map() | nil} | {:error, term()}

@optional_callbacks secret_env_var: 0, fetch_sub_issues: 1, fetch_plan: 1

@spec fetch_plan(String.t()) :: {:ok, map() | nil} | {:error, term()}
def fetch_plan(epic_id) do
  with {:ok, mod} <- adapter() do
    if function_exported?(mod, :fetch_plan, 1) do
      mod.fetch_plan(epic_id)
    else
      {:ok, nil}
    end
  end
end
```

- [ ] **Step 4: Implement `fetch_plan/1` in GitHub adapter**

Add to `elixir/lib/symphony_elixir/github/adapter.ex`:

```elixir
@impl true
def fetch_plan(epic_id) when is_binary(epic_id) do
  with {:ok, comments} <- client_module().fetch_issue_comments(epic_id) do
    case SymphonyElixir.GitHub.EpicPlan.extract(comments) do
      {:ok, plan} -> {:ok, plan}
      {:error, :no_plan} -> {:ok, nil}
      {:error, _reason} = err -> err
    end
  end
end
```

- [ ] **Step 5: Implement `fetch_plan/1` in Memory adapter (for tests later)**

Add to `elixir/lib/symphony_elixir/tracker/memory.ex`:

```elixir
def fetch_plan(epic_id) when is_binary(epic_id) do
  plans = Application.get_env(:symphony_elixir, :memory_tracker_plans, %{})
  {:ok, Map.get(plans, epic_id)}
end
```

- [ ] **Step 6: Wire `populate_blocked_by_from_plans/1` into the GitHub adapter using the callback**

Modify `elixir/lib/symphony_elixir/github/adapter.ex`:

```elixir
@impl true
def fetch_candidate_issues do
  with {:ok, raw_issues} <- client_module().fetch_candidate_issues() do
    {:ok, populate_blocked_by_from_plans(raw_issues)}
  end
end

@impl true
def fetch_issues_by_states(states) do
  with {:ok, raw_issues} <- client_module().fetch_issues_by_states(states) do
    {:ok, populate_blocked_by_from_plans(raw_issues)}
  end
end

defp populate_blocked_by_from_plans(issues) do
  state_by_number =
    issues
    |> Enum.into(%{}, fn issue ->
      case Integer.parse(issue.id || "") do
        {n, _} -> {n, issue.state}
        :error -> {nil, issue.state}
      end
    end)
    |> Map.delete(nil)

  epics = Enum.filter(issues, &(&1.state == "Epic Tracking"))

  blockers_by_child =
    epics
    |> Enum.flat_map(fn epic -> blockers_for_epic(epic, state_by_number) end)
    |> Enum.into(%{})

  Enum.map(issues, fn issue ->
    case Map.get(blockers_by_child, issue.id) do
      nil -> issue
      blockers -> %{issue | blocked_by: blockers}
    end
  end)
end

defp blockers_for_epic(epic, state_by_number) do
  case fetch_plan(epic.id) do
    {:ok, %{sub_issues: subs}} ->
      Enum.map(subs, fn sub ->
        blockers = Enum.map(sub.blocked_by, fn n -> %{state: Map.get(state_by_number, n, "Todo")} end)
        {Integer.to_string(sub.id), blockers}
      end)

    _ ->
      []
  end
end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/github/adapter_test.exs test/symphony_elixir/tracker_test.exs`
Expected: all tests pass. The previously failing `blocked_by` tests now succeed because the GitHub adapter looks up plans via `fetch_plan/1`.

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker.ex elixir/lib/symphony_elixir/github/adapter.ex elixir/lib/symphony_elixir/tracker/memory.ex elixir/test/symphony_elixir/github/adapter_test.exs
git commit -m "feat(tracker): fetch_plan callback + GitHub populates blocked_by"
```

---

## Task 10: Workflow loader: parse `prompts.epic_planner` from frontmatter

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow.ex`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/workflow_prompts_test.exs`:

```elixir
defmodule SymphonyElixir.WorkflowPromptsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Workflow

  defp write_workflow!(content) do
    path = Path.join(System.tmp_dir!(), "WORKFLOW-#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    Workflow.set_workflow_file_path(path)
    on_exit_unlink(path)
    path
  end

  defp on_exit_unlink(path) do
    ExUnit.Callbacks.on_exit(fn ->
      _ = File.rm(path)
      Workflow.clear_workflow_file_path()
    end)
  end

  test "loads epic_planner prompt from frontmatter when present" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    prompts:
      epic_planner: |
        Plan the epic.
    ---
    Default prompt body.
    """)

    {:ok, loaded} = Workflow.load()
    assert loaded.prompt_template == "Default prompt body."
    assert loaded.prompts.epic_planner == "Plan the epic.\n"
  end

  test "loaded.prompts is an empty map when frontmatter has no prompts:" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    Default prompt body.
    """)

    {:ok, loaded} = Workflow.load()
    assert loaded.prompts == %{}
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/workflow_prompts_test.exs`
Expected: FAIL — `loaded.prompts` does not exist.

- [ ] **Step 3: Implement**

Modify `elixir/lib/symphony_elixir/workflow.ex`:

Update the `loaded_workflow` type:

```elixir
@type loaded_workflow :: %{
        config: map(),
        prompt: String.t(),
        prompt_template: String.t(),
        prompts: %{atom() => String.t()}
      }
```

Update `parse/1`:

```elixir
defp parse(content) do
  {front_matter_lines, prompt_lines} = split_front_matter(content)

  case front_matter_yaml_to_map(front_matter_lines) do
    {:ok, front_matter} ->
      prompt = Enum.join(prompt_lines, "\n") |> String.trim()

      {:ok,
       %{
         config: front_matter,
         prompt: prompt,
         prompt_template: prompt,
         prompts: extract_named_prompts(front_matter)
       }}

    {:error, :workflow_front_matter_not_a_map} ->
      {:error, :workflow_front_matter_not_a_map}

    {:error, reason} ->
      {:error, {:workflow_parse_error, reason}}
  end
end

defp extract_named_prompts(%{"prompts" => map}) when is_map(map) do
  map
  |> Enum.flat_map(fn
    {key, value} when is_binary(key) and is_binary(value) -> [{String.to_atom(key), value}]
    _ -> []
  end)
  |> Map.new()
end

defp extract_named_prompts(_), do: %{}
```

Also update `WorkflowStore` if it pattern-matches on the loaded shape — verify with: `grep -n "prompt_template\|prompt:" elixir/lib/symphony_elixir/workflow_store.ex`. If it does, add the `prompts:` key to the matched shapes (default `%{}`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/workflow_prompts_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 5: Run the full test suite to catch regressions in workflow_store**

Run: `cd elixir && mix test`
Expected: 0 failures across all suites. If any are failing on `prompts:` key absence, fix the destructuring and re-run.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow.ex elixir/test/symphony_elixir/workflow_prompts_test.exs elixir/lib/symphony_elixir/workflow_store.ex
git commit -m "feat(workflow): load named prompts from frontmatter"
```

---

## Task 11: PromptBuilder variant support

**Files:**
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`

- [ ] **Step 1: Write the failing test**

Create `elixir/test/symphony_elixir/prompt_builder_test.exs`:

```elixir
defmodule SymphonyElixir.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Issue, PromptBuilder, Workflow}

  defp write_workflow!(content) do
    path = Path.join(System.tmp_dir!(), "WORKFLOW-#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    Workflow.set_workflow_file_path(path)
    on_exit(fn ->
      _ = File.rm(path)
      Workflow.clear_workflow_file_path()
    end)
    path
  end

  defp issue, do: %Issue{id: "1", identifier: "1", title: "T", description: "D", labels: [], url: "u"}

  test "default variant renders the body prompt" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    Issue: {{ issue.identifier }}.
    """)

    assert PromptBuilder.build_prompt(issue()) =~ "Issue: 1."
  end

  test "epic_planner variant renders the named prompt and exposes :epic context" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    prompts:
      epic_planner: |
        Plan epic {{ issue.identifier }} with sub-issues: {{ epic.sub_issue_numbers | join: ', ' }}.
    ---
    default body
    """)

    out = PromptBuilder.build_prompt(issue(), variant: :epic_planner, epic: %{sub_issue_numbers: [134, 135]})
    assert out =~ "Plan epic 1 with sub-issues: 134, 135."
  end

  test "epic_planner variant raises a clear error when prompt is missing" do
    write_workflow!("""
    ---
    tracker:
      kind: memory
    ---
    default body only
    """)

    assert_raise RuntimeError, ~r/missing.*epic_planner/, fn ->
      PromptBuilder.build_prompt(issue(), variant: :epic_planner)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/prompt_builder_test.exs`
Expected: FAIL — variant option not recognized.

- [ ] **Step 3: Implement**

Modify `elixir/lib/symphony_elixir/prompt_builder.ex`:

```elixir
@spec build_prompt(SymphonyElixir.Issue.t(), keyword()) :: String.t()
def build_prompt(issue, opts \\ []) do
  variant = Keyword.get(opts, :variant, :default)

  template =
    Workflow.current()
    |> prompt_template_for!(variant)
    |> parse_template!()

  context = %{
    "attempt" => Keyword.get(opts, :attempt),
    "issue" => issue |> Map.from_struct() |> to_solid_map(),
    "epic" => to_solid_value(Keyword.get(opts, :epic, %{}))
  }

  template
  |> Solid.render!(context, @render_opts)
  |> IO.iodata_to_binary()
end

defp prompt_template_for!({:ok, %{prompts: prompts, prompt_template: default}}, :default) do
  default_prompt(default)
end

defp prompt_template_for!({:ok, %{prompts: prompts}}, variant) do
  case Map.get(prompts, variant) do
    nil -> raise RuntimeError, "workflow_missing_prompt: missing prompts.#{variant}"
    template -> template
  end
end

defp prompt_template_for!({:error, reason}, _variant) do
  raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
end
```

Note: replace the old `prompt_template!/1` / `prompt_template!/{:ok, ...}` definitions with the variant-aware ones above.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/prompt_builder_test.exs`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Run the full test suite**

Run: `cd elixir && mix test`
Expected: 0 failures. Existing PromptBuilder callers still pass `[]` opts, which defaults to variant `:default`, so behavior is unchanged.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/prompt_builder.ex elixir/test/symphony_elixir/prompt_builder_test.exs
git commit -m "feat(prompt_builder): :variant option for epic_planner and friends"
```

---

## Task 12: AgentRunner: thread `:variant` and `:max_turns` overrides

The `agent_runner.ex` already supports `:max_turns` via opts (`agent_runner.ex:79`); we add `:variant` pass-through to PromptBuilder.

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: Inspect current code**

Read `agent_runner.ex:132` (`build_turn_prompt/4`):

```elixir
defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)
```

This already forwards opts. The only change needed: ensure `:variant` and `:epic` keys, if passed in by orchestrator, reach `PromptBuilder`. They will, because `opts` is forwarded as-is.

- [ ] **Step 2: Add a smoke test**

Append to `elixir/test/symphony_elixir/prompt_builder_test.exs`:

```elixir
test "AgentRunner-style call with variant and epic forwards correctly" do
  write_workflow!("""
  ---
  tracker:
    kind: memory
  prompts:
    epic_planner: |
      P {{ issue.identifier }} {{ epic.sub_issue_numbers | size }}.
  ---
  default
  """)

  assert "P 1 2." <> _ = PromptBuilder.build_prompt(issue(), variant: :epic_planner, epic: %{sub_issue_numbers: [1, 2]}, attempt: 1)
end
```

- [ ] **Step 3: Run the test**

Run: `cd elixir && mix test test/symphony_elixir/prompt_builder_test.exs`
Expected: 4 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add elixir/test/symphony_elixir/prompt_builder_test.exs
git commit -m "test(agent_runner): smoke-check variant + epic forwarding"
```

---

## Task 13: Orchestrator: detect epic and dispatch planner

This is the most invasive change. The detection happens at dispatch time. We add a function that classifies a candidate as `:regular` or `{:epic, sub_issue_numbers}`. Plan-comment detection (skip planner if plan exists) lives in the GitHub adapter — it's the source of truth via `populate_blocked_by_from_plans/1` (Task 9). So the orchestrator only needs to choose the variant the FIRST time it sees an epic without `Epic Tracking` state.

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

- [ ] **Step 1: Read the current dispatch path**

Run: `grep -n "fetch_candidate_issues\|dispatch\|run_agent\|AgentRunner" elixir/lib/symphony_elixir/orchestrator.ex | head -30`

The orchestrator's polling tick fetches candidates, applies the gate (`candidate_issue?`, `todo_issue_blocked_by_non_terminal?`), and for each survivor calls into the agent runner. The exact dispatch helper is in `orchestrator.ex` around the `available_slots/1` and `do_handle_dispatch` regions; identify it by searching for the call to `AgentRunner.run/...` or to `Task.Supervisor.start_child` that wraps it. **The implementing agent should locate this site and confirm before editing.**

- [ ] **Step 2: Write a failing integration test**

Create `elixir/test/symphony_elixir/orchestrator_epic_test.exs`:

```elixir
defmodule SymphonyElixir.OrchestratorEpicTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Issue, Tracker.Memory}

  setup do
    # Memory tracker setup: epic #100 with two sub-issues, no plan yet.
    epic = %Issue{id: "100", identifier: "100", title: "Epic", state: "Todo", labels: ["symphony:todo"]}
    child_a = %Issue{id: "101", identifier: "101", title: "A", state: "Todo", labels: ["symphony:todo"]}
    child_b = %Issue{id: "102", identifier: "102", title: "B", state: "Todo", labels: ["symphony:todo"]}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child_a, child_b])
    Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"100" => [101, 102]})
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      [:memory_tracker_issues, :memory_tracker_sub_issues, :memory_tracker_recipient]
      |> Enum.each(&Application.delete_env(:symphony_elixir, &1))
    end)

    :ok
  end

  test "orchestrator dispatches planner variant for an epic with no plan yet" do
    # The orchestrator picks epic #100. Because Memory.fetch_sub_issues returns [101, 102],
    # it should classify it as an epic, choose variant :epic_planner, max_turns: 4,
    # and (with a stubbed agent runner) we capture the kwargs.
    SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn agent_runner_pid ->
      :ok = SymphonyElixir.OrchestratorTestHelper.tick()
      assert_receive {:agent_run_invoked, "100", opts}, 5_000
      assert opts[:variant] == :epic_planner
      assert opts[:max_turns] == 4
    end)
  end
end
```

This test depends on a small helper `SymphonyElixir.OrchestratorTestHelper` which:
- replaces `AgentRunner.run/...` with a stub that sends `{:agent_run_invoked, issue_id, opts}` to the test pid.
- exposes `tick/0` to drive one polling cycle synchronously.

The implementing agent must add this helper to `elixir/test/support/test_support.exs` (or create a new file). The exact API of the existing `AgentRunner.run` and how to stub it is determined by reading the current orchestrator dispatch path — the helper wraps that seam.

If a clean stub seam doesn't exist, the implementing agent should add one in this task: e.g., make the orchestrator look up the agent runner module via `Application.get_env(:symphony_elixir, :agent_runner_module, AgentRunner)`. This is the same pattern used for `:github_client_module`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: FAIL — orchestrator doesn't yet branch on epic.

- [ ] **Step 4: Implement the epic detection branch**

In `orchestrator.ex`, locate the dispatch helper (likely named something like `dispatch_issue/...` or `run_agent_for_issue/...` — find it by following calls from the polling-tick path). Replace the body so that:

1. Before calling AgentRunner, check `Tracker.fetch_sub_issues(issue.id)`.
2. If the result is non-empty AND `issue.state != "Epic Tracking"`, dispatch with `variant: :epic_planner, max_turns: 4, epic: %{sub_issue_numbers: numbers}` instead of the default.
3. Otherwise dispatch as today.

Sketch of the new helper:

```elixir
defp build_run_opts(%Issue{} = issue, base_opts) do
  case epic_classification(issue) do
    {:epic, sub_numbers} ->
      Keyword.merge(base_opts,
        variant: :epic_planner,
        max_turns: 4,
        epic: %{sub_issue_numbers: sub_numbers}
      )

    :regular ->
      base_opts
  end
end

defp epic_classification(%Issue{id: id, state: state}) when state != "Epic Tracking" do
  case Tracker.fetch_sub_issues(id) do
    {:ok, [_ | _] = numbers} -> {:epic, numbers}
    _ -> :regular
  end
end

defp epic_classification(_issue), do: :regular
```

Splice `build_run_opts/2` into the call site that currently passes `[]` or similar to the agent runner.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: PASS.

- [ ] **Step 6: Run the full suite**

Run: `cd elixir && mix test`
Expected: 0 failures.

- [ ] **Step 7: Add a failing test for planner failure detection**

Per spec §6.7: when the planner agent run finishes but the epic is NOT in `Epic Tracking` state (i.e., the planner didn't successfully label it), Symphony moves the epic to `Human Review` with an explanatory comment. Without this, a failing planner causes infinite redispatch (because `In Progress` is in `active_states`).

Append to `elixir/test/symphony_elixir/orchestrator_epic_test.exs`:

```elixir
test "epic stays in active state after planner run -> moved to Human Review with diagnostic comment" do
  epic = %Issue{id: "600", identifier: "600", title: "Epic", state: "In Progress", labels: ["symphony:in-progress"]}
  child = %Issue{id: "601", identifier: "601", state: "Todo", labels: ["symphony:todo"]}

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child])
  Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"600" => [601]})
  # No plan was written; no Epic Tracking label was applied. The orchestrator
  # should detect this on the NEXT polling tick (after the planner run notionally
  # completed) and escalate.

  SymphonyElixir.OrchestratorTestHelper.mark_planner_run_completed("600")

  :ok = SymphonyElixir.OrchestratorTestHelper.tick()
  assert_receive {:memory_tracker_state_update, "600", "Human Review"}, 5_000
  assert_receive {:memory_tracker_comment, "600", body}, 5_000
  assert body =~ "planner"
end
```

`mark_planner_run_completed/1` is a test helper that records into the orchestrator's state (or a side-channel) that this epic's planner run already finished — so the next tick should treat it as "should have a plan by now" rather than "first time seeing this epic". The implementing agent decides whether to track this as orchestrator state (a MapSet of epic IDs whose planner has already run this lifetime) or to derive it from labels (if the parent has `symphony:in-progress` and sub-issues but no plan comment, planner must have run).

The latter (derive from state) is preferred — it's idempotent and crash-safe.

- [ ] **Step 8: Implement the failure detection**

In the orchestrator's polling tick, after fetching candidates and before dispatching new runs, add:

```elixir
defp escalate_failed_planner_runs(issues) do
  Enum.each(issues, fn issue ->
    if planner_failed?(issue) do
      Logger.warning("Epic planner failure detected for #{issue_context(issue)}; escalating to Human Review")
      _ = Tracker.create_comment(issue.id, planner_failure_comment(issue))
      _ = Tracker.update_issue_state(issue.id, "Human Review")
    end
  end)
end

defp planner_failed?(%Issue{id: id, state: state}) when state in ["In Progress", "Todo"] do
  case Tracker.fetch_sub_issues(id) do
    {:ok, [_ | _]} ->
      case Tracker.fetch_plan(id) do
        {:ok, nil} -> true                       # no plan comment -> planner failed
        {:error, {:invalid_yaml, _}} -> true     # planner wrote a malformed plan
        {:error, {:missing_field, _}} -> true
        {:error, {:invalid_sub_issue, _}} -> true
        {:error, {:schema_mismatch, _}} -> true
        _ -> false
      end

    _ ->
      false
  end
end

defp planner_failed?(_), do: false

defp planner_failure_comment(_issue) do
  "Symphony's epic planner run did not produce a valid `<!-- symphony-plan:v1 -->` " <>
    "block on this issue. Moving to Human Review for manual triage. " <>
    "To retry: remove the `symphony:human-review` label, re-add `symphony:todo`, " <>
    "and ensure GitHub sub-issues are configured."
end
```

**Important guard against false positives:** `planner_failed?/1` returns `true` only if the planner has actually had a chance to run. A fresh `Todo` epic that hasn't been picked up yet will trip this check on the very first tick because no plan exists yet. Mitigate by:

- Only running `escalate_failed_planner_runs/1` for epics in `In Progress` state (not `Todo`). The `before_run` hook already moves issues from `Todo` to `In Progress` before the agent starts (`WORKFLOW.alpha.md:47-50`), so by the time we see `In Progress`, the planner *has* run at least once.

Adjust the guard:

```elixir
defp planner_failed?(%Issue{id: id, state: "In Progress"}) do
  # ... same body as above
end

defp planner_failed?(_), do: false
```

Wire `escalate_failed_planner_runs/1` into the polling tick **before** the dispatch loop (otherwise the orchestrator dispatches the planner *again* on the same tick).

- [ ] **Step 9: Run the test to verify it passes**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: 2 tests passing (Task 13 step 5's test + this one).

- [ ] **Step 10: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_epic_test.exs elixir/test/support/test_support.exs
git commit -m "feat(orchestrator): escalate failed planner runs to Human Review"
```

---

## Task 14: Orchestrator reaper: close `Epic Tracking` parents when all children Done

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

- [ ] **Step 1: Write the failing test**

Append to `elixir/test/symphony_elixir/orchestrator_epic_test.exs`:

```elixir
test "reaper closes parent when every child is Done" do
  # Override setup with all-Done children
  epic = %Issue{id: "200", identifier: "200", title: "Epic", state: "Epic Tracking", labels: ["symphony:epic-tracking"]}
  done_a = %Issue{id: "201", identifier: "201", title: "A", state: "Done", labels: ["symphony:done"]}
  done_b = %Issue{id: "202", identifier: "202", title: "B", state: "Done", labels: ["symphony:done"]}

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, done_a, done_b])
  Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"200" => [201, 202]})

  :ok = SymphonyElixir.OrchestratorTestHelper.tick()
  assert_receive {:memory_tracker_state_update, "200", "Done"}, 5_000
end

test "reaper does NOT close parent when any child is still active" do
  epic = %Issue{id: "300", identifier: "300", title: "Epic", state: "Epic Tracking"}
  in_progress = %Issue{id: "301", identifier: "301", state: "In Progress"}
  done = %Issue{id: "302", identifier: "302", state: "Done"}

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, in_progress, done])
  Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"300" => [301, 302]})

  :ok = SymphonyElixir.OrchestratorTestHelper.tick()
  refute_receive {:memory_tracker_state_update, "300", _}, 200
end

test "reaper does NOT close parent if a child is in Human Review (PR not merged)" do
  # Human Review is terminal in the workflow but means PR pending review,
  # not merged — closing parent here would be premature.
  epic = %Issue{id: "400", identifier: "400", title: "Epic", state: "Epic Tracking"}
  human_review = %Issue{id: "401", identifier: "401", state: "Human Review"}

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, human_review])
  Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"400" => [401]})

  :ok = SymphonyElixir.OrchestratorTestHelper.tick()
  refute_receive {:memory_tracker_state_update, "400", _}, 200
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: FAIL — reaper doesn't exist.

- [ ] **Step 3: Implement the reaper**

Add to `orchestrator.ex` (called from the polling tick, after the dispatch loop):

```elixir
defp run_epic_reaper(issues) do
  epics = Enum.filter(issues, &(&1.state == "Epic Tracking"))

  Enum.each(epics, fn epic ->
    case Tracker.fetch_sub_issues(epic.id) do
      {:ok, [_ | _] = sub_numbers} ->
        if all_children_done?(sub_numbers, issues) do
          Logger.info("Epic reaper: closing #{issue_context(epic)} (all children Done)")
          _ = Tracker.update_issue_state(epic.id, "Done")
        else
          :ok
        end

      _ ->
        :ok
    end
  end)
end

defp all_children_done?(sub_numbers, issues) do
  by_id = Map.new(issues, &{&1.identifier, &1.state})

  Enum.all?(sub_numbers, fn n ->
    Map.get(by_id, Integer.to_string(n)) == "Done"
  end)
end
```

Wire `run_epic_reaper/1` into the polling tick — it should run **after** the dispatch loop has fetched issues, so we can pass that same list in (no extra fetch).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: 4 tests, 0 failures (1 from Task 13 + 3 from this task).

- [ ] **Step 5: Run the full test suite**

Run: `cd elixir && mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_epic_test.exs
git commit -m "feat(orchestrator): epic reaper closes parent when children Done"
```

---

## Task 15: Update `WORKFLOW.alpha.md` with planner prompt + Epic Tracking active state

`WORKFLOW.alpha.md` is operator config (untracked in git as of this writing — see `git status`). The plan instructs the operator to update it; the actual file edit should happen in their working tree.

**Files:**
- Modify: `WORKFLOW.alpha.md` (root of repo)

- [ ] **Step 1: Add `Epic Tracking` to active_states**

Edit the frontmatter of `WORKFLOW.alpha.md`:

```yaml
tracker:
  kind: github
  repo: AnattaResearch/alpha
  api_key: "${GITHUB_TOKEN}"
  active_states:
    - Todo
    - In Progress
    - Epic Tracking
  terminal_states:
    - Human Review
    - Done
```

- [ ] **Step 2: Add the `prompts.epic_planner` body**

Add to the same frontmatter, before the closing `---`:

```yaml
prompts:
  epic_planner: |
    You are PLANNING (not implementing) AnattaResearch/alpha epic #{{ issue.identifier }}.

    Sub-issues to plan: {{ epic.sub_issue_numbers | join: ', ' }}.

    Steps:
    1. For each sub-issue, run:
         gh issue view <n> --comments --repo AnattaResearch/alpha
       Read it carefully.

    2. Decide the dependency graph between sub-issues using semantic judgment:
       - What defines a contract / schema / interface?
       - What depends on a contract?
       - What can run in parallel?

    3. Comment ONCE on the parent epic with this exact wrapped YAML block.
       Replace the placeholder content; keep the marker comments verbatim:

         gh issue comment {{ issue.identifier }} --repo AnattaResearch/alpha --body-file - <<'PLAN'
         <!-- symphony-plan:v1 -->
         schema: 1
         generated_at: $(date -u +%FT%TZ)
         sub_issues:
           - id: <number>
             blocked_by: [<number>, ...]
             rationale: "<one short sentence>"
         <!-- /symphony-plan -->
         PLAN

    4. For each sub-issue, run:
         gh issue edit <n> --repo AnattaResearch/alpha --add-label symphony:todo

    5. For the parent epic, swap labels:
         gh issue edit {{ issue.identifier }} --repo AnattaResearch/alpha \
           --remove-label symphony:in-progress \
           --add-label symphony:epic-tracking

    6. Stop. Do NOT open a PR. Do NOT modify any code in this run.

    If you can't decide ordering for some sub-issue, set blocked_by: [] and add
    a rationale that explains the uncertainty — do not refuse to write a plan.
```

- [ ] **Step 3: Verify Symphony loads the file**

Run (from repo root):
```bash
cd elixir && mix compile
WORKFLOW=../WORKFLOW.alpha.md mix run -e 'IO.inspect(SymphonyElixir.Workflow.load("../WORKFLOW.alpha.md"))'
```
Expected: `{:ok, %{... prompts: %{epic_planner: "You are PLANNING..."}}}`

- [ ] **Step 4: Commit (only if `WORKFLOW.alpha.md` is tracked in this repo; if not, the operator commits in their config repo)**

If tracked: `git add WORKFLOW.alpha.md && git commit -m "config(workflow): add Epic Tracking + epic_planner prompt"`. Otherwise leave untracked.

---

## Task 16: Update `SPEC.md` with the epic handling section

**Files:**
- Modify: `elixir/SPEC.md` (and/or `SPEC.md` at repo root — confirm where the canonical spec is)

- [ ] **Step 1: Locate the canonical spec**

Run: `grep -l 'blocked_by\|Issue normalization' SPEC.md elixir/SPEC.md 2>/dev/null`. Expected: `SPEC.md` (root). The repo has both `/SPEC.md` and `elixir/SPEC.md` — the canonical is `/SPEC.md` (referenced from `README.md`).

- [ ] **Step 2: Add the new section**

Add before the "Adapters" section (or wherever GitHub-specific behavior is described). The content:

```markdown
## Epic handling (GitHub)

GitHub issues can have structured sub-issues via the native sub-issues API.
Symphony treats issues with non-empty `sub_issues` as epics and processes
them in three phases:

1. **Planner phase.** When a `Todo` issue is detected as an epic and no plan
   comment exists yet, Symphony dispatches an agent run with the
   `epic_planner` prompt variant and `max_turns: 4`. The planner reads each
   sub-issue, comments a YAML dependency plan on the parent (between
   `<!-- symphony-plan:v1 -->` markers), labels each child `symphony:todo`,
   and switches the parent's label to `symphony:epic-tracking`. No code is
   written; no PR is opened.

2. **Execution phase.** On subsequent polling cycles, the GitHub adapter
   parses the parent's plan comment and populates `blocked_by` on each
   child issue. The existing orchestrator dispatch gate
   (`todo_issue_blocked_by_non_terminal?/2`) handles topological ordering
   for free — children whose blockers haven't reached `Done` stay queued.

3. **Reaping.** Each polling tick runs an epic reaper: for any issue in
   state `Epic Tracking`, if every sub-issue is in state `Done`, the parent
   is transitioned to `Done` and closed.

### YAML plan format (v1)

\`\`\`yaml
<!-- symphony-plan:v1 -->
schema: 1
generated_at: 2026-05-08T12:34:56Z
sub_issues:
  - id: 134
    blocked_by: []
    rationale: "Defines DB schema; everything else needs it."
  - id: 135
    blocked_by: [134]
    rationale: "Migration depends on schema."
<!-- /symphony-plan -->
\`\`\`

### State machine

| Entity | State path |
|---|---|
| Parent epic | `Todo` -> (planner runs) -> `Epic Tracking` -> (reaper) -> `Done` |
| Child sub-issue | (no Symphony label) -> (planner labels) -> `Todo` -> `In Progress` -> `Human Review` -> `Done` |

`Epic Tracking` is in `active_states` (so `state_from_labels` decodes it),
but `assigned_to_worker` is set to `false` for issues in this state, which
makes the orchestrator's `issue_routable_to_worker?` gate skip them.
This keeps the parent open in GitHub while children run.

### v1 limitations

- Re-planning when an epic body or sub-issue list mutates is not supported.
  To force a re-plan: delete the parent's plan comment and remove the
  `symphony:epic-tracking` label.
- Nested epics (a sub-issue that is itself an epic) are not recursively
  expanded.
- Children execute serially while `agent.max_concurrent_agents == 1`.
  Bumping this config enables parallel children with no further code
  changes — the dependency graph is honored either way.
```

- [ ] **Step 3: Run the spec compliance check**

Run: `cd elixir && mix specs.check`
Expected: PASS. If it fails, the implementing agent must reconcile.

- [ ] **Step 4: Commit**

```bash
git add SPEC.md
git commit -m "docs(spec): document epic handling for GitHub"
```

---

## Task 17: End-to-end integration test for the full epic flow

**Files:**
- Modify: `elixir/test/symphony_elixir/orchestrator_epic_test.exs`

- [ ] **Step 1: Add an end-to-end test**

```elixir
test "full happy path: planner -> children dispatch in topo order -> reaper closes parent" do
  # Memory tracker: epic with two sub-issues, no plan.
  epic = %Issue{id: "500", identifier: "500", title: "Epic", state: "Todo", labels: ["symphony:todo"]}
  child_a = %Issue{id: "501", identifier: "501", state: "Todo", labels: ["symphony:todo"]}
  child_b = %Issue{id: "502", identifier: "502", state: "Todo", labels: ["symphony:todo"]}

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [epic, child_a, child_b])
  Application.put_env(:symphony_elixir, :memory_tracker_sub_issues, %{"500" => [501, 502]})
  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  # Tick 1: planner dispatch
  SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn _pid ->
    :ok = SymphonyElixir.OrchestratorTestHelper.tick()
    assert_receive {:agent_run_invoked, "500", opts}, 5_000
    assert opts[:variant] == :epic_planner
  end)

  # Simulate planner side effects: epic relabeled to epic-tracking, plan comment written.
  # In Memory tracker that means we update issue state and stash a plan in app env.
  # (See OrchestratorTestHelper.simulate_planner_completion/1.)
  SymphonyElixir.OrchestratorTestHelper.simulate_planner_completion(
    epic_id: "500",
    plan: [%{id: 501, blocked_by: []}, %{id: 502, blocked_by: [501]}]
  )

  # Tick 2: child 501 dispatched (no blockers); 502 blocked.
  SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn _pid ->
    :ok = SymphonyElixir.OrchestratorTestHelper.tick()
    assert_receive {:agent_run_invoked, "501", _opts}, 5_000
    refute_receive {:agent_run_invoked, "502", _}, 200
  end)

  # Simulate 501 done; tick 3 should now dispatch 502.
  SymphonyElixir.OrchestratorTestHelper.set_state("501", "Done")
  SymphonyElixir.OrchestratorTestHelper.with_stubbed_agent_runner(fn _pid ->
    :ok = SymphonyElixir.OrchestratorTestHelper.tick()
    assert_receive {:agent_run_invoked, "502", _opts}, 5_000
  end)

  # Simulate 502 done; tick 4 should reap parent.
  SymphonyElixir.OrchestratorTestHelper.set_state("502", "Done")
  :ok = SymphonyElixir.OrchestratorTestHelper.tick()
  assert_receive {:memory_tracker_state_update, "500", "Done"}, 5_000
end
```

The implementing agent extends `OrchestratorTestHelper` with the helper functions used here:
- `simulate_planner_completion/1` — flips the epic to Epic Tracking + injects a fake `EpicPlan` into Memory tracker (e.g., a side-channel in app env that the GitHub adapter normally reads from comments; for Memory tracker we read from app env directly via a small `Memory.fetch_plan/1` shim).
- `set_state/2` — mutates one issue's state in the configured `memory_tracker_issues` list.

Note: Memory tracker doesn't model the YAML comment lifecycle natively. To keep this test honest, add a tiny `Tracker.Memory.fetch_plan/1` accessor that reads `Application.get_env(:symphony_elixir, :memory_tracker_plans, %{})`, and have the orchestrator **for the Memory adapter only** consult this instead of fetching comments. Document this clearly in the helper as a test-only seam.

Alternatively (cleaner): put the plan-resolution step behind another `Tracker` callback, e.g., `c:fetch_plan/1`. GitHub implements it via comments + EpicPlan. Memory implements it via app env. This way the orchestrator depends only on the abstract callback. **Prefer this design** — it pushes adapter complexity behind the Tracker interface.

- [ ] **Step 2: Use the existing `Tracker.fetch_plan/1` from Task 9**

Task 9 already added the callback to `Tracker`, the GitHub impl, and the Memory impl. This task just exercises them end-to-end via:
- `Application.put_env(:symphony_elixir, :memory_tracker_plans, %{"500" => %{schema: 1, generated_at: nil, sub_issues: [%{id: 501, blocked_by: [], rationale: nil}, %{id: 502, blocked_by: [501], rationale: nil}]}})` inside `OrchestratorTestHelper.simulate_planner_completion/1`.
- `OrchestratorTestHelper.set_state/2` mutates `:memory_tracker_issues` in-place.

No further code changes to `tracker.ex`, `github/adapter.ex`, or `tracker/memory.ex` are required here.

- [ ] **Step 3: Run the integration test**

Run: `cd elixir && mix test test/symphony_elixir/orchestrator_epic_test.exs`
Expected: all tests pass.

- [ ] **Step 4: Run the full suite**

Run: `cd elixir && mix test`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add elixir/test/symphony_elixir/orchestrator_epic_test.exs elixir/test/support/test_support.exs
git commit -m "test(orchestrator): e2e epic flow planner -> children -> reaper"
```

---

## Task 18: Lint and final regression sweep

**Files:** none (verification only)

- [ ] **Step 1: Run credo and dialyzer**

Run: `cd elixir && mix lint`
Expected: 0 issues. (`mix lint` is `specs.check + credo --strict` per `mix.exs:25`.)

- [ ] **Step 2: Run the full test suite once more**

Run: `cd elixir && mix test --max-failures 1`
Expected: 0 failures.

- [ ] **Step 3: Manual smoke test against the live `WORKFLOW.alpha.md`**

If the operator wants to verify before merging, run the orchestrator in dry-mode against `AnattaResearch/alpha`:

```bash
cd elixir
GITHUB_TOKEN=<their token> WORKFLOW=../WORKFLOW.alpha.md mix run -e 'SymphonyElixir.Tracker.fetch_sub_issues("133") |> IO.inspect()'
```
Expected: `{:ok, [<sub-issue numbers>]}` (assuming #133 has sub-issues).

- [ ] **Step 4: No commit needed**

---

## Self-Review Notes

- All spec sections (§1 problem, §6.1–6.8 components, §7 invariants, §8 testing, §9 docs, §10 risks) map to a task. §11 implementation order is followed with one deliberate change: `Tracker.fetch_plan/1` is introduced in Task 9 (not Task 17) so the GitHub adapter is built on the abstract callback from the start.
- `Epic Tracking` state mapping aligns with §6.4 (in `active_states` + `assigned_to_worker: false`), reflecting the spec correction made during plan drafting.
- Spec §6.7 ("Planner failure → move parent to Human Review") is implemented in Task 13 steps 7–10. Without this, `In Progress` epics whose planner failed would be re-dispatched indefinitely (because `In Progress` is in `active_states`).
- All YAML field names (`schema`, `generated_at`, `sub_issues`, `id`, `blocked_by`, `rationale`) are consistent across SPEC.md, EpicPlan code, and the planner prompt.
- v1 limitations from spec §3 are repeated in SPEC.md (Task 16) and the planner prompt assumes single-pass planning (no re-plan instructions).

---

## Open implementation-time questions

These were flagged in spec §12 and should be resolved by the implementing agent during the relevant task:

1. **Where exactly does the orchestrator dispatch helper live?** Task 13 step 1 instructs the agent to find it. If the seam doesn't exist, Task 13 step 4 instructs adding `:agent_runner_module` config.
2. **Does the planner agent share the same workspace clone as a regular run?** Recommendation: yes, for v1 — this avoids special-casing Workspace.run_hook and accepts ~5s of unnecessary clone time per epic. Revisit if planner runs become frequent.
