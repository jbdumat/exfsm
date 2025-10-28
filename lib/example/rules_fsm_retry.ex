defmodule Rules.OrderFSM.Complex do
  use ExFSM

  # -------------------------------
  # Transition INIT -> (RESERVED | REJECTED)
  # validate -> (reject | reserve) -> (notify_ok | notify_warn) -> exit
  # -------------------------------

  @to [:reserved, :rejected]
  @doc "Création de réservation: validation, réservation stock, notification"
  deftrans_rules init({:reservation_created, _params}, _state) do
    # 1) validate : exige au minimum :id et :lines (non vides)
    defrule validate(p) do
      valid? = is_map(p) and Map.has_key?(p, :id) and match?([_|_], Map.get(p, :lines, []))
      if valid?, do: next_ok({:reserve, p}), else: next_ok({:reject, p})
    end

    # 2) reject : sortie erreur
    defrule reject(_p) do
      rules_exit({:error, :invalid_params})
    end

    # 3) reserve : stock ok / warn / error
    defrule reserve(p) do
      cond do
        Map.get(p, :force_error, false) ->
          next_error({:notify_warn, p})

        Map.get(p, :force_warn, false) ->
          next_warn({:notify_warn, p})

        true ->
          next_ok({:notify_ok, p})
      end
    end

    # 4) notifications (ex: mail/event)
    defrule notify_ok(_p),   do: rules_exit({:ok, :reserved})
    defrule notify_warn(_p), do: rules_exit({:warning, :reserved})

    # Figer le graphe + poids (plan nominal déterministe)
    defrules_commit(entry: :validate, weights: %{reserve: 80, notify_ok: 50, notify_warn: 49, reject: 10, validate: 100})

    # Épilogue runtime: issue -> next_state
    defrules_exit(_params, state, acc) do
      # IO.inspect(acc)
      state = Map.put(state, :meta, acc)
      case acc.exit do
        {:ok, :reserved}          -> {:next_state, :reserved, state}
        {:warning, :reserved}     -> {:next_state, :reserved, state}
        {:error, :invalid_params} -> {:next_state, :init, state}
        other -> {:error, other}
      end
    end
  end

  # -------------------------------
  # Transition RESERVED -> (SOLD | RESERVED)
  # charge -> (invoice | fail) -> exit
  # -------------------------------

  @to [:sold, :reserved]
  @doc "Vente: paiement, facturation"
  deftrans_rules reserved({:sell, _params}, _state) do
    defrule charge(p) do
      if Map.get(p, :payment_ok, true),
        do: next_ok({:invoice, p}),
        else: next_error({:fail, p})
    end

    defrule invoice(_p), do: rules_exit({:ok, :sold})
    defrule fail(_p),    do: rules_exit({:error, :payment_failed})

    defrules_commit(entry: :charge, weights: %{
      charge: 100, invoice: 50, fail: 10
    })

    defrules_exit(_params, state, acc) do
      case acc.exit do
        {:ok, :sold}              -> {:next_state, :sold, state}
        {:error, :payment_failed} -> {:next_state, :reserved, state}
        other -> {:error, other}
      end
    end
  end

  # -------------------------------
  # BYPASSES globaux
  # -------------------------------

  @doc "Annuler la commande (bypass global)"
  defbypass cancel_order(_params, state) do
    {:next_state, :canceled, state}
  end

  @doc "Clore la commande (bypass global)"
  defbypass close_order(_params, state) do
    {:next_state, :closed, state}
  end
end

defmodule RulesTest.Complex.State do
  defstruct state: :init
end

defimpl ExFSM.Machine.State, for: RulesTest.Complex.State do
  # Ici on ne fait varier qu’avec un seul handler; tu peux retourner une liste si besoin.
  def handlers(_s, _params), do: [Rules.OrderFSM.Complex]
  def state_name(s), do: s.state
  def set_state_name(s, name, _possible_handlers), do: %{s | state: name}
end
