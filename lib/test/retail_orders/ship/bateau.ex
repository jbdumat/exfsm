defmodule RetailOrders.Ship.Bateau do
  use ExFSM.V2

  deftrans sourced({:shipped, _params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "ship"], "by_bateau")
    {:next_state, :wait_for_bateau_update, retail_order}
  end

  deftrans sourced({:shipped2, nil}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "ship"], "by_bateau")
    {:next_state, :wait_for_bateau_update, retail_order}
  end

  deftrans wait_for_bateau_update({:bateau_update, params}, retail_order) do
    case params["is_arrived"] do
      true ->
        {:next_state, :in_store, retail_order}
      false ->
        retail_order = update_in(retail_order, [:custom, Access.key("bateau_updates", [])], & ["a timestamp", &1])
        {:next_state, :wait_for_bateau_update, retail_order}
    end
  end
end
