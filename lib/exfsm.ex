defmodule ExFSM do
  @type fsm_spec :: %{{state_name :: atom, event_name :: atom} => {exfsm_module :: atom,[dest_statename :: atom]}}
  @moduledoc """
  After `use ExFSM` : define FSM transition handler with `deftrans fromstate({action_name,params},state)`.
  A function `fsm` will be created returning a map of the `fsm_spec` describing the fsm.

  Destination states are found with AST introspection, if the `{:next_state,xxx,xxx}` is defined
  outside the `deftrans/2` function, you have to define them manually defining a `@to` attribute.

  For instance :

    iex> defmodule Elixir.Door do
    ...>   use ExFSM
    ...>
    ...>   @doc "Close to open"
    ...>   @to [:opened]
    ...>   deftrans closed({:open, _}, s) do
    ...>     {:next_state, :opened, s}
    ...>   end
    ...>
    ...>   @doc "Close to close"
    ...>   deftrans closed({:close, _}, s) do
    ...>     {:next_state, :closed, s}
    ...>   end
    ...>
    ...>   deftrans closed({:else, _}, s) do
    ...>     {:next_state, :closed, s}
    ...>   end
    ...>
    ...>   @doc "Open to open"
    ...>   deftrans opened({:open, _}, s) do
    ...>     {:next_state, :opened, s}
    ...>   end
    ...>
    ...>   @doc "Open to close"
    ...>   @to [:closed]
    ...>   deftrans opened({:close, _}, s) do
    ...>     {:next_state, :closed, s}
    ...>   end
    ...>
    ...>   deftrans opened({:else, _}, s) do
    ...>     {:next_state, :opened, s}
    ...>   end
    ...> end
    ...> Door.fsm
    %{{:closed, :close} => {Door, [:closed]}, {:closed, :else} => {Door, [:closed]},
      {:closed, :open} => {Door, [:opened]}, {:opened, :close} => {Door, [:closed]},
      {:opened, :else} => {Door, [:opened]}, {:opened, :open} => {Door, [:opened]}}
    iex> Door.docs
    %{{:transition_doc, :closed, :close} => "Close to close",
      {:transition_doc, :closed, :else} => nil,
      {:transition_doc, :closed, :open} => "Close to open",
      {:transition_doc, :opened, :close} => "Open to close",
      {:transition_doc, :opened, :else} => nil,
      {:transition_doc, :opened, :open} => "Open to open"}
  """

  defmacro __using__(_opts) do
    quote do
      import ExFSM
      @fsm %{}
      @check %{}
      @bypasses %{}
      @docs %{}
      @to nil
      @before_compile ExFSM
    end
  end
  defmacro __before_compile__(_env) do
    quote do
      def fsm, do: @fsm
      def check, do: @check
      def event_bypasses, do: @bypasses
      def docs, do: @docs
      def match_trans(_, _, _, _), do: false
    end
  end

  @doc """
    Define a function of type `transition` describing a state and its
    transition. The function name is the state name, the transition is the
    first argument. A state object can be modified and is the second argument.

        deftrans opened({:close_door,_params},state) do
          {:next_state,:closed,state}
        end
  """
  @type transition :: (({event_name :: atom, event_param :: any},state :: any) -> {:next_state,event_name :: atom,state :: any})
  defmacro deftrans({state,_meta,[{trans,params},obj|_]}=signature, body_block) do
    quote do
      @fsm Map.put(@fsm,{unquote(state),unquote(trans)},{__MODULE__, @to || unquote(Enum.uniq(find_nextstates(body_block[:do])))})
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs,{:transition_doc,unquote(state),unquote(trans)},doc)
      def match_trans(unquote(state), unquote(trans), unquote(ExFSM.silent(obj)), unquote(ExFSM.silent(params))), do: true
      def unquote(signature), do: unquote(body_block[:do])
      @to nil
    end
  end

  defmacro defbypass({event,_meta,[params,obj]}=signature,body_block) do
    quote do
      @bypasses Map.put(@bypasses,unquote(event),__MODULE__)
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs,{:event_doc,unquote(event)},doc)
      def match_bypass(unquote(event), unquote(ExFSM.silent(obj)), unquote(ExFSM.silent(params))), do: true
      def unquote(signature), do: unquote(body_block[:do])
    end
  end


  def silent({t, {_, _, _} = a}), do: {t, silent(a)}
  def silent({t, a}) when is_tuple(a), do: {t, List.to_tuple(silent(Tuple.to_list(a)))}
  def silent({a, m, p}) when is_atom(a) do
    case Atom.to_charlist(a) do
      [c | _] = charlist when c in ?a..?z -> {String.to_atom("_" <> "#{charlist}"), m, silent(p)}
      _ -> {a, m, silent(p)}
    end
  end
  def silent({a, m, p}), do: {a, m, silent(p)}
  def silent(list) when is_list(list), do: Enum.map(list, &silent/1)
  def silent(v), do: v

  defp find_nextstates({:{},_,[:next_state,state|_]}) when is_atom(state), do: [state]
  defp find_nextstates({_,_,asts}), do: find_nextstates(asts)
  defp find_nextstates({_,asts}), do: find_nextstates(asts)
  defp find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts,&find_nextstates/1)
  defp find_nextstates(_), do: []
