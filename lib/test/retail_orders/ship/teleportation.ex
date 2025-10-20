defmodule RetailOrders.Ship.Teleportation do
  use ExFSM

  deftrans sourced({:shipped, _params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "ship"], "WOOOOOOW")
    {:next_state, :in_store, retail_order}
  end
end
