# ============================== ExFSM Meta ====================================

defmodule ExFSM.Meta do
  @moduledoc false

  @key :exfsm_meta

  @type t :: %{
          initial_state: any,
          initial_params: map(),
          acc: ExFSM.Acc.t(),
          delta: map()
        }

  @spec init(any, map(), ExFSM.Acc.t()) :: :ok
  def init(state0, params0, acc0 \\ %ExFSM.Acc{}) do
    put(%{initial_state: state0, initial_params: params0, acc: acc0, delta: %{}})
  end

  @spec get() :: t
  def get,
    do: Process.get(@key) || %{initial_state: nil, initial_params: %{}, acc: %ExFSM.Acc{}, delta: %{}}

  @spec put(t) :: :ok
  def put(m) when is_map(m), do: Process.put(@key, m) && :ok

  @spec update_acc(ExFSM.Acc.t()) :: :ok
  def update_acc(acc), do: put(%{get() | acc: acc})
end
