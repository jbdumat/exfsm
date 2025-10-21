 defmodule RetailOrders do
  def new(order_type \\ "T01", requesting_location \\ "SG01") do
    %Kbrw.FSM.Instance{
      id: generate_id(),
      type: :retail_orders,
      custom: %{
        "order_type" => order_type,
        "requesting_location" => requesting_location
      }
    }
    |> event(:create, %{})
  end

  def generate_id() do
    Enum.random(1..1_000_000)
    |> to_string()
  end

  def event(object, event, params) do
    case ExFSM.V2.Machine.event(object, {event, params}) do
      {:next_state, new_object} ->
        new_object
      other ->
        throw("Got #{inspect other}")
    end
  end

  def case_1(int \\ 1) do
    new()
    |> event(:running_lines_creation, %{})
    |> event(:shipped, int)
  end
end

defimpl ExFSM.V2.Machine.State, for: Kbrw.FSM.Instance do

  def state_name(transaction) do
    transaction[:status][:state]
  end

  def handlers(%{type: RetailOrders.MainFSM}, _) do
    [RetailOrders.MainFSM]
  end

  def handlers(%{type: :retail_orders} = obj, params) do
    RetailOrders.MainFSM.evaluate(obj, params)
  end

  # new set state name
  def set_state_name(%{type: RetailOrders.MainFSM} = transaction, name, handlers) do
    RetailOrders.MainFSM.set_state_name(transaction, name, handlers)
  end

  # original
  def set_state_name(transaction, name, handlers) do
    put_in(transaction, [:status, :state], name)
    |> put_in([:current_fsm], handlers)
  end
end



%Kbrw.FSM.Instance{
      id: "1",
      type: :retail_orders,
      custom: %{
        "order_type" => "T01",
        "requesting_location" => "SG01"
      }
    }
