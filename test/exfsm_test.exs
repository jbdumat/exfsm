defmodule ExFSMTest do
  use ExUnit.Case, async: false

  alias ExFSM.{Machine, RuleEngine, Meta, Acc}

  # ---------------------------------------------------------------------------
  # Test FSM: keep_state_name / keep_state (uses a struct to avoid conflicting
  # with the Map protocol impl declared in Example.DEMO_FSM)
  # ---------------------------------------------------------------------------

  defmodule KeepTestState do
    defstruct [:__state__, :value]
  end

  defmodule KeepTestFSM do
    use ExFSM

    defimpl ExFSM.Machine.State, for: KeepTestState do
      def handlers(_state, _params), do: [KeepTestFSM]
      def state_name(state), do: state.__state__
      def set_state_name(state, name, _handlers), do: %{state | __state__: name}
    end

    # Returns {:keep_state_name, updated_entity} — same phase, entity changed
    deftrans active({:update, params}, state) do
      {:keep_state_name, %{state | value: params[:value]}}
    end

    # Returns :keep_state — entity completely untouched
    deftrans active({:noop, _params}, state) do
      _ = state
      :keep_state
    end

    # Rules-based: keep_state_name from defrules_exit
    deftrans_rules active(:rules_update) do
      defrule do_update(params, state) do
        rules_exit(:updated, params, %{state | value: params[:value]}, :ok)
      end

      defrules_commit(entry: :do_update)

      defrules_exit(_params, new_state, proposed) do
        case proposed do
          :updated -> {:keep_state_name, new_state}
          _ -> {:error, :unexpected}
        end
      end
    end

    # Rules-based: :keep_state from defrules_exit
    deftrans_rules active(:rules_noop) do
      defrule just_exit(params, state) do
        rules_exit(:done, params, state, :ok)
      end

      defrules_commit(entry: :just_exit)

      defrules_exit(_params, _new_state, _proposed) do
        :keep_state
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Rules-based transitions (deftrans_rules)
  # ---------------------------------------------------------------------------

  describe "rules-based transitions via Machine.event/3" do
    test "happy path: pay from rules_pending_payment transitions to :paid" do
      state = %{__state__: :rules_pending_payment}
      assert {:next_state, :paid, new_state, opts} = Machine.event(state, {:pay, %{}})
      assert new_state.__state__ == :paid
      assert is_list(opts)
    end

    test "error in check_payment routes to :payment_error" do
      state = %{__state__: :rules_pending_payment}
      params = %{"fail" => "payment"}
      assert {:next_state, :payment_error, new_state, opts} = Machine.event(state, {:pay, params})
      assert new_state.__state__ == :payment_error
      acc = opts[:acc]
      assert %Acc{} = acc
      assert acc.exit == {:error, :check_payment_error}
    end

    test "error in check_fraud routes to :payment_error" do
      state = %{__state__: :rules_pending_payment}
      params = %{"fail" => "fraud"}
      assert {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, params})
      acc = opts[:acc]
      assert acc.exit == {:error, :check_fraud_error}
    end

    test "error in notify_erp routes to :payment_error" do
      state = %{__state__: :rules_pending_payment}
      params = %{"fail" => "erp"}
      assert {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, params})
      acc = opts[:acc]
      assert acc.exit == {:error, :notify_erp_error}
    end

    test "warning in notify_erp takes the warning branch through update_lines_w_erp" do
      state = %{__state__: :rules_pending_payment}
      params = %{"erp" => "warning"}
      assert {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, params})
      acc = opts[:acc]
      assert acc.exit == {:ok, :tmp_paid}
      rules = Enum.map(acc.steps, & &1.rule)
      assert :notify_erp in rules
      assert :update_lines_w_erp in rules
    end

    test "error in update_lines routes to :payment_error" do
      state = %{__state__: :rules_pending_payment}
      params = %{"fail" => "lines"}
      assert {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, params})
      acc = opts[:acc]
      assert acc.exit == {:error, :update_lines_error}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Classic transitions (deftrans)
  # ---------------------------------------------------------------------------

  describe "classic transitions via Machine.event/3" do
    test "happy path: pay from classic_pending_payment transitions to :paid" do
      state = %{__state__: :classic_pending_payment}
      assert {:next_state, :paid, new_state, opts} = Machine.event(state, {:pay, %{}})
      assert new_state.__state__ == :paid
      assert is_list(opts)
    end

    test "error in classic transition routes to :payment_error" do
      state = %{__state__: :classic_pending_payment}
      params = %{"fail" => "payment"}
      assert {:next_state, :payment_error, new_state, _opts} = Machine.event(state, {:pay, params})
      assert new_state.__state__ == :payment_error
    end

    test "classic fraud error routes to :payment_error" do
      state = %{__state__: :classic_pending_payment}
      params = %{"fail" => "fraud"}
      assert {:next_state, :payment_error, _new_state, _opts} = Machine.event(state, {:pay, params})
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Accumulator verification
  # ---------------------------------------------------------------------------

  describe "accumulator structure" do
    test "happy path accumulator has correct steps" do
      state = %{__state__: :rules_pending_payment}
      {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      acc = opts[:acc]

      assert %Acc{} = acc
      assert is_list(acc.steps)
      assert length(acc.steps) == 4

      rules_in_order = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert rules_in_order == [:check_payment, :check_fraud, :notify_erp, :update_lines]
    end

    test "each step has required fields" do
      state = %{__state__: :rules_pending_payment}
      {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      acc = opts[:acc]

      for step <- acc.steps do
        assert Map.has_key?(step, :rule)
        assert Map.has_key?(step, :tag)
        assert Map.has_key?(step, :in)
        assert Map.has_key?(step, :out)
        assert Map.has_key?(step, :chosen)
        assert Map.has_key?(step, :time_us)
        assert is_atom(step.rule)
        assert is_atom(step.tag)
        assert is_map(step.in)
        assert is_map(step.out)
        assert is_integer(step.time_us)
      end
    end

    test "steps are recorded in reverse chronological order (newest first)" do
      state = %{__state__: :rules_pending_payment}
      {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      acc = opts[:acc]

      [last_step | _] = acc.steps
      assert last_step.rule == :update_lines
      assert last_step.chosen == :exit
    end

    test "exit field is set correctly in accumulator" do
      state = %{__state__: :rules_pending_payment}
      {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      acc = opts[:acc]
      assert acc.exit == {:ok, :paid}
    end

    test "error path accumulator stops at failing rule" do
      state = %{__state__: :rules_pending_payment}
      {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, %{"fail" => "fraud"}})
      acc = opts[:acc]

      assert length(acc.steps) == 2
      rules = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert rules == [:check_payment, :check_fraud]
    end
  end

  # ---------------------------------------------------------------------------
  # 4. RuleEngine.run/5 directly
  # ---------------------------------------------------------------------------

  describe "RuleEngine.run/5" do
    test ":full mode returns {:next_state, ...}" do
      state = %{__state__: :rules_pending_payment}

      result =
        RuleEngine.run(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          %{},
          state,
          fsm_mode: :full
        )

      assert {:next_state, :paid, _new_state, %Acc{}} = result
    end

    test ":steps_only mode returns {:steps_done, ...}" do
      state = %{__state__: :rules_pending_payment}

      result =
        RuleEngine.run(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          %{},
          state,
          fsm_mode: :steps_only
        )

      assert {:steps_done, params, _st, _ext_state, %Acc{} = acc} = result
      assert is_map(params)
      assert length(acc.steps) == 4
    end

    test ":full mode with error params" do
      state = %{__state__: :rules_pending_payment}

      result =
        RuleEngine.run(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          %{"fail" => "payment"},
          state,
          fsm_mode: :full
        )

      assert {:next_state, :payment_error, _new_state, %Acc{} = acc} = result
      assert acc.exit == {:error, :check_payment_error}
      assert length(acc.steps) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # 5. RuleEngine.replay/6
  # ---------------------------------------------------------------------------

  describe "RuleEngine.replay/6" do
    test "replay from steps_only result in full mode completes successfully" do
      state = %{__state__: :rules_pending_payment}

      {:steps_done, params, _st, ext_state, acc} =
        RuleEngine.run(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          %{},
          state,
          fsm_mode: :steps_only
        )

      result =
        RuleEngine.replay(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          params,
          ext_state,
          acc,
          fsm_mode: :full
        )

      assert {:next_state, :paid, _new_state, %Acc{}} = result
    end

    test "replay with :from option starts from specified rule" do
      state = %{__state__: :rules_pending_payment}

      {:steps_done, params, _st, ext_state, acc} =
        RuleEngine.run(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          %{},
          state,
          fsm_mode: :steps_only
        )

      result =
        RuleEngine.replay(
          Example.DEMO_FSM,
          {:rules_pending_payment, :pay},
          params,
          ext_state,
          acc,
          fsm_mode: :full,
          from: :notify_erp
        )

      assert {:next_state, :paid, _new_state, %Acc{}} = result
    end
  end

  # ---------------------------------------------------------------------------
  # 6. RuleEngine.dry_run/2
  # ---------------------------------------------------------------------------

  describe "RuleEngine.dry_run/2" do
    test "returns ok tuple with plan, graph, and entry" do
      result = RuleEngine.dry_run(Example.DEMO_FSM, {:rules_pending_payment, :pay})
      assert {:ok, info} = result
      assert Map.has_key?(info, :plan)
      assert Map.has_key?(info, :graph)
      assert Map.has_key?(info, :entry)

      assert is_list(info.plan)
      assert is_map(info.graph)
      assert info.entry == :check_payment
    end

    test "plan contains expected rule sequence" do
      {:ok, info} = RuleEngine.dry_run(Example.DEMO_FSM, {:rules_pending_payment, :pay})
      assert :check_payment in info.plan
      assert :check_fraud in info.plan
      assert :notify_erp in info.plan
    end

    test "graph contains all defined rules" do
      {:ok, info} = RuleEngine.dry_run(Example.DEMO_FSM, {:rules_pending_payment, :pay})
      graph_rules = Map.keys(info.graph)
      assert :check_payment in graph_rules
      assert :check_fraud in graph_rules
      assert :notify_erp in graph_rules
      assert :update_lines in graph_rules
      assert :update_lines_w_erp in graph_rules
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Introspection
  # ---------------------------------------------------------------------------

  describe "introspection" do
    test "rules_graph returns expected structure" do
      graph = Example.DEMO_FSM.rules_graph()
      assert is_map(graph)
      assert Map.has_key?(graph, {:rules_pending_payment, :pay})

      ruleset = graph[{:rules_pending_payment, :pay}]
      assert ruleset.entry == :check_payment
      assert is_map(ruleset.graph)
    end

    test "rules_outputs has the right keys" do
      outputs = Example.DEMO_FSM.rules_outputs()
      assert is_map(outputs)
      assert Map.has_key?(outputs, {:rules_pending_payment, :pay})
    end

    test "__rules_entry__ returns :check_payment for rules_pending_payment/pay" do
      assert Example.DEMO_FSM.__rules_entry__({:rules_pending_payment, :pay}) == :check_payment
    end

    test "fsm() includes both classic and rules entries" do
      fsm = Example.DEMO_FSM.fsm()
      assert is_map(fsm)
      assert Map.has_key?(fsm, {:classic_pending_payment, :pay})
      assert Map.has_key?(fsm, {:rules_pending_payment, :pay})
    end

    test "available_actions includes :pay for rules_pending_payment" do
      state = %{__state__: :rules_pending_payment}
      actions = Machine.available_actions({state, %{}})
      assert :pay in actions
    end

    test "available_actions includes :pay for classic_pending_payment" do
      state = %{__state__: :classic_pending_payment}
      actions = Machine.available_actions({state, %{}})
      assert :pay in actions
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Machine.event with illegal action
  # ---------------------------------------------------------------------------

  describe "illegal actions" do
    test "nonexistent state returns :illegal_action" do
      state = %{__state__: :nonexistent}
      assert {:error, :illegal_action} = Machine.event(state, {:bogus, %{}})
    end

    test "valid state but unknown event returns error" do
      state = %{__state__: :rules_pending_payment}
      assert {:error, :illegal_action} = Machine.event(state, {:unknown_event, %{}})
    end
  end

  # ---------------------------------------------------------------------------
  # 11. keep_state_name / keep_state (classic deftrans)
  # ---------------------------------------------------------------------------

  describe "keep_state_name and keep_state — classic deftrans" do
    test "{:keep_state_name, new_state} keeps the phase, updates entity" do
      state = %KeepTestState{__state__: :active, value: :old}
      assert {:next_state, :active, new_state, opts} =
               Machine.event(state, {:update, [value: :new]})

      assert new_state.__state__ == :active
      assert new_state.value == :new
      assert opts == []
    end

    test ":keep_state keeps both phase and entity untouched" do
      state = %KeepTestState{__state__: :active, value: :original}
      assert {:next_state, :active, new_state, opts} =
               Machine.event(state, {:noop, %{}})

      assert new_state == state
      assert opts == []
    end
  end

  # ---------------------------------------------------------------------------
  # 12. keep_state_name / keep_state (rules defrules_exit)
  # ---------------------------------------------------------------------------

  describe "keep_state_name and keep_state — defrules_exit" do
    test "{:keep_state_name, new_state} from defrules_exit keeps phase, updates entity" do
      state = %KeepTestState{__state__: :active, value: :old}
      assert {:next_state, :active, new_state, opts} =
               Machine.event(state, {:rules_update, [value: :new]})

      assert new_state.__state__ == :active
      assert new_state.value == :new
      assert %Acc{} = opts[:acc]
    end

    test ":keep_state from defrules_exit keeps both phase and entity untouched" do
      state = %KeepTestState{__state__: :active, value: :original}
      assert {:next_state, :active, new_state, opts} =
               Machine.event(state, {:rules_noop, %{}})

      assert new_state == state
      assert %Acc{} = opts[:acc]
    end
  end

  # ---------------------------------------------------------------------------
  # 9. ExFSM.meta_put / opts[:meta] surfacing
  # ---------------------------------------------------------------------------

  describe "ExFSM.meta_put/2 and opts[:meta]" do
    test "meta_put values are returned in opts[:meta] after a rules transition" do
      state = %{__state__: :rules_pending_payment}
      assert {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      assert opts[:meta] == %{payment_result: :paid}
    end

    test "meta written during an error path is also surfaced" do
      state = %{__state__: :rules_pending_payment}
      params = %{"fail" => "payment"}
      assert {:next_state, :payment_error, _new_state, opts} = Machine.event(state, {:pay, params})
      assert opts[:meta] == %{payment_result: :check_payment_error}
    end

    test "meta delta is reset at the start of each rules transition (no bleed-over)" do
      state = %{__state__: :rules_pending_payment}

      # First transition writes :payment_result => :paid
      {:next_state, :paid, new_state, opts1} = Machine.event(state, {:pay, %{}})
      assert opts1[:meta] == %{payment_result: :paid}

      # The new state is :paid — no transition defined from there, so replay from
      # a fresh :rules_pending_payment state to trigger a second rules run and
      # confirm the delta was reset (only this run's key is present).
      {:next_state, :payment_error, _, opts2} =
        Machine.event(%{__state__: :rules_pending_payment}, {:pay, %{"fail" => "payment"}})

      assert opts2[:meta] == %{payment_result: :check_payment_error}
      # The first run's :paid value must NOT appear
      refute opts2[:meta][:payment_result] == :paid

      _ = new_state
    end

    test "opts[:meta] is absent for classic deftrans transitions" do
      state = %{__state__: :classic_pending_payment}
      assert {:next_state, :paid, _new_state, opts} = Machine.event(state, {:pay, %{}})
      refute Keyword.has_key?(opts, :meta)
    end
  end

  # ---------------------------------------------------------------------------
  # 10. ExFSM.Meta (low-level)
  # ---------------------------------------------------------------------------

  describe "ExFSM.Meta" do
    test "init/get/put cycle" do
      state0 = %{__state__: :test_state}
      params0 = %{"key" => "value"}
      acc0 = %Acc{params: params0, state: state0}

      Meta.init(state0, params0, acc0)
      meta = Meta.get()

      assert meta.initial_state == state0
      assert meta.initial_params == params0
      assert meta.acc == acc0
      assert meta.delta == %{}
    end

    test "update_acc updates the accumulator in meta" do
      state0 = %{__state__: :test_state}
      Meta.init(state0, %{}, %Acc{})

      new_acc = %Acc{steps: [%{rule: :test_rule, tag: :ok}], exit: {:ok, :done}}
      Meta.update_acc(new_acc)

      meta = Meta.get()
      assert meta.acc == new_acc
      assert meta.acc.exit == {:ok, :done}
    end

    test "get returns default when nothing is set" do
      Process.delete(:exfsm_meta)

      meta = Meta.get()
      assert meta.initial_state == nil
      assert meta.initial_params == %{}
      assert meta.acc == %Acc{}
      assert meta.delta == %{}
    end
  end
end
