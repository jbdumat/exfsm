# defmodule Example.StoreOrderFSM do
#   @moduledoc """
#   Cycle de vie simplifié d'une commande en store-picking.

#   Etapes (rules) typiques :
#   - validate_order
#   - source_inventory (-> create_transfer_request optionnel)
#   - reserve_store_stock
#   - schedule_pickup (optionnel selon préférences client)
#   - sell_order

#   Etats finaux proposés via payload d'`rules_exit` : :rejected | :sourced | :reserved | :scheduled | :sold
#   """
#   use ExFSM

#   # State = map
#   defimpl ExFSM.Machine.State, for: Example.StoreOrderFSM.State do
#     def handlers(_state, _params), do: [Example.StoreOrderFSM]
#     def state_name(state), do: Map.fetch!(state, :__state__)
#     def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
#   end

#   # Event principal : :create depuis :init
#   deftrans_rules init({:create, _}, state) do
#     @to [:rejected, :sourced, :reserved, :scheduled, :sold]

#     defrule validate_order(params, tmp) do
#       with sku when is_binary(sku) <- Map.get(params, :sku),
#            qty when is_integer(qty) and qty > 0 <- Map.get(params, :qty) do
#         ExFSM.merge_delta(%{sku: sku, qty: qty})
#         next_rule({:source_inventory, params, tmp}, :ok)
#       else
#         _ -> rules_exit(:rejected, :error)
#       end
#     end

#     defrule source_inventory(params, tmp) do
#       case Map.get(params, :availability, :in_store) do
#         :in_store ->
#           tmp2 = Map.put(tmp, :sourcing, :store)
#           ExFSM.merge_delta(%{sourcing: :store})
#           next_rule({:reserve_store_stock, params, tmp2}, :ok)
#         :in_main ->
#           tmp2 = Map.put(tmp, :sourcing, :main)
#           ExFSM.merge_delta(%{sourcing: :main})
#           next_rule({:reserve_store_stock, params, tmp2}, :warning) # avertissement: sourcing central
#         :transfer_needed ->
#           tmp2 = Map.put(tmp, :sourcing, :transfer)
#           ExFSM.merge_delta(%{sourcing: :transfer})
#           next_rule({:create_transfer_request, params, tmp2}, :ok)
#       end
#     end

#     defrule create_transfer_request(params, tmp) do
#       # Simulation d'une demande de transfert
#       transfer_id = System.unique_integer([:monotonic])
#       tmp2 = Map.put(tmp, :transfer_id, transfer_id)
#       ExFSM.merge_delta(%{transfer_id: transfer_id})
#       next_rule({:reserve_store_stock, params, tmp2}, :ok)
#     end

#     defrule reserve_store_stock(params, tmp) do
#       # Simule la réservation locale; si sourcing != :store, on considère une résa différée
#       case Map.get(tmp, :sourcing) do
#         :store ->
#           ExFSM.merge_delta(%{reserved: true})
#           next_rule({:schedule_pickup, params, tmp}, :ok)
#         other ->
#           # on peut quand même planifier un pickup, mais on garde un tag warning
#           ExFSM.merge_delta(%{reserved: false})
#           next_rule({:schedule_pickup, params, tmp}, :warning)
#       end
#     end

#     defrule schedule_pickup(params, tmp) do
#       case get_in(params, [:client, :wants_appointment]) do
#         true ->
#           # rdv J+2 10:00 fictif
#           ts = DateTime.utc_now() |> DateTime.add(2 * 24 * 3600, :second)
#           ExFSM.merge_delta(%{pickup_at: ts})
#           next_rule({:sell_order, params, tmp}, :ok)
#         _ ->
#           # pas de rdv; on passe quand même
#           next_rule({:sell_order, params, tmp}, :warning)
#       end
#     end

#     defrule sell_order(params, tmp) do
#       payment_ok = Map.get(params, :payment_ok, true)
#       if payment_ok do
#         ExFSM.merge_delta(%{sold_at: System.system_time(:millisecond)})
#         rules_exit(:sold, :ok)
#       else
#         rules_exit(:rejected, :error)
#       end
#     end

#     defrules_commit(entry: :validate_order)

#     defrules_exit(new_params, new_state) do
#       m = ExFSM.meta()
#       case m.acc.exit do
#         {:ok, :sold} ->
#           {:next_state, :sold, Map.merge(m.initial_state, m.delta)}
#         {:error, :rejected} ->
#           {:next_state, :rejected, Map.merge(m.initial_state, m.delta)}
#         # Cas intermédiaires si on veut sortir plus tôt (ex.: :reserved):
#         {:warning, :reserved} ->
#           {:next_state, :reserved, Map.merge(m.initial_state, m.delta)}
#         other ->
#           {:error, {:unexpected_exit, other}}
#       end
#     end
#   end
# end
