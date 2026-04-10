defmodule Example.DEMO_FSM do
  use ExFSM

  defimpl ExFSM.Machine.State, for: Map do
    def handlers(_state, _params), do: [Example.DEMO_FSM]
    def state_name(state), do: Map.fetch!(state, :__state__)
    def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
  end

  # ----------------------------------------------------------------------------
  # Demo helpers (simulate external checks based on params)
  # ----------------------------------------------------------------------------

  defp check_payment(_order, %{"fail" => "payment"}), do: :error
  defp check_payment(_order, _params), do: :ok

  defp check_fraud(_order, %{"fail" => "fraud"}), do: :error
  defp check_fraud(_order, _params), do: :ok

  defp notify_erp(_order, %{"fail" => "erp"}), do: :error
  defp notify_erp(_order, %{"erp" => "warning"}), do: :warning
  defp notify_erp(order, _params), do: {:ok, order}

  defp update_lines(_order, %{"fail" => "lines"}), do: :error
  defp update_lines(_order, _params), do: :ok

  defp update_lines_w_erp(_order, _params), do: :ok

  # ----------------------------------------------------------------------------
  # DEMO entrypoints
  # ----------------------------------------------------------------------------

  def demo_classic() do
    state = %{__state__: :classic_pending_payment}
    ExFSM.Machine.event(state, {:pay, %{}}, [])
  end

  def demo_rules() do
    state = %{__state__: :rules_pending_payment}
    ExFSM.Machine.event(state, {:pay, %{}}, [])
  end

  def demo_error() do
    state = %{__state__: :rules_pending_payment}
    ExFSM.Machine.event(state, {:pay, %{"fail" => "payment"}}, [])
  end

  def replay_error() do
    base_params = %{"fail" => "payment"}
    state = %{__state__: :rules_pending_payment}
    {:next_state, _status, new_state, meta} = ExFSM.Machine.event(state, {:pay, %{"fail" => "payment"}}, [])

    params_override = %{}
    acc = Keyword.get(meta, :acc)

    ExFSM.RuleEngine.replay(Example.DEMO_FSM, {:rules_pending_payment, :pay}, base_params, new_state, acc, [params_override: params_override])
    # You can keep base params and either override params with opts (see above) or even merge params with opts :merge_params
    # ExFSM.RuleEngine.replay(Example.DEMO_FSM, {:rules_pending_payment, :pay}, params_override, new_state, acc)
  end


  # ----------------------------------------------------------------------------
  # ExFSM v1 (classic)
  # ----------------------------------------------------------------------------

  deftrans classic_pending_payment({:pay, params}, state) do
    with :ok <- check_payment(state, params),
         :ok <- check_fraud(state, params),
         {:ok, new_state} <- notify_erp(state, params) do
      :ok = update_lines(new_state, params)
      {:next_state, :paid, new_state}
    else
      _other -> {:next_state, :payment_error, state}
    end
  end

  # ----------------------------------------------------------------------------
  # ExFSM v2 (rules)
  # ----------------------------------------------------------------------------

  deftrans_rules rules_pending_payment(:pay) do
    defrule check_payment(toto, titi) do
      case check_payment(titi, toto) do
        :ok -> next_rule({:check_fraud, toto, titi}, :ok)
        :error -> rules_exit(:check_payment_error, toto, titi, :error)
      end
    end

    defrule check_fraud(params, state) do
      case check_fraud(state, params) do
        :ok -> next_rule({:notify_erp, params, state}, :ok)
        :error -> rules_exit(:check_fraud_error, params, state, :error)
      end
    end

    defrule notify_erp(params, state) do
      case notify_erp(state, params) do
        {:ok, new_state} -> next_rule({:update_lines, params, new_state}, :ok)
        :warning -> next_rule({:update_lines_w_erp, params, state}, :warning)
        :error -> rules_exit(:notify_erp_error, params, state, :error)
      end
    end

    defrule update_lines_w_erp(params, state) do
      case update_lines_w_erp(state, params) do
        :ok -> rules_exit(:tmp_paid, params, state, :ok)
        :error -> rules_exit(:update_lines_w_erp_error, params, state, :error)
      end
    end

    defrule update_lines(params, state) do
      case update_lines(state, params) do
        :ok -> rules_exit(:paid, params, state, :ok)
        :error -> rules_exit(:update_lines_error, params, state, :error)
      end
    end

    defrules_commit(entry: :check_payment)

    defrules_exit(_new_params, new_state_flow, proposed) do
      _m = ExFSM.meta()
      IO.inspect("Rule :exit")

      case proposed do
        :paid ->
          {:next_state, :paid, new_state_flow}

        _other ->
          # IMPORTANT: keep it a next_state so Machine.event/3 returns meta [acc: acc]
          # The reason is carried by acc.exit (set by rules_exit/4).
          {:next_state, :payment_error, new_state_flow}
      end
    end
  end
end
