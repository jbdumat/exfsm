defmodule ExFSMRulesReplayDemo.FSM do
  use ExFSM

  @to [:done, :failed]

  # Transition : a -> (b|c) -> d -> exit
  # - a choisit b (nominal) sauf si params[:take_c] => c (branche alternative)
  # - c est taguée :warn pour vérifier la traçabilité
  # - d termine en {:ok, :done}

  deftrans_rules init({:go, _params}, _state) do
    # a : choisir la branche
    IO.inspect("HERE")

    defrule a(p) do
      if Map.get(p, :take_c, false) do
        # on émet explicitement un tag :ok ici
        next_ok({:c, p})
      else
        next_ok({:b, p})
      end
    end

    # b : voie nominale vers d
    defrule b(p) do
      next_ok({:d, Map.put(p, :from, :b)})
    end

    # c : voie alternative vers d, tag :warn
    defrule c(p) do
      next_warn({:d, Map.put(p, :from, :c)})
    end

    # d : sortie
    defrule d(_p) do
      rules_exit({:ok, :done})
    end

    # figer le graphe et entry
    defrules_commit(entry: :a, weights: %{a: 100, b: 60, c: 50, d: 10})

    # mapping issue -> next_state
    defrules_exit(_params, state, acc) do
      state = Map.put(state, :meta, acc)
      case acc.exit do
        {:ok, :done} -> {:next_state, :done, state}
        other        -> {:error, other}
      end
    end
  end

  # un bypass pour montrer qu'il coexiste sans gêner
  defbypass cancel(_params, state), do: {:next_state, :failed, state}
end

defmodule ExFSMRulesReplayDemo.State do
  defstruct state: :init
end

defimpl ExFSM.Machine.State, for: ExFSMRulesReplayDemo.State do
  def handlers(_s, _params), do: ExFSMRulesReplayDemo.FSM
  def state_name(s), do: s.state
  def set_state_name(s, name, _handlers), do: %{s | state: name}
end
