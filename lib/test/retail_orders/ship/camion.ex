defmodule RetailOrders.Ship.Camion do
  use ExFSM

  deftrans sourced({:shipped, params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "id_camion"], params)
    {:next_state, :on_the_road, retail_order}
  end

  deftrans on_the_road({:new_camion, params}, retail_order) do
    retail_order = put_in(retail_order, [:custom, "id_camion"], params)
    {:next_state, :on_the_road, retail_order}
  end

  deftrans on_the_road({:camion_crash, _params}, retail_order) do
    {:next_state, :error, retail_order}
  end

  deftrans on_the_road({:arrived, _params}, retail_order) do
    {:next_state, :in_store, retail_order}
  end
end
