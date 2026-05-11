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
