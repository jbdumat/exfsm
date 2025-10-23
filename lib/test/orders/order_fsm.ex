defmodule ExFSMRulesDemo.OrderFSM do
  use ExFSM

  # -------------------------------
  # INIT -> (RESERVED | REJECTED)
  # validate -> (reserve|reject) -> (notify_ok|notify_warn) -> exit
  # -------------------------------

  @to [:reserved, :rejected]
  @doc "Création de réservation"
  deftrans_rules init({:reservation_created, _params}, _state) do
    defrule validate(p) do
      valid? = is_map(p) && Map.has_key?(p, :id) && match?([_|_], Map.get(p, :lines, []))
      if valid?, do: next_rule({:reserve, p}), else: next_rule({:reject, p})
    end

    defrule reject(_p) do
      rules_exit({:error, :invalid_params})
    end

    defrule reserve(p) do
      if Map.get(p, :force_warn, false),
        do: next_rule({:notify_warn, p}),
        else: next_rule({:notify_ok, p})
    end

    defrule notify_ok(_p),   do: rules_exit({:ok, :reserved})
    defrule notify_warn(_p), do: rules_exit({:warning, :reserved})

    # fige le graphe et fixe l’entrée
    defrules_commit(entry: :validate)

    # sortie -> next_state
    defrules_exit(_params, state, acc) do
      case acc.exit do
        {:ok, :reserved}          -> {:next_state, :reserved, state}
        {:warning, :reserved}     -> {:next_state, :reserved, state}
        {:error, :invalid_params} -> {:next_state, :rejected, state}
        other -> {:error, other}
      end
    end
  end

  # -------------------------------
  # RESERVED -> (SOLD | RESERVED)
  # charge -> (invoice|fail) -> exit
  # -------------------------------

  @to [:sold, :reserved]
  @doc "Vente"
  deftrans_rules reserved({:sell, _params}, _state) do
    defrule charge(p) do
      if Map.get(p, :payment_ok, true),
        do: next_rule({:invoice, p}),
        else: next_rule({:fail, p})
    end

    defrule invoice(_p), do: rules_exit({:ok, :sold})
    defrule fail(_p),    do: rules_exit({:error, :payment_failed})

    defrules_commit(entry: :charge)

    defrules_exit(_params, state, acc) do
      case acc.exit do
        {:ok, :sold}              -> {:next_state, :sold, state}
        {:error, :payment_failed} -> {:next_state, :reserved, state}
        other -> {:error, other}
      end
    end
  end

  # -------------------------------
  # BYPASSES (globaux)
  # -------------------------------

  @doc "Annuler"
  defbypass cancel_order(_params, state), do: {:next_state, :canceled, state}

  @doc "Clore"
  defbypass close_order(_params, state), do: {:next_state, :closed, state}
end

defmodule ExFSMRulesDemo.OrderState do
  defstruct state: :init
end

defimpl ExFSM.Machine.State, for: ExFSMRulesDemo.OrderState do
  def handlers(_s, _params), do: [ExFSMRulesDemo.OrderFSM]
  def state_name(s), do: s.state
  def set_state_name(s, name, _handlers), do: %{s | state: name}
end
