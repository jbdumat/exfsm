defmodule RetailOrders.MainFSM do
  use MomFSM

  defusefsm init(retail_order, _params) do
    case retail_order[:custom]["order_type"] do
      "T01" ->
        {:use, RetailOrders.Init.SkipSourcing}
      _ ->
        {:use, RetailOrders.Init.Normal}
     end
  end

  defusefsm pending(retail_order, _params) do
    case retail_order[:custom]["requesting_location"] == retail_order["sourcing_location"] do
      true ->
        {:use, RetailOrders.Pending.GoodMovement}
      false ->
        {:use, RetailOrders.Pending.StoCreation}
    end
  end

  defusefsm sourced(_retail_order, params) do
    case params do
      1 ->
        {:use, RetailOrders.Ship.Teleportation}
      2 ->
        {:use, RetailOrders.Ship.Bateau}
      _ ->
        {:use, RetailOrders.Ship.Camion}
    end
  end
end
