defmodule Kbrw.FSM.Instance do

  @type t :: %Kbrw.FSM.Instance{
    id: id(),
    custom: any(),
    type: atom(),
    status: %{
      state: atom(),
      error_log: list(error_log()),
      action_log: list(action_log()),
      error: nil | any(),
    }
  }

  @typedoc """
  Depends on the backend implementation
  """
  @type id :: any()

  @type error_log() :: map() #TODO
  @type action_log() :: map() #TODO

  @behaviour Access
  defstruct id: nil, custom: %{}, type: nil, status: %{state: :init, error_log: [], action_log: [], error: nil}

  def fetch(obj, key) do
    Map.fetch(obj, key)
  end

  def get_and_update(data, key, function) do
    Map.get_and_update(data, key, function)
  end

  def pop(data, key) do
    Map.pop(data, key)
  end
end
