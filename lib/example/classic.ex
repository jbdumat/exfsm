defmodule Example.ClassicFSM do
  @moduledoc """
  FSM de démonstration avec 4 rules : `:a -> :b -> :c -> :d`.
  Montre les sorties `:ok`, `:warning`, `:error` et l'usage de `meta.delta`.
  """
  use ExFSM

  # Implémentation minimale du protocole pour un state sous forme de map
  # defimpl ExFSM.Machine.State, for: Map do
  #   def handlers(_state, _params) do
  #     IO.inspect("CLASSIC FSM")
  #     [Example.ClassicFSM]
  #   end
  #   def state_name(state), do: Map.fetch!(state, :__state__)
  #   def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
  # end

  deftrans init({:classic, %{toto: _toto}}, state) do
    {:next_state, :next, state}
  end
end
