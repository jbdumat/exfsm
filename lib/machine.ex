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
  def event_bypasses(handlers) when is_list(handlers), do: transition_map(handlers, :event_bypasses)

  @doc """
  Applique un évènement {action, params} sur l’état (résout handler, route bypass/transition).
  """
  def event(state, {action, params}) do
      case find_handlers({state, action, params}) do
        [handler | _] ->
          case apply(handler, State.state_name(state), [{action, params}, state]) do
            {:next_state, state_name, state2, timeout} ->
              {:next_state, State.set_state_name(state2, state_name, to_list(State.handlers(state, params))), timeout}

            {:next_state, state_name, state2} ->
              {:next_state, State.set_state_name(state2, state_name, to_list(State.handlers(state, params)))}

            other ->
              other
          end

        [] ->
          case find_bypasses({state, action, params}) do
            [handler | _] ->
              case apply(handler, action, [params, state]) do
                {:keep_state, state2} ->
                  {:next_state, state2}

                {:next_state, state_name, state2, timeout} ->
                  {:next_state, State.set_state_name(state2, state_name, to_list(State.handlers(state, params))), timeout}

                {:next_state, state_name, state2} ->
                  {:next_state, State.set_state_name(state2, state_name, to_list(State.handlers(state, params)))}

                other ->
                  other
              end

            _ ->
              {:error, :illegal_action}
          end
      end
  end

  # available_actions — both arities for compatibility
  def available_actions({state, params}) do
    handlers = to_list(State.handlers(state, params))

    fsm_actions =
      fsm(handlers)
      |> Enum.filter(fn {{from, _}, _} -> from == State.state_name(state) end)
      |> Enum.map(fn {{_, action}, _} -> action end)

    bypass_actions =
      event_bypasses(handlers)
      |> Map.keys()

    Enum.uniq(fsm_actions ++ bypass_actions)
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
end
