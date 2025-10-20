defmodule RetailOrders.Init.Normal do
  use ExFSM

  deftrans init({:create, _params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "type_label"], "CR")
    {:next_state, :pending_lines_creation, retail_order}
  end

  deftrans pending_lines_creation({:running_lines_creation, _}, retail_order) do
    {:next_state, :pending, retail_order}
  end
end
