defmodule RetailOrders.Pending.GoodMovement do
  use ExFSM

  deftrans pending({:sourcing, params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "sourcing_params"], params)
    {:next_state, :sourced, retail_order}
  end
end
