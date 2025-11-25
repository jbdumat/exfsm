defmodule ExFSM.AccJSON do
  @moduledoc """
  Encodage d'un ou plusieurs %ExFSM.Acc{} vers un format JSON-safe
  pour la visualisation ExFSM.

  Hypothèse:
    - chaque acc contient déjà un champ :transition ou "transition"
      de la forme {:state, :event} ou ["state","event"].
  """

  @type acc :: %ExFSM.Acc{} | map()

  @doc """
  Encode un acc unique en map JSON-safe.

  Résultat typique:

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
      "steps"      => Enum.map(acc.steps, &encode_step/1),
      "state"      => encode_value(acc.state),
      "params"     => encode_value(acc.params),
      "exit"       => encode_exit(acc.exit)
    }

    case extract_transition(acc) do
      nil        -> base
      transition -> Map.put(base, "transition", transition)
    end
  end

  # Si jamais tu veux aussi encoder un acc "raw" déjà mapifié
  def encode(%{} = acc_map) do
    base = %{
      "steps"      => acc_map |> Map.get(:steps)  |> or_string("steps")  |> encode_steps(),
      "state"      => acc_map |> Map.get(:state)  |> or_string("state")  |> encode_value(),
      "params"     => acc_map |> Map.get(:params) |> or_string("params") |> encode_value(),
      "exit"       => acc_map |> Map.get(:exit)   |> or_string("exit")   |> encode_exit()
    }

    case extract_transition(acc_map) do
      nil        -> base
      transition -> Map.put(base, "transition", transition)
    end
  end

  @doc """
  Encode une liste d'accs successifs.

  Entrée:
      [acc1, acc2, acc3, ...]

  Sortie JSON (via Poison.encode!/1):

      [
        %{...encoded acc1...},
        %{...encoded acc2...},
        ...
      ]

  L'ordre dans la liste est l'ordre des transitions.
  """
  @spec encode_chain([acc]) :: [map()]
  def encode_chain(accs) when is_list(accs) do
    Enum.map(accs, &encode/1)
  end

  # ------------------------------------------------------------------
  # helpers internes
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
  defp encode_exit(nil),        do: nil
  defp encode_exit(other),      do: other

  ## transition

  # supporte :transition ou "transition" dans l'acc
  defp extract_transition(acc) do
    t = Map.get(acc, :transition) || Map.get(acc, "transition")

    case t do
      nil           -> nil
      {s, e}        -> [encode_atom(s), encode_atom(e)]
      [s, e]        -> [encode_atom(s), encode_atom(e)]
      [s, e | _]    -> [encode_atom(s), encode_atom(e)]
      other         -> raise ArgumentError, "invalid transition: #{inspect(other)}"
    end
  end

  ## generic value

  defp encode_value(v) when is_atom(v),  do: encode_atom(v)

  defp encode_value(v) when is_map(v) do
    v
    |> Enum.map(fn {k, vv} -> {encode_atom(k), encode_value(vv)} end)
    |> Map.new()
  end

  defp encode_value(v) when is_list(v),  do: Enum.map(v, &encode_value/1)
  defp encode_value(v),                  do: v

  defp encode_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp encode_atom(a),                 do: a

  # petit helper pratique pour fallback sur clé string
  defp or_string(nil, _k), do: nil
  defp or_string(value, _k), do: value
end
