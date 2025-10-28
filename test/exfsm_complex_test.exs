defmodule ExFSMRulesDemoTest do
  use ExUnit.Case, async: true

  alias ExFSMRulesReplayDemo.{FSM, State}

  @key {:init, :go}

  test "rules_graph et fsm sont bien peuplés" do
    g = FSM.rules_graph()
    assert Map.has_key?(g, @key)
    assert g[@key].entry == :a
    assert Map.keys(g[@key].graph) |> MapSet.new() == MapSet.new([:a, :b, :c, :d])

    # fsm est déclaré et pointe sur [:done, :failed] (fallback via @to)
    assert FSM.fsm()[@key] == {FSM, [:done, :failed]}
  end

  test "remaining_rules respecte la branche choisie (a -> c -> d)" do
    s = %State{state: :init}
    p = %{take_c: true}

    # on exécute en mode steps_only pour récupérer l'acc sans appeler defrules_exit
    {:steps_done, params, state, acc} = ExFSM.RuleEngine.run(FSM, @key, p, s, mode: :steps_only)

    # dernier step exécuté : c, avec chosen :d
    last = List.last(acc.rules_applied)
    assert last.rule in [:b, :c]
    assert last.rule == :c
    assert last.tag  == :warn
    assert last.chosen == :d

    # remaining doit partir de 'd' uniquement
    remaining = ExFSM.RuleEngine.remaining_rules(s, @key, acc.rules_applied)
    assert remaining == [:d]
  end

  test "replay ne rejoue que le restant et termine via defrules_exit/3" do
    alias ExFSMRulesReplayDemo.{FSM, State}
    s0 = %State{state: :init}
    p  = %{take_c: true}

    # add acc car replay doit le prendre en compte
    {:steps_done, params, state, acc} = ExFSM.RuleEngine.run(FSM, @key, p, s0, mode: :steps_only)

    # On rejoue en full, le moteur doit exécuter 'd' et appliquer defrules_exit → :done
    {:next_state, s1} =
      ExFSM.RuleEngine.replay(s0, @key, %{}, acc, :full)

    assert s1.state == :done
  end

  test "branche nominale (a -> b -> d) : remaining après b == [:d]" do
    s = %State{state: :init}
    p = %{take_c: false}

    {:steps_done, params, state, acc} = ExFSM.RuleEngine.run(FSM, @key, p, s, mode: :steps_only)

    # dernier step : b, chosen :d
    last = List.last(acc.rules_applied)
    assert last.rule == :b
    assert last.tag  == :ok
    assert last.chosen == :d

    assert ExFSM.RuleEngine.remaining_rules(s, @key, acc.rules_applied) == [:d]
  end

  test "event() full path: a -> b -> d → :done" do
    s0 = %State{state: :init}
    {:next_state, s1} = ExFSM.Machine.event(s0, {:go, %{take_c: false}})
    assert s1.state == :done
  end

  test "bypass ne perturbe pas : available_actions inclut :go et :cancel" do
    s = %State{state: :init}
    actions = ExFSM.Machine.available_actions({s, %{}})
    assert :go in actions
    assert :cancel in actions
  end

  test "rules_graph contient les 2 transitions" do
    g = Rules.OrderFSM.Complex.rules_graph()
    assert Map.has_key?(g, {:init, :reservation_created})
    assert Map.has_key?(g, {:reserved, :sell})
    # structure minimale
    assert %{entry: :validate, graph: _, weights: _} = g[{:init, :reservation_created}]
    assert %{entry: :charge,   graph: _, weights: _} = g[{:reserved, :sell}]
  end

  test "nominal: reservation_created → :reserved" do
    s  = %RulesTest.Complex.State{state: :init}
    p0 = %{id: 1, lines: [%{}]}
    assert {:next_state, s2} = ExFSM.Machine.event(s, {:reservation_created, p0})
    assert s2.state == :reserved
  end

  test "rejet: params invalides → :rejected" do
    s  = %RulesTest.Complex.State{state: :init}
    p0 = %{} # manque id/lines
    assert {:next_state, s2} = ExFSM.Machine.event(s, {:reservation_created, p0})
    assert s2.state == :init
  end

  test "warn: reservation_created (force_warn) → :reserved avec tag warn" do
    s  = %RulesTest.Complex.State{state: :init}
    p0 = %{id: 1, lines: [%{}], force_warn: true}

    # on passe par RuleEngine en steps_only pour récupérer l’acc
    {:steps_done, _p_out, state, acc} =
      ExFSM.RuleEngine.run(Rules.OrderFSM.Complex, {:init, :reservation_created}, p0, s, mode: :steps_only)

    # on doit voir un tag warn à la rule :reserve
    assert Enum.any?(acc.rules_applied, fn step ->
      step.rule == :reserve and match?(:warn, step.tag)
    end)

    # et la transition “complète” doit bien amener à :reserved
    assert {:next_state, s2} = ExFSM.Machine.event(s, {:reservation_created, p0})
    assert s2.state == :reserved
  end

  test "dry_run et plan: init/reservation_created" do
    {:ok, info} = ExFSM.RuleEngine.dry_run(Rules.OrderFSM.Complex, {:init, :reservation_created})
    # plan nominal commence par :validate et contient :reserve
    assert hd(info.plan) == :validate
    assert :reserve in info.plan

    plan = ExFSM.RuleEngine.plan(Rules.OrderFSM.Complex, {:init, :reservation_created})
    assert plan == info.plan
  end

  test "sell OK: reserved → sold" do
    s0 = %RulesTest.Complex.State{state: :init}
    p0 = %{id: 1, lines: [%{}]}

    assert {:next_state, s_res} = ExFSM.Machine.event(s0, {:reservation_created, p0})
    assert s_res.state == :reserved

    # paiement OK
    assert {:next_state, s_sold} = ExFSM.Machine.event(s_res, {:sell, %{payment_ok: true}})
    assert s_sold.state == :sold
  end

  test "sell KO: reserved reste reserved" do
    s0 = %RulesTest.Complex.State{state: :init}
    p0 = %{id: 1, lines: [%{}]}

    assert {:next_state, s_res} = ExFSM.Machine.event(s0, {:reservation_created, p0})
    assert s_res.state == :reserved

    # paiement KO
    assert {:next_state, s1} = ExFSM.Machine.event(s_res, {:sell, %{payment_ok: false}})
    assert s1.state == :reserved
  end

  test "available_actions depuis :init inclut reservation_created + bypasses" do
    s = %RulesTest.Complex.State{state: :init}
    actions = ExFSM.Machine.available_actions({s, %{}})
    assert :reservation_created in actions
    # bypasses globaux
    assert :cancel_order in actions
    assert :close_order in actions
  end
end