end

defmodule ExFSM.Machine do
  @moduledoc """
  Module to simply use FSMs defined with ExFSM :

  - `ExFSM.Machine.fsm/1` merge fsm from multiple handlers (see `ExFSM` to see how to define one).
  - `ExFSM.Machine.event_bypasses/1` merge bypasses from multiple handlers (see `ExFSM` to see how to define one).
  - `ExFSM.Machine.event/2` allows you to execute the correct handler from a state and action

  Define a structure implementing `ExFSM.Machine.State` in order to
  define how to extract handlers and state_name from state, and how
  to apply state_name change. Then use `ExFSM.Machine.event/2` in order
  to execute transition.

      iex> defmodule Elixir.Door1 do
      ...>   use ExFSM
      ...>   deftrans closed({:open_door,_},s) do {:next_state,:opened,s} end
      ...> end
      ...> defmodule Elixir.Door2 do
      ...>   use ExFSM
      ...>   @doc "allow multiple closes"
      ...>   defbypass close_door(_,s), do: {:keep_state,Map.put(s,:doubleclosed,true)}
      ...>   @doc "standard door open"
      ...>   deftrans opened({:close_door,_},s) do {:next_state,:closed,s} end
      ...> end
      ...> ExFSM.Machine.fsm([Door1,Door2])
      %{
        {:closed,:open_door}=>{Door1,[:opened]},
        {:opened,:close_door}=>{Door2,[:closed]}
      }
      iex> ExFSM.Machine.event_bypasses([Door1,Door2])
      %{close_door: Door2}
      iex> defmodule Elixir.DoorState do defstruct(handlers: [Door1,Door2], state: nil, doubleclosed: false) end
      ...> defimpl ExFSM.Machine.State, for: DoorState do
      ...>   def handlers(d) do d.handlers end
      ...>   def state_name(d) do d.state end
      ...>   def set_state_name(d,name) do %{d|state: name} end
      ...> end
      ...> struct(DoorState, state: :closed) |> ExFSM.Machine.event({:open_door,nil})
      {:next_state,%{__struct__: DoorState, handlers: [Door1,Door2],state: :opened, doubleclosed: false}}
      ...> struct(DoorState, state: :closed) |> ExFSM.Machine.event({:close_door,nil})
      {:next_state,%{__struct__: DoorState, handlers: [Door1,Door2],state: :closed, doubleclosed: true}}
      iex> ExFSM.Machine.find_info(struct(DoorState, state: :opened),:close_door)
      {:known_transition,"standard door open"}
      iex> ExFSM.Machine.find_info(struct(DoorState, state: :closed),:close_door)
      {:bypass,"allow multiple closes"}
      iex> ExFSM.Machine.available_actions(struct(DoorState, state: :closed))
      [:open_door,:close_door]
  """

  defprotocol State do
    @doc "retrieve current state handlers from state object, return [Handler1,Handler2]"
    def handlers(state, params)
    @doc "retrieve current state name from state object"
    def state_name(state)
    @doc "set new state name"
    def set_state_name(state, state_name, possible_handlers)
  end

  @doc "return the FSM as a map of transitions %{{state,action}=>{handler,[dest_states]}} based on handlers"
  # Enum.into can remove same deftrans between modules -> change to a group_by
  @spec fsm([exfsm_module :: atom]) :: ExFSM.fsm_spec
  def fsm(handlers) when is_list(handlers), do: transition_map(handlers, :fsm)
  def event_bypasses(handlers) when is_list(handlers), do: transition_map(handlers, :event_bypasses)
  def transition_map(handlers, method), do:
    (handlers |> Enum.map(&(apply(&1, method, []))) |> Enum.concat |> Enum.group_by(fn {k, _} -> k end, fn {_, v} -> v end))

  @doc "find the ExFSM Module from the list `handlers` implementing the event `action` from `state_name`"
  @spec find_handlers({state_name::atom,event_name::atom},[exfsm_module :: atom]) :: exfsm_module :: atom
  def find_handlers({state_name, action}, handlers) when is_list(handlers) do
    case Map.get(fsm(handlers), {state_name, action}) do
      list when is_list(list) -> Enum.map(list, fn {handler, _} -> handler end)
      _ -> []
    end
  end
  @doc "same as `find_handlers/2` but using a 'meta' state implementing `ExFSM.Machine.State` and filter if a 'match_trans' is available"
  def find_handlers({state, action, params}) do
    state_name = State.state_name(state)
    case find_handlers({state_name, action}, State.handlers(state, params)) do
      list when is_list(list) ->
        Enum.filter(list, fn handler -> handler.match_trans(state_name, action, state, params) end)
      _ ->
        nil
    end
  end

  def find_bypasses(action, handlers) when is_list(handlers) do
    case Map.get(event_bypasses(handlers), action) do
      list when is_map(list) -> Enum.map(list, fn {handler, _} -> handler end)
      list when is_list(list) -> list
      _ -> nil
    end
  end

  def find_bypasses({state, action, params}) do
    case find_bypasses(action, State.handlers(state, params)) do
      list when is_list(list) ->
        Enum.filter(list, fn handler -> handler.match_bypass(action, state, params) end)
      _ ->
        nil
    end
  end

  def infos(handlers, _action) when is_list(handlers), do:
    (handlers |> Enum.map(&(&1.docs)) |> Enum.concat |> Enum.into(%{}))
  def infos(state, params, action), do:
    infos(State.handlers(state, params), action)

  def find_info(state, params, action) do
    docs = infos(state, params, action)
    if doc = docs[{:transition_doc, State.state_name(state), action}] do
      {:known_transition, doc}
    else
      {:bypass, docs[{:event_doc, action}]}
    end
  end

  # ExFSM.Machine.event(obj, {:create, "exx"})
  # ExFSM.Machine.find_handler({obj, :create})
  @doc "Meta application of the transition function, using `find_handler/2` to find the module implementing it."
  @type meta_event_reply :: {:next_state,ExFSM.Machine.State.t} | {:next_state,ExFSM.Machine.State.t,timeout :: integer} | {:error,:illegal_action}
  @spec event(ExFSM.Machine.State.t,{event_name :: atom, event_params :: any}) :: meta_event_reply
  def event(state, {action, params}) do
    case find_handlers({state, action, params}) do
      [handler | _] ->
        case apply(handler, State.state_name(state), [{action, params}, state]) do
          {:next_state, state_name, state, timeout} -> {:next_state, State.set_state_name(state, state_name, State.handlers(state, params)), timeout}
          {:next_state, state_name, state} -> {:next_state, State.set_state_name(state, state_name, State.handlers(state, params))}
          other -> other
        end
      _ ->
        case find_bypasses({state, action, params}) do
          [handler | _]->
            case apply(handler, action, [params, state]) do
              {:keep_state, state} -> {:next_state, state}
              {:next_state, state_name, state,timeout} -> {:next_state, State.set_state_name(state, state_name, State.handlers(state, params)), timeout}
              {:next_state, state_name, state} -> {:next_state, State.set_state_name(state, state_name, State.handlers(state, params))}
              other -> other
            end
          _ ->
            {:error, :illegal_action}
        end
    end
  end

  def available_actions({state, params}) do
    handlers = State.handlers(state, params)
    fsm_actions = ExFSM.Machine.fsm(handlers)
      |> Enum.filter(fn {{from, _}, _} -> from == State.state_name(state) end)
      |> Enum.map(fn {{_, action}, _} -> action end)
    bypasses_actions = ExFSM.Machine.event_bypasses(handlers) |> Map.keys
    Enum.uniq(fsm_actions ++ bypasses_actions)
  end
  # @spec available_actions(ExFSM.Machine.State.t) :: [action_name :: atom]
  # def available_actions(state) do
  #   fsm_actions = ExFSM.Machine.fsm(state)
  #     |> Enum.filter(fn {{from, _}, _} -> from == State.state_name(state) end)
  #     |> Enum.map(fn {{_, action}, _} -> action end)
  #   bypasses_actions = ExFSM.Machine.event_bypasses(state) |> Map.keys
  #   Enum.uniq(fsm_actions ++ bypasses_actions)
  # end

  #@spec action_available?(ExFSM.Machine.State.t,action_name :: atom) :: boolean
  # def action_available?(state, action) do
  #   action in available_actions(state)
  # end
  def action_available?(state, params, action) do
    action in available_actions({state, params})
  end
end
