# defmodule Example.StoreOrderFSMTest do
#   use ExUnit.Case, async: true
#   alias Example.StoreOrderFSM

#   @state0 %{__state__: :init}

#   test "graph functions exist" do
#     assert function_exported?(StoreOrderFSM, :__rules_entry__, 1)
#     assert function_exported?(StoreOrderFSM, :__rules_exit__, 2)
#   end

#   test "happy path in_store -> sold" do
#     params = %{
#       sku: "SKU1",
#       qty: 2,
#       availability: :in_store,
#       client: %{wants_appointment: true},
#       payment_ok: true
#     }

#     {:next_state, :sold, state1, acc} =
#       ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :full)

#     assert acc.exit == {:ok, :sold}
#     assert state1[:sku] == "SKU1"
#     assert state1[:qty] == 2
#     assert state1[:sourcing] == :store
#     assert state1[:reserved] == true
#     assert Map.has_key?(state1, :pickup_at)
#     assert Map.has_key?(state1, :sold_at)
#   end

#   test "transfer needed -> creates transfer and warns on reserve -> sold" do
#     params = %{
#       sku: "SKU2",
#       qty: 1,
#       availability: :transfer_needed,
#       client: %{wants_appointment: false},
#       payment_ok: true
#     }

#     {:next_state, :sold, state1, acc} =
#       ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :full)

#     assert acc.exit == {:ok, :sold}
#     assert state1[:sourcing] == :transfer
#     assert Map.has_key?(state1, :transfer_id)
#     assert state1[:reserved] == false
#   end

#   test "invalid order -> rejected" do
#     params = %{sku: nil, qty: 0}

#     {:next_state, :rejected, _state1, acc} =
#       ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :full)

#     assert acc.exit == {:error, :rejected}
#   end

#   test "steps_only produces acc and keeps state" do
#     params = %{
#       sku: "X",
#       qty: 1,
#       availability: :in_main,
#       client: %{wants_appointment: false},
#       payment_ok: true
#     }

#     {:steps_done, p2, tmp2, s0, acc} =
#       ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :steps_only)

#     assert s0 == @state0
#     assert acc.exit == {:ok, :sold}
#     assert is_map(p2)
#   end

#   test "replay with completed acc calls defrules_exit/2 and returns sold" do
#     params = %{
#       sku: "R",
#       qty: 1,
#       availability: :in_store,
#       client: %{wants_appointment: true},
#       payment_ok: true
#     }

#     {:steps_done, _p2, _t2, _s, acc} =
#       ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :steps_only)

#     {:next_state, :sold, state1, acc2} =
#       ExFSM.RuleEngine.replay(StoreOrderFSM, {:init, :create}, params, @state0, acc, mode: :full)

#     assert acc2.exit == {:ok, :sold}
#     assert Map.has_key?(state1, :sold_at)
#   end

#   test "replay error path with bogus acc.exit leads to {:error, ...}" do
#     bogus = %ExFSM.Acc{params: %{}, tmp: %{}, steps: [], exit: {:ok, :not_a_state}}

#     {:error, _reason, _acc} =
#       ExFSM.RuleEngine.replay(StoreOrderFSM, {:init, :create}, %{}, @state0, bogus, mode: :full)
#   end

#   test "remaining_rules helper if available" do
#     if function_exported?(StoreOrderFSM, :__remaining_rules__, 3) do
#       params = %{sku: "S", qty: 1, availability: :in_store}

#       {:steps_done, _p2, _t2, _s, acc} =
#         ExFSM.RuleEngine.run(StoreOrderFSM, {:init, :create}, params, @state0, mode: :steps_only)

#       applied = Enum.map(Enum.reverse(acc.steps), & &1.rule)
#       remaining = apply(StoreOrderFSM, :__remaining_rules__, [{:init, :create}, applied, acc])
#       assert is_list(remaining)
#     else
#       assert true
#     end
#   end
# end
