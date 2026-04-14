# ============================== ExFSM Meta ====================================

defmodule ExFSM.Meta do
  @moduledoc """
  Process-dictionary store for per-transition FSM metadata.

  Holds the initial state/params, the running `ExFSM.Acc`, and a free-form
  `delta` map for user-defined side-channel data — for the duration of a single
  `RuleEngine.run/5` or `RuleEngine.replay/6` call.

  **Reset guarantee**: `init/3` is called at the start of every `RuleEngine.run`
  and `RuleEngine.replay`, unconditionally resetting all fields (including `delta`).
  Meta from a previous transition is never visible inside the next one.

  **Transactor assumption**: this module is safe only when each FSM execution runs
  within a single, dedicated process (e.g., wrapped in a short-lived GenServer /
  transactor). Do not call `Machine.event/3` recursively from within a running
  transition on the same process — the inner call would reset meta and corrupt
  the outer call's context.

  Use `ExFSM.meta_put/2` to write custom fields to `delta`. The final `delta`
  is surfaced in `opts[:meta]` returned by `Machine.event/3`.
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
    do:
      Process.get(@key) ||
        %{initial_state: nil, initial_params: %{}, acc: %ExFSM.Acc{}, delta: %{}}

  @spec put(t) :: :ok
  def put(m) when is_map(m) do
    Process.put(@key, m)
    :ok
  end

  @spec update_acc(ExFSM.Acc.t()) :: :ok
  def update_acc(acc), do: put(%{get() | acc: acc})
end
