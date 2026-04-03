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

  # simulate a stable fingerprint for replay checks
  defp replay_fp(state, params) do
    # Avoid including replay_fp itself in the fingerprint
    clean = Map.drop(params, ["replay_fp"])
    :erlang.phash2({state.__state__, clean})
  end

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

  # -------------------------------------------------------------------------
  # DEMO: error + replay using ACC
  # -------------------------------------------------------------------------

  # 1) Dry-run that ends in an error (steps_only)
  # Show: {:steps_done, p, st, ext, acc} + acc.exit + acc.steps
  def demo_rules_error_dry_run() do
    state = %{__state__: :rules_pending_payment}
    params = %{"fail" => "fraud"}  # will fail at check_fraud
    ExFSM.Machine.event(state, {:pay, params}, fsm_mode: :steps_only)
  end

  # 2) Replay/commit with SAME inputs returned by dry-run
  # Show: returns {:next_state, :payment_error, ..., [acc: acc]}
  def demo_rules_replay_error_same_inputs() do
    case demo_rules_error_dry_run() do
      {:steps_done, p, st, _ext, _acc} ->
        ExFSM.Machine.event(st, {:pay, p}, fsm_mode: :full)

      other ->
        other
    end
  end

  # 3) Replay attempt after "fixing" the input, but reusing the old replay token
  # This should be rejected by your replay_fp mismatch rule.
  # Show: next_state payment_error, acc.exit indicates :replay_mismatch (via rules_exit)
  def demo_rules_replay_error_reject_after_fix() do
    case demo_rules_error_dry_run() do
      {:steps_done, p, st, _ext, _acc} ->
        # "Fix" the error but keep the old replay_fp -> mismatch expected
        p2 =
          p
          |> Map.delete("fail")
          |> Map.put("tampered_fix", true)

        IO.inspect {st, p2}

        ExFSM.Machine.event(st, {:pay, p2}, fsm_mode: :full)

      other ->
        other
    end
  end

  def demo_classic() do
    state = %{__state__: :classic_pending_payment}
    ExFSM.Machine.event(state, {:pay, %{}}, [])
  end

  def demo_rules() do
    state = %{__state__: :rules_pending_payment}
    ExFSM.Machine.event(state, {:pay, %{}}, [])
  end

  # --- NEW: dry-run (steps_only) ---
  def demo_rules_dry_run(params \\ %{}) do
    state = %{__state__: :rules_pending_payment}

    ExFSM.Machine.event(state, {:pay, params}, fsm_mode: :steps_only)
    # => {:steps_done, p, st, ext, acc}
  end

  # --- NEW: replay OK (dry-run => replay/commit full) ---
  def demo_rules_replay_ok(params \\ %{}) do
    case demo_rules_dry_run(params) do
      {:steps_done, p, st, _ext, _acc} ->
        # Replay/commit with the enriched params coming from steps_only
        ExFSM.Machine.event(st, {:pay, p}, fsm_mode: :full)

      other ->
        other
    end
  end

  # --- NEW: replay reject (tamper with params after dry-run) ---
  def demo_rules_replay_reject(params \\ %{}) do
    case demo_rules_dry_run(params) do
      {:steps_done, p, st, _ext, _acc} ->
        # Simulate "replay drift": change something after dry-run
        p2 = Map.put(p, "tampered", true)
        ExFSM.Machine.event(st, {:pay, p2}, fsm_mode: :full)

      other ->
        other
    end
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

  deftrans_rules rules_pending_payment({:pay, _}, state) do
    defrule check_payment(params, state) do
      # Attach a replay fingerprint early so steps_only can return it,
      # and full run can verify it before committing.
      fp = replay_fp(state, params)
      params = Map.put_new(params, "replay_fp", fp)

      # If this is a replay/commit run, verify that params/state match the dry-run fp
      fp2 = replay_fp(state, params)
      if params["replay_fp"] != fp2 do
        rules_exit(:replay_mismatch, params, state, :error)
      else
        case check_payment(state, params) do
          :ok -> next_rule({:check_fraud, params, state}, :ok)
          :error -> rules_exit(:check_payment_error, params, state, :error)
        end
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

# defmodule Example.DEMO_FSM do
#   use ExFSM

#   defimpl ExFSM.Machine.State, for: Map do
#     def handlers(_state, _params) do
#       [Example.DEMO_FSM]
#     end
#     def state_name(state), do: Map.fetch!(state, :__state__)
#     def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
#   end

#   defp check_payment(order, params) do
#     :ok
#   end

#   defp check_fraud(order, params) do
#     :ok
#   end

#   defp notify_erp(order, params) do
#     {:ok, order}
#   end

#   defp update_lines(order, params) do
#     :ok
#   end

#   defp update_lines_w_erp(order, params) do
#     "ok"
#   end

#     # ------ DEMO --------

#   def demo_classic() do
#     state = %{__state__: :classic_pending_payment}
#     ExFSM.Machine.event(state, {:pay, %{}}, [])
#   end

#   def demo_rules() do
#     state2 = %{__state__: :rules_pending_payment}
#     ExFSM.Machine.event(state2, {:pay, %{}}, [])
#   end


#   # ------ ExFSM v1 --------

#   deftrans classic_pending_payment({:pay, params}, state) do
#     with :ok <- check_payment(state, params),
#          :ok <- check_fraud(state, params),
#          {:ok, new_state} <- notify_erp(state, params) do
#       :ok = update_lines(new_state, params)
#       {:next_state, :paid, new_state}
#     else
#       other -> {:next_state, :payment_error, state}
#     end
#   end

#   # ------ ExFSM v2 --------

#   deftrans_rules rules_pending_payment({:pay, _}, state) do

#     defrule check_payment(params, state) do
#       case check_payment(state, params) do
#         :ok ->
#           next_rule({:check_fraud, params, state}, :ok)
#         :error ->
#           rules_exit(:check_payment_error, params, state, :error)
#       end
#     end

#     defrule check_fraud(params, state) do
#       case check_fraud(state, params) do
#         :ok ->
#           next_rule({:notify_erp, params, state}, :ok)
#         :error ->
#           rules_exit(:check_fraud_error, params, state, :error)
#       end
#     end

#     defrule notify_erp(params, state) do
#       case notify_erp(state, params) do
#         {:ok, new_state} ->
#           next_rule({:update_lines, params, new_state}, :ok)
#         :warning ->
#           next_rule({:update_lines_w_erp, params, state}, :warning)
#         :error ->
#           rules_exit(:notify_erp_error, params, state, :error)
#       end
#     end

#     defrule update_lines_w_erp(params, state) do
#       case update_lines(state, params) do
#         :ok ->
#           rules_exit(:tmp_paid, params, state, :ok)
#         :error ->
#           rules_exit(:update_lines_w_erp_error, params, state, :error)
#       end
#     end

#     defrule update_lines(params, state) do
#       case update_lines(state, params) do
#         :ok ->
#           rules_exit(:paid, params, state, :ok)
#         :error ->
#           rules_exit(:update_lines_error, params, state, :error)
#       end
#     end

#     defrules_commit(entry: :check_payment)

#     defrules_exit(_new_params, new_state_flow, proposed) do
#         m = ExFSM.meta()
#         _acc = m.acc
#         IO.inspect("Rule :exit")

#         case proposed do
#           :paid -> {:next_state, proposed, new_state_flow}
#           other -> {:error, {:unexpected_error, other}}
#         end
#       end
#   end

# end
