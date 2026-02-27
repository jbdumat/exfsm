# defmodule Example.ROLines.FSM do
#   @moduledoc """
#   FSM de démonstration avec 4 rules : `:a -> :b -> :c -> :d`.
#   Montre les sorties `:ok`, `:warning`, `:error` et l'usage de `meta.delta`.
#   """
#   use ExFSM


#   # Resa T02
#   # init -create-> product_assignation -running_stock_mvmt-> customer_picking -sell-> sold
#   # init -create-> product_assignation -running_stock_mvmt-> customer_picking -cancelled-> cancelled
#   # init -create-> product_assignation -running_stock_mvmt-> customer_picking -cancelled-> cancelled_stock_mvt_failed -replay-> cancelled

#   # init -create-> product_assignation -running_stock_mvmt-> stock_mvmt_failed -{loop}-> customer_picking -sell-> sold
#   # init -create-> product_assignation -running_stock_mvmt-> stock_mvmt_failed -{loop}-> customer_picking -cancel-> cancelled


#   # # # #
#   # SOLUTION Resa
#   # init -create-> customer_picking
#   # ==> On fait le GM dans le create de la ligne car on a crée la ligne dans Riak dans le transactor
#   #
#   # SOLUTION CR
#   # init -create-> new
#   # ==> On check si une sourcing option a été proposée, si non on passe en new
#   #
#   # init -create-> pending
#   # ==> On check si une sourcing option a été proposée, si oui on passe en pending et on créé une STO si cette sourcing n'est pas du MAIN (optionnel car SALC on passe en pending sans rien faire)
#   # # # #

#   # CR T01
#   #
#   # init -create-> product_assignation -assigned-> Flow Resa (depuis customer picking) ==> On a assigné du MAIN a la CR a la création

#   ## Manual
#   # init -create-> product_assignation -no_auto_sourcing-> new -atp_sourcing-> pending -> Flow Resa (depuis Pending)
#   # init -create-> product_assignation -no_auto_sourcing-> new -cancelled-> cancelled
#   # init -create-> product_assignation -no_auto_sourcing-> new -cancelled-> cancelled_stock_mvt_failed -replay-> cancelled
#   # init -create-> product_assignation -no_auto_sourcing-> new -assigned-> Flow Resa (depuis customer picking) ==> On a assigné du MAIN a la CR post creation
#   # init -create-> product_assignation -no_auto_sourcing-> new -assigned-> assigned_stock_mvt_failed -replay-> Flow Resa (depuis customer picking)

#   ## Auto or manual
#   # init -create-> product_assignation -atp_sourcing-> pending -cancelled-> cancelled
#   # init -create-> product_assignation -atp_sourcing-> pending -assigned-> customer_picking -> Workflow RESA

#   # EResa T05
#   # TBD

#   # SALC
#   # init -create-> pending (on skip le product assignation) -> Flow Resa (depuis pending)
#   ## Potentiellement devoir gérer le cas du LDC avec création de STO.

#   # Kbc Wish T03
#   # TBD

#   # MOTO T06
#   # TBD

#   deftrans_rules init({:create, _}, ext_state) do
#     @to [:active] # Output status ?

#     defrule create(_params, state) do
#       next_rule({:format_lines, _params, state}, :ok)
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
