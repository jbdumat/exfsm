# defmodule Example.RO.Creation.FSM do
#   @moduledoc """
#   FSM de démonstration avec 4 rules : `:a -> :b -> :c -> :d`.
#   Montre les sorties `:ok`, `:warning`, `:error` et l'usage de `meta.delta`.
#   """
#   use ExFSM

#   deftrans_rules init({:create, _}, ext_state) do
#     @to [:active] # Output status ?

#     defrule create(_params, state) do
#       # Mother transactor already saved the header in DB, this rule is more "symbolic"
#       # in order to unify the entry points names for creation which is a special transactor call
#       next_rule({:running_lines_creation, _params, state}, :ok)
#     end

#     defrule running_lines_creation(_params, state) do
#       # Pseudo code
#       # Lines transactor will save in DB bf executing lines events
#       case call_run_lines_creation(state) do
#         {:ok, _return} ->
#           rules_exit(%{result: :ok}, _params, state, :ok)
#         {:error, _return} ->
#           rules_exit(%{result: :lines_creation_error}, _params, state, :ok)
#         {:prune, _return} ->
#           rules_exit(%{result: :prune}, _params, state, :ok)
#       end
#     end

#     defrules_commit(entry: :create)

#     defrules_exit(_new_params, new_state, proposed) do
#       # This contains the trace of my transitions and it can be very useful for logging/debugging purpose
#       _meta = ExFSM.meta()

#       case proposed do
#         :ok ->
#           {:next_state, :active, new_state}
#         :lines_format_error ->
#           {:next_state, :creation_error, new_state}
#         :lines_creation_error ->
#           {:next_state, :creation_error, new_state}
#         # Idea for indicating to transactor that object must be deleted and transactor terminated
#         :prune ->
#           {:next_state, :__prune_transactor, new_state}
#       end
#     end
#   end
# end
