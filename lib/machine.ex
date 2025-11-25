# ================================= Machine ====================================

defmodule ExFSM.Machine do
  @moduledoc """
  Glue pour exécuter des transitions rules-based.
  Supporte un protocole `State` basé sur `handlers(state, params)`.
  """

  defprotocol State do
    def handlers(state, params)
    def state_name(state)
    def set_state_name(state, new_name, possible_handlers)
  end

  # Normalize handlers to a list
  def to_list(nil), do: []
  def to_list(list) when is_list(list), do: list
  def to_list(one), do: [one]

  # Maps of transitions/bypasses for a list of handlers
  defp transition_map(handlers, method) do
    handlers
    |> Enum.map(&apply(&1, method, []))
    |> Enum.concat()
    |> Enum.into(%{})
  end

  def fsm(handlers) when is_list(handlers), do: transition_map(handlers, :fsm)

  # -----------------------------
  # Détection rule-graph par clé
  # -----------------------------
  defp supports_rules_key?(handler, key) do
    cond do
      function_exported?(handler, :rules_graph, 0) ->
        try do
          handler.rules_graph() |> Map.has_key?(key)
        rescue
          _ -> false
        end

      function_exported?(handler, :__rules_entry__, 1) ->
        try do
          _ = apply(handler, :__rules_entry__, [key])
          true
        rescue
          FunctionClauseError -> false
          UndefinedFunctionError -> false
        catch
          :error, :function_clause -> false
        end

      true ->
        false
    end
  end

  # -----------------------------
  # Engines (formes unifiées)
  # -----------------------------
  @doc """
  Engine classique (deftrans). Retour unifié:
  {:next_state, next, state2, [timeout: integer() | nil]}
  """
  def classic_engine(handler, state, {action, params}) do
    handlers_list = to_list(State.handlers(state, params))

    case apply(handler, State.state_name(state), [{action, params}, state]) do
      {:next_state, next, state2, timeout} ->
        {:next_state, next, State.set_state_name(state2, next, handlers_list), [timeout: timeout]}

      {:next_state, next, state2} ->
        {:next_state, next, State.set_state_name(state2, next, handlers_list), []}

      {:keep_state, state2} ->
        # On reste cohérent: retourne next_state = nom courant (ou celui de state2 s’il a changé)
        next = Map.get(state2, :__state__, State.state_name(state))
        {:next_state, next, state2, [keep: true]}

      other ->
        other
    end
  end

  @doc """
  Engine RuleEngine (deftrans_rules). Retour unifié:
  {:next_state, next, state2, [acc: %ExFSM.Acc{}, timeout: nil]}
  En :steps_only -> retourne le tuple steps_only tel quel (on ne rabat pas).
  """
  def rules_engine(handler, state, action, params, opts \\ []) do
    key   = {State.state_name(state), action}
    mode  = Keyword.get(opts, :mode, :full)
    hlist = to_list(State.handlers(state, params))

    case ExFSM.RuleEngine.run(handler, key, params, state, mode: mode) do
      {:next_state, next, new_state, acc} ->
        new_state2 = State.set_state_name(new_state, next, hlist) |> IO.inspect(label: "NEXT STATE")
        {:next_state, next, new_state2, [acc: acc]}

      {:steps_done, p, st, ext, acc} ->
        # On laisse au call-site décider comment utiliser steps_only.
        {:steps_done, p, st, ext, acc}

      other ->
        other
    end
  end

  @doc """
  Choisit l'engine **par clé**. Retour unifié dans tous les cas.
  opts passées au rules_engine (ex: [mode: :full | :steps_only]).
  """
  def dispatch_engine(handler, state, {action, params}, opts \\ []) do
    key = {State.state_name(state), action}

    cond do
      supports_rules_key?(handler, key) ->
        rules_engine(handler, state, action, params, opts)

      function_exported?(handler, State.state_name(state), 2) ->
        classic_engine(handler, state, {action, params})

      true ->
        {:error, {:no_engine_for, key}}
    end
  end

  # -----------------------------
  # Bypasses
  # -----------------------------
  def event_bypasses(handlers) when is_list(handlers),
    do: transition_map(handlers, :event_bypasses)

  # -----------------------------
  # Entry point unifié
  # -----------------------------
  @doc """
  Applique {action, params} à `state` via le handler résolu, en renvoyant
  **toujours** la forme unifiée:

      {:next_state, next_state_atom, new_state, opts_kw}

  Cas steps_only côté RuleEngine:
      {:steps_done, params, state, external_state, acc}
  """
  def event(state, {action, params}, opts \\ []) do
    case find_handlers({state, action, params}) do
      [handler | _] ->
        dispatch_engine(handler, state, {action, params}, opts)

      [] ->
        case find_bypasses({state, action, params}) do
          [handler | _] ->
            # Bypass classique, on unifie aussi
            case apply(handler, action, [params, state]) do
              {:keep_state, state2} ->
                next = Map.get(state2, :__state__, State.state_name(state))
                {:next_state, next, state2, [keep: true, timeout: nil, acc: nil]}

              {:next_state, next, state2, timeout} ->
                {:next_state,
                 next,
                 State.set_state_name(state2, next, to_list(State.handlers(state, params))),
                 [timeout: timeout, acc: nil]}

              {:next_state, next, state2} ->
                {:next_state,
                 next,
                 State.set_state_name(state2, next, to_list(State.handlers(state, params))),
                 [timeout: nil, acc: nil]}

              other ->
                other
            end

          _ ->
            {:error, :illegal_action}
        end
    end
  end

  # Find handler(s) for a given (state_name, action)
  def find_handlers({state_name, action}, handlers) when is_list(handlers) do
    case Map.get(fsm(handlers), {state_name, action}) do
      {h, _} -> [h]
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Param-aware handler resolution
  def find_handlers({state, action, params}) do
    handlers = to_list(State.handlers(state, params))
    find_handlers({State.state_name(state), action}, handlers)
  end

  def find_bypasses({state, action, params}) do
    handlers = to_list(State.handlers(state, params))

    case Map.get(event_bypasses(handlers), action) do
      nil -> []
      h when is_list(h) -> h
      h -> [h]
    end
  end

  @spec available_actions(State.t()) :: [atom()]
  def available_actions(state) do
    state_name = State.state_name(state)
    handler     = State.handlers(state, %{}) |> List.first()

    classic_actions =
      handler.fsm()
      |> Enum.filter(fn {{from,_},_} -> from == state_name end)
      |> Enum.map(fn {{_,action},_} -> action end)

    rules_actions =
      if function_exported?(handler, :rules_graph, 0) do
        handler.rules_graph()
        |> Map.keys()
        |> Enum.filter(fn {s,_} -> s == state_name end)
        |> Enum.map(fn {_, action} -> action end)
      else
        []
      end

    bypass_actions =
      handler.event_bypasses()
      |> Map.keys()

    Enum.uniq(classic_actions ++ rules_actions ++ bypass_actions)
  end

  @spec action_available?(State.t(), atom()) :: boolean()
  def action_available?(state, action) do
    action in available_actions(state)
  end
end
