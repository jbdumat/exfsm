defmodule RetailOrders.Init.SkipSourcing do
  use ExFSM.V2

  deftrans init({:create, %{body: "xxx"}}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "type_label"], "RESA")
    {:next_state, :pending_lines_creation, retail_order}
  end

  deftrans init({:create, _params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "type_label"], "RESA")
    {:next_state, :pending_lines_creation, retail_order}
  end

  deftrans pending_lines_creation({:running_lines_creation, _}, retail_order) do
    {:next_state, :sourced, retail_order}
  end
end
