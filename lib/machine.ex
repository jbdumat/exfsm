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

  # Maps of transitions/bypasses for a list of handlers.
  # Results are cached in the process dictionary: safe under the transactor pattern
  # where each FSM execution runs in a dedicated short-lived process.
  defp transition_map(handlers, method) do
    cache_key = {__MODULE__, :transition_map_cache, handlers, method}

    case Process.get(cache_key) do
      nil ->
        result =
          handlers
          |> Enum.map(&apply(&1, method, []))
          |> Enum.concat()
          |> Enum.group_by(fn {k, _} -> k end, fn {_, v} -> v end)

        Process.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  def fsm(handlers) when is_list(handlers), do: transition_map(handlers, :fsm)

  # -----------------------------
  # Détection rule-graph par clé
  # -----------------------------
  defp supports_rules_key?(handler, key) do
    cond do
      function_exported?(handler, :rules_graph, 0) ->
        Map.has_key?(handler.rules_graph(), key)

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

    case apply(handler, State.state_name(state), [{action, params}, state]) do
      {:next_state, next, state2, timeout} ->
        {:next_state, next, State.set_state_name(state2, next, State.handlers(state2, params)), [timeout: timeout]}

      {:next_state, next, state2} ->
        {:next_state, next, State.set_state_name(state2, next, State.handlers(state2, params)), []}

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
    key = {State.state_name(state), action}
    fsm_mode = Keyword.get(opts, :fsm_mode, :full)

    case ExFSM.RuleEngine.run(handler, key, params, state, fsm_mode: fsm_mode) do
      {:next_state, next, new_state, acc} ->
        {:next_state, next, State.set_state_name(new_state, next, State.handlers(new_state, params)), [acc: acc]}

      {:steps_done, p, st, ext, acc} ->
        # On laisse au call-site décider comment utiliser steps_only.
        {:steps_done, p, st, ext, acc}

      other ->
        other
    end
  end

  @doc """
  Choisit l'engine **par clé**. Retour unifié dans tous les cas.
  opts passées au rules_engine (ex: [fsm_mode: :full | :steps_only]).
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
                 State.set_state_name(state2, next, State.handlers(state2, params)),
                 [timeout: timeout, acc: nil]}

              {:next_state, next, state2} ->
                {:next_state,
                 next,
                 State.set_state_name(state2, next, State.handlers(state2, params)),
                 [timeout: nil, acc: nil]}

              other ->
                other
            end

          [] ->
            {:error, :illegal_action}
        end
    end
  end

  @spec find_handlers({state_name::atom,event_name::atom},[exfsm_module :: atom]) :: exfsm_module :: atom
  def find_handlers({state_name, action}, handlers) when is_list(handlers) do
    case Map.get(fsm(handlers), {state_name, action}) do
      {h, _} -> [h]
      list when is_list(list) -> Enum.map(list, fn {handler, _} -> handler end)
      _ -> []
    end
  end

  @doc "same as `find_handlers/2` but using a 'meta' state implementing `ExFSM.Machine.State` and filter if a 'match_trans' is available"
  def find_handlers({state, action, params}) do
    state_name = State.state_name(state)
    find_handlers({state_name, action}, State.handlers(state, params))
    |> Enum.filter(fn handler -> handler.match_trans(state_name, action, state, params) end)
  end

  def find_bypasses(action, handlers) when is_list(handlers) do
    case Map.get(event_bypasses(handlers), action) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  def find_bypasses({state, action, params}) do
    find_bypasses(action, State.handlers(state, params))
    |> List.wrap()
    |> Enum.filter(fn handler -> handler.match_bypass(action, state, params) end)
  end

  @spec available_actions({State.t(), any()}) :: [atom()]
  def available_actions({state, params}) do
    state_name = State.state_name(state)
    handlers = State.handlers(state, params)

    classic_actions = ExFSM.Machine.fsm(handlers)
      |> Enum.filter(fn {{from,_},_} -> from == state_name end)
      |> Enum.map(fn {{_,action},_} -> action end)

    bypass_actions = ExFSM.Machine.event_bypasses(handlers) |> Map.keys()

    rules_actions = handlers |> Enum.map(fn handler ->
      if function_exported?(handler, :rules_graph, 0) do
        handler.rules_graph()
        |> Map.keys()
        |> Enum.filter(fn {s,_} -> s == state_name end)
        |> Enum.map(fn {_, action} -> action end)
      else
        []
      end
    end) |> List.flatten()

    Enum.uniq(classic_actions ++ rules_actions ++ bypass_actions)
  end

  @spec action_available?(State.t(), any(), atom()) :: boolean()
  def action_available?(state, params, action) do
    action in available_actions({state, params})
  end

  def infos(handlers) when is_list(handlers),
    do: handlers |> Enum.map(& &1.docs) |> Enum.concat() |> Enum.into(%{})

  def infos(state, params), do:
    infos(State.handlers(state, params))

  def find_info(state, params, action) do
    docs = infos(state, params)
    if doc = docs[{:transition_doc, State.state_name(state), action}] do
      {:known_transition, doc}
    else
      {:bypass, docs[{:event_doc, action}]}
    end
  end
end
