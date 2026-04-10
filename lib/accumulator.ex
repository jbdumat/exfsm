# ============================== ExFSM Accumulator ====================================

defmodule ExFSM.Acc do
  defstruct steps: [], exit: nil, params: %{}, state: nil
  @type t :: %__MODULE__{steps: list, exit: nil | {atom, term}, params: map, state: any}
end
