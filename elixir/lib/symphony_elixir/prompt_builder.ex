defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

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
      "epic" => to_solid_value(Keyword.get(opts, :epic, %{})),
      # PR-stage prompts reference `{{ pr.number }}`, `{{ pr.head_sha }}`,
      # etc. `Stage.dispatch_options/3` injects `:pr` from
      # `WorkItem.pull_request/1` for any stage whose WorkItem carries
      # an attached PR; non-PR stages get an empty map (so accidental
      # `{{ pr.foo }}` references still raise strict_variables errors
      # rather than silently rendering blank).
      "pr" => to_solid_value(Keyword.get(opts, :pr, %{}))
    }

    template
    |> Solid.render!(context, @render_opts)
    |> IO.iodata_to_binary()
  end

  defp prompt_template_for!({:ok, %{prompts: _prompts, prompt_template: default}}, :default) do
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

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
