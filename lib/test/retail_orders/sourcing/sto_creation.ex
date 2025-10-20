defmodule RetailOrders.Pending.StoCreation do
  use ExFSM

  deftrans pending({:sourcing, params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "sourcing_params"], params)
    {:next_state, :pending_response_from_sto, retail_order}
  end

  deftrans pending_response_from_sto({:sto_response, _}, retail_order) do
    {:next_state, :sourced, retail_order}
  end
end
