# defmodule Example.SimpleFSM do
#   @moduledoc """
#   FSM de démonstration avec 4 rules : `:a -> :b -> :c -> :d`.
#   Montre les sorties `:ok`, `:warning`, `:error` et l'usage de `meta.delta`.
#   """
#   use ExFSM
#   use ExFSM.Rule.DSL

#   # Implémentation minimale du protocole pour un state sous forme de map
#   # defimpl ExFSM.Machine.State, for: Map do
#   #   def handlers(_state, _params) do
#   #     IO.inspect("SIMPLE FSM")
#   #     [Example.SimpleFSM]
#   #   end
#   #   def state_name(state), do: Map.fetch!(state, :__state__)
#   #   def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
#   # end

#   deftrans_rules init({:go, _}, ext_state) do
#     @to [:done, :warned, :failed]

#     defrule a(params, state) do
#       IO.inspect("Rule :a")
#       state2 = Map.update(state, :seq, [:a], fn s -> [:a | s] end)
#       next_rule({:b, params, state2}, :ok)
#     end

#     defrule b(params, state) do
#       IO.inspect({params, state}, label: "Rule :b")

#       case Map.get(params, :path, :ok_path) do
#         :warn_path ->
#           rules_exit(:warned, params, state, :warning)

#         :error_path ->
#           rules_exit(:failed, params, state, :error)

#         _ ->
#           new_state = Map.update(state, :seq, [:b], fn s -> [:b | s] end)
#           next_rule({:c, params, new_state}, :ok)
#       end
#     end

#     defrule c(params, state) do
#       IO.inspect("Rule :c")
#       new_state = Map.update(state, :seq, [:c], fn s -> [:c | s] end)
#       next_rule({:d, params, new_state}, :ok)
#     end

#     defrule d(params, state) do
#       IO.inspect("Rule :d")
#       rules_exit(:done, params, Map.update(state, :seq, [:d], fn s -> [:d | s] end), :ok)
#     end

#     defrules_commit(entry: :a)

#     defrules_exit(_new_params, new_state_flow, proposed) do
#       m = ExFSM.meta()
#       IO.inspect("Rule :exit")

#       case m.acc.exit do
#         {:ok, :done} -> {:next_state, proposed, new_state_flow}
#         {:warning, :warned} -> {:keep_state, m.initial_state.__state__, m.initial_state}
#         {:error, :failed} -> {:keep_state, m.initial_state.__state__, m.initial_state}
#         other -> {:error, {:unexpected_exit, other}}
#       end
#     end
#   end
# end
