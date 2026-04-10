defmodule ExFSM.AccJSON do
  @moduledoc """
  Encodes one or more `%ExFSM.Acc{}` into a JSON-safe format
  for ExFSM visualization.

  Assumption: each acc already contains a `:transition` or `"transition"` field
  of the form `{:state, :event}` or `["state", "event"]`.
  """

  @type acc :: %ExFSM.Acc{} | map()

  @doc """
  Encodes a single acc into a JSON-safe map.

  Typical result:

      %{
        "steps"      => [...],
        "state"      => %{...},
        "params"     => %{...},
        "exit"       => ["ok", %{...}],
        "transition" => ["init","go"]
      }
  """
  @spec encode(acc) :: map()
  def encode(%ExFSM.Acc{} = acc) do
    base = %{
      "steps" => Enum.map(acc.steps, &encode_step/1),
      "state" => encode_value(acc.state),
      "params" => encode_value(acc.params),
      "exit" => encode_exit(acc.exit)
    }

    case extract_transition(acc) do
      nil -> base
      transition -> Map.put(base, "transition", transition)
    end
  end

  # Also encodes a "raw" acc that is already a plain map
  def encode(%{} = acc_map) do
    base = %{
      "steps" => acc_map |> Map.get(:steps) |> encode_steps(),
      "state" => acc_map |> Map.get(:state) |> encode_value(),
      "params" => acc_map |> Map.get(:params) |> encode_value(),
      "exit" => acc_map |> Map.get(:exit) |> encode_exit()
    }

    case extract_transition(acc_map) do
      nil -> base
      transition -> Map.put(base, "transition", transition)
    end
  end

  def encode(other) do
    raise ArgumentError,
          "ExFSM.AccJSON.encode/1 expects %ExFSM.Acc{} or a map, got: #{inspect(other)}"
  end

  @doc """
  Encodes a list of successive accs.

  Input: `[acc1, acc2, acc3, ...]`

  Output (JSON-safe):

      [
        %{...encoded acc1...},
        %{...encoded acc2...},
        ...
      ]

  List order matches the order of transitions.
  """
  @spec encode_chain([acc]) :: [map()]
  def encode_chain(accs) when is_list(accs) do
    Enum.map(accs, &encode/1)
  end

  # ------------------------------------------------------------------
  # Internal helpers
  # ------------------------------------------------------------------

  ## steps

  defp encode_steps(nil), do: []
  defp encode_steps(steps) when is_list(steps), do: Enum.map(steps, &encode_step/1)

  defp encode_step(step) when is_map(step) do
    step
    |> Enum.map(fn {k, v} -> {to_string(k), encode_value(v)} end)
    |> Map.new()
  end

  ## exit

  defp encode_exit({tag, val}), do: [Atom.to_string(tag), encode_value(val)]
  defp encode_exit(nil), do: nil
  defp encode_exit(other), do: other

  ## transition

  # Supports :transition or "transition" key in the acc
  defp extract_transition(acc) do
    t = Map.get(acc, :transition) || Map.get(acc, "transition")

    case t do
      nil -> nil
      {s, e} -> [encode_atom(s), encode_atom(e)]
      [s, e] -> [encode_atom(s), encode_atom(e)]
      [s, e | _] -> [encode_atom(s), encode_atom(e)]
      other -> raise ArgumentError, "invalid transition: #{inspect(other)}"
    end
  end

  ## Generic value encoding

  defp encode_value(v) when is_atom(v), do: encode_atom(v)

  defp encode_value(v) when is_map(v) do
    v
    |> Enum.map(fn {k, vv} -> {encode_atom(k), encode_value(vv)} end)
    |> Map.new()
  end

  defp encode_value(v) when is_list(v), do: Enum.map(v, &encode_value/1)
  defp encode_value(v), do: v

  defp encode_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp encode_atom(a), do: a
end
