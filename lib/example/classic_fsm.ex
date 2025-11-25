# defmodule Example.ClassicFSM do
#   @moduledoc """
#   FSM minimale et purement *classique* (sans RuleEngine).

#   États : :idle → :processing → :done | :failed
#   """

#   use ExFSM

#   # defimpl ExFSM.Machine.State, for: Map do
#   #   def handlers(_state, _params) do
#   #     IO.inspect("Classic FSM")
#   #     [Example.ClassicFSM]
#   #   end
#   #   def state_name(state), do: Map.fetch!(state, :__state__)
#   #   def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
#   # end

#   # ---------------------------------------------------------------
#   # Transition : {:idle, :start}
#   # ---------------------------------------------------------------
#   deftrans idle({:start, params}, state) do
#     IO.puts("Transition :idle/:start - params=#{inspect(params)}")

#     # Ajoute un marqueur dans le state
#     state = Map.put(state, :__state__, :processing)
#     state = Map.put(state, :started_at, System.system_time(:millisecond))

#     # Passer à l’état processing
#     {:next_state, :processing, state}
#   end

#   # ---------------------------------------------------------------
#   # Transition : {:processing, :succeed}
#   # ---------------------------------------------------------------
#   deftrans processing({:succeed, params}, state) do
#     IO.puts("Transition :processing/:succeed")

#     new_state =
#       state
#       |> Map.put(:__state__, :done)
#       |> Map.put(:result, {:ok, params})

#     {:next_state, :done, new_state}
#   end

#   # ---------------------------------------------------------------
#   # Transition : {:processing, :fail}
#   # ---------------------------------------------------------------
#   deftrans processing({:fail, params}, state) do
#     IO.puts("Transition :processing/:fail")

#     new_state =
#       state
#       |> Map.put(:__state__, :failed)
#       |> Map.put(:result, {:error, params})

#     {:next_state, :failed, new_state}
#   end

#   # ---------------------------------------------------------------
#   # Transition : {:done, :reset}
#   # ---------------------------------------------------------------
#   deftrans done({:reset, _params}, state) do
#     IO.puts("Transition :done/:reset")

#     new_state =
#       state
#       |> Map.put(:__state__, :idle)
#       |> Map.delete(:result)
#       |> Map.delete(:started_at)

#     {:next_state, :idle, new_state}
#   end
# end
