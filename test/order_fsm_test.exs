defmodule ExFSMRulesDemoTest do
  use ExUnit.Case, async: true

  alias ExFSMRulesDemo.OrderFSM, as: FSM

  defmodule State do
    defstruct state: :init
  end

  # Impl de Machine.State pour le dummy State local (si tu en as déjà une, tu peux supprimer ceci)
  defimpl ExFSM.Machine.State, for: State do
    def handlers(_s, _params \\ %{}), do: [FSM]
    def state_name(s), do: s.state
    def set_state_name(s, name, _possible_handlers \\ []), do: %{s | state: name}
  end

  # ------------ Helpers

  defp state_name(%State{state: st}), do: st

  # ------------ Introspection

  test "introspection: fsm & rules_graph sont peuplés" do
    f = FSM.fsm()
    g = FSM.rules_graph()
    outs = FSM.rules_outputs()

    assert Map.has_key?(f, {:init, :reservation_created})
    assert Map.has_key?(f, {:reserved, :sell})

    assert Map.has_key?(g, {:init, :reservation_created})
    assert Map.has_key?(g, {:reserved, :sell})

    assert Map.has_key?(outs, {:init, :reservation_created})
    assert Map.has_key?(outs, {:reserved, :sell})
  end

  test "available_actions depuis :init inclut reservation_created + bypasses" do
    s = %State{state: :init}
    actions = ExFSM.Machine.available_actions({s, %{}})

    assert :reservation_created in actions
    # Les bypass globaux doivent être accessibles aussi
    assert :cancel_order in actions
    assert :close_order in actions
  end

  # ------------ Reservation (INIT -> RESERVED | REJECTED)

  test "nominal: reservation_created → :reserved" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{id: 1, lines: [%{}]}})
    assert state_name(s1) == :reserved
  end

  test "warning: reservation_created(force_warn) → :reserved (trace warning interne, mais next_state identique)" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{id: 1, lines: [%{}], force_warn: true}})
    assert state_name(s1) == :reserved
  end

  test "rejet: reservation_created → :rejected si params invalides" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{}})
    assert state_name(s1) == :rejected
  end

  # ------------ Sell (RESERVED -> SOLD | RESERVED)

  test "sell OK: reserved → sold" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{id: 1, lines: [%{}]}})
    assert state_name(s1) == :reserved

    assert {:next_state, s2} =
             ExFSM.Machine.event(s1, {:sell, %{payment_ok: true}})
    assert state_name(s2) == :sold
  end

  test "sell KO: reserved reste reserved (payment_failed)" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{id: 1, lines: [%{}]}})
    assert state_name(s1) == :reserved

    assert {:next_state, s2} =
             ExFSM.Machine.event(s1, {:sell, %{payment_ok: false}})
    assert state_name(s2) == :reserved
  end

  # ------------ Bypasses globaux

  test "bypass cancel_order marche depuis n'importe quel état" do
    s0 = %State{state: :init}
    assert {:next_state, s1} =
             ExFSM.Machine.event(s0, {:reservation_created, %{id: 1, lines: [%{}]}})
    assert state_name(s1) == :reserved

    assert {:next_state, s2} = ExFSM.Machine.event(s1, {:cancel_order, %{}})

    assert state_name(s2) == :canceled
  end
end
