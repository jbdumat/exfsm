# ============================== ExFSM Meta ====================================

defmodule ExFSM.Meta do
  @moduledoc """
  Process-dictionary store for per-execution FSM metadata.

  Holds the initial state/params and the running `ExFSM.Acc` for the duration
  of a single `RuleEngine.run/5` or `RuleEngine.replay/6` call.

  **Threading model assumption**: this module is safe only when each FSM
  execution runs within a single, dedicated process (e.g., wrapped in a
  short-lived GenServer / transactor). Concurrent calls sharing a process
  would corrupt the stored metadata.
  """

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
  def put(m) when is_map(m) do
    Process.put(@key, m)
    :ok
  end

  @spec update_acc(ExFSM.Acc.t()) :: :ok
  def update_acc(acc), do: put(%{get() | acc: acc})
end
