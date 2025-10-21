defmodule ExFSM.V2 do
  @type fsm_spec :: %{
          {state_name :: atom, event_name :: atom} =>
            {exfsm_module :: atom, [dest_statename :: atom]}
        }

  @moduledoc """
  Minimal FSM DSL with optional **processless pipelines**.

  ## Classic transitions

      defmodule Door do
        use ExFSM.V2
        @to [:opened]
        @doc "Close to open"
        deftrans closed({:open, _}, s) do
          {:next_state, :opened, s}
        end
      end

  ## Pipeline mode (processless)

      defmodule OrderFSM do
        use ExFSM.V2

        @doc "Create order: enrich -> client api -> update lines"
        @to [:created] # fallback if output can't be introspected
        deftrans_input init({:create_order, params}, state) do
          @doc "Enrich data"
          deftrans_action init({:enrich_order, p}, s) do
            {:ok, p, s}
          end

          @doc "Call client API"
          deftrans_action init({:call_client_api, p}, s) do
            {:ok, p, s}
          end

          @doc "Update order lines"
          deftrans_action init({:update_order_lines, p}, s) do
            {:ok, p, s}
          end

          @doc "Decide final state"
          deftrans_output(params, state, acc) do
            {:next_state, :created, state}
          end
        end
      end

  Introspection helpers (added by `use ExFSM.V2`):
    * `MyFSM.fsm/0` → %{{state,event} => {handler, [dest_states]}}
    * `MyFSM.pipelines/0` → %{{state,event} => [:step1, :step2, ...]}
    * `MyFSM.pipeline_outputs/0` → %{{state,event} => output_fun_atom}
    * `MyFSM.docs/0` → map of user docs for transitions/actions/output

  Step return conventions:
    * `{:ok, params, state}`
    * `{:error_continue, reason, params, state}`  (trace warning but continue)
    * `{:error, reason, params, state}`           (by default halts pipeline)
  """

  # ---------------------------------------------------------------------------
  # __using__/1 — module attributes & introspection
  # ---------------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      import ExFSM.V2
      @fsm %{}
      @check %{}
      @bypasses %{}
      @docs %{}
      @to nil

      # --- pipeline additions ---
      @pipelines %{}          # %{{state,event} => [:step1, :step2, ...]}
      @pipeline_outputs %{}   # %{{state,event} => output_fun_atom}
      @current_pipeline nil   # {state, event}

      @before_compile ExFSM.V2
    end
  end

  defmacro __before_compile__(env) do
    mod = env.module
    snap = Module.get_attribute(mod, :__exfsm_snapshot__) || %{}

    fsm = Map.get(snap, :fsm)              || (Module.get_attribute(mod, :fsm)              || %{})
    bypasses = Map.get(snap, :bypasses)         || (Module.get_attribute(mod, :bypasses)         || %{})
    docs = Map.get(snap, :docs)             || (Module.get_attribute(mod, :docs)             || %{})
    pipelines = Map.get(snap, :pipelines)        || (Module.get_attribute(mod, :pipelines)        || %{})
    pipeline_outputs = Map.get(snap, :pipeline_outputs) || (Module.get_attribute(mod, :pipeline_outputs) || %{})

    quote do
      def fsm, do: unquote(Macro.escape(fsm))
      def check, do: @check
      def event_bypasses, do: unquote(Macro.escape(bypasses))
      def docs, do: unquote(Macro.escape(docs))
      def pipelines, do: unquote(Macro.escape(pipelines))
      def pipeline_outputs, do: unquote(Macro.escape(pipeline_outputs))
      def match_trans(_, _, _, _), do: false

      def __debug_attrs__ do
        %{
          fsm: fsm(),
          pipelines: pipelines(),
          pipeline_outputs: pipeline_outputs(),
          bypasses: event_bypasses(),
          docs: docs()
        }
      end
    end
  end


  # ---------------------------------------------------------------------------
  # Classic deftrans/2
  # ---------------------------------------------------------------------------

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
      def match_trans(unquote(state), unquote(trans), unquote(ExFSM.V2.silent(obj)), unquote(ExFSM.V2.silent(params))), do: true
      def unquote(signature), do: unquote(body_block[:do])
      @to nil
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline DSL (processless)
  # ---------------------------------------------------------------------------

  @doc """
  Declare the *input* transition (same signature as `deftrans/2`), then inside
  define multiple `deftrans_action/2` and one `deftrans_output/4`.
  """
  defmacro deftrans_input({state, _m, [{event, _p} | _]}, do: block) do
    mod = __CALLER__.module
    Module.put_attribute(mod, :current_pipeline, {state, event})

    pipelines = Module.get_attribute(mod, :pipelines) || %{}
    unless Map.has_key?(pipelines, {state, event}) do
      Module.put_attribute(mod, :pipelines, Map.put(pipelines, {state, event}, []))
    end

    doc  = Module.get_attribute(mod, :doc)
    docs = Module.get_attribute(mod, :docs) || %{}
    Module.put_attribute(mod, :docs, Map.put(docs, {:transition_doc, state, event}, doc))
    Module.delete_attribute(mod, :doc)

    quote do
      unquote(block)
      # reset @current_pipeline dans deftrans_output/4
    end
  end

  @doc """
  Declare an internal *action step* of the current pipeline.
  Must be called inside a `deftrans_input/2` block.
  """
  defmacro deftrans_action({state_ast, _m, [{step_event, _} | _]} = signature, body) do
    mod = __CALLER__.module
    {st, ev} =
      Module.get_attribute(mod, :current_pipeline) ||
        raise "deftrans_action must be inside a deftrans_input block"

    pipelines = Module.get_attribute(mod, :pipelines) || %{}
    steps = Map.get(pipelines, {st, ev}, [])
    Module.put_attribute(mod, :pipelines, Map.put(pipelines, {st, ev}, steps ++ [step_event]))

    doc  = Module.get_attribute(mod, :doc)
    docs = Module.get_attribute(mod, :docs) || %{}
    Module.put_attribute(mod, :docs, Map.put(docs, {:action_doc, st, ev, step_event}, doc))
    Module.delete_attribute(mod, :doc)

    _ = state_ast

    quote do
      def unquote(signature), do: unquote(body[:do])
    end
  end

  @doc """
  Declare the *output* callback of the current pipeline and the wrapper entry function.
  Syntax: `deftrans_output(params, state, acc) do ... end`
  (explicit args for clarity and compile-time safety)
  """
  defmacro deftrans_output(params_ast, state_ast, acc_ast, do: body) do
    mod = __CALLER__.module
    {st, ev} =
      Module.get_attribute(mod, :current_pipeline) ||
        raise "deftrans_output must be inside a deftrans_input block"

    output_fun = String.to_atom("__output__#{st}_#{ev}")

    # --- DOC output
    doc  = Module.get_attribute(mod, :doc)
    docs = Module.get_attribute(mod, :docs) || %{}
    Module.put_attribute(mod, :docs, Map.put(docs, {:output_doc, st, ev}, doc))
    Module.delete_attribute(mod, :doc)

    # --- Destinations (introspection de l'AST du bloc) + fallback @to
    to_attr  = Module.get_attribute(mod, :to)
    inferred =
      case find_nextstates(body) do
        [] -> to_attr || []
        xs -> Enum.uniq(xs)
      end

    # --- Enregistrer dans les attributs
    fsm = Module.get_attribute(mod, :fsm) || %{}
    fsm2 = Map.put(fsm, {st, ev}, {mod, inferred})
    Module.put_attribute(mod, :fsm, fsm2)

    outs = Module.get_attribute(mod, :pipeline_outputs) || %{}
    outs2 = Map.put(outs, {st, ev}, output_fun)
    Module.put_attribute(mod, :pipeline_outputs, outs2)

    pipes = Module.get_attribute(mod, :pipelines) || %{}
    bypasses = Module.get_attribute(mod, :bypasses) || %{}

    # --- SNAPSHOT figé pour __before_compile__
    snapshot = %{
      fsm: fsm2,
      pipelines: pipes,
      pipeline_outputs: outs2,
      docs: Module.get_attribute(mod, :docs) || %{},
      bypasses: bypasses
    }

    Module.put_attribute(mod, :__exfsm_snapshot__, snapshot)

    # reset de quelques attributs
    Module.put_attribute(mod, :to, nil)
    Module.put_attribute(mod, :current_pipeline, nil)

    quote do
      # consommer @to pour éviter le warning "was set but never used"
      _ = @to

      # output(params, state, acc)
      def unquote(output_fun)(unquote(params_ast), unquote(state_ast), unquote(acc_ast)) do
        unquote(body)
      end

      # wrapper d’entrée: exécute la pipeline puis l’output
      def unquote(st)({unquote(ev), params}, state) do
        ExFSM.V2.Pipeline.run(__MODULE__, {unquote(st), unquote(ev)}, params, state)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AST introspection (used by deftrans & deftrans_output)
  # ---------------------------------------------------------------------------

  defp find_nextstates({:{}, _, [:next_state, state | _]}) when is_atom(state), do: [state]
  defp find_nextstates({_, _, asts}), do: find_nextstates(asts)
  defp find_nextstates({_, asts}), do: find_nextstates(asts)
  defp find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts, &find_nextstates/1)
  defp find_nextstates(_), do: []

  # ---------------------------------------------------------------------------
  # Event bypass (unchanged)
  # ---------------------------------------------------------------------------

  defmacro defbypass({event,_meta,[params,obj]}=signature,body_block) do
    quote do
      @bypasses Map.put(@bypasses,unquote(event),__MODULE__)
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs,{:event_doc,unquote(event)},doc)
      def match_bypass(unquote(event), unquote(ExFSM.V2.silent(obj)), unquote(ExFSM.V2.silent(params))), do: true
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
end

# =============================================================================
# Pipeline engine
# =============================================================================

defmodule ExFSM.V2.Pipeline do
  @moduledoc false

  @type step_status :: :ok | :warning | :error
  @type trace_entry :: {step :: atom, status :: :ok | {:error_continue, term} | {:error, term}}

  @doc false
  @spec run(module, {atom, atom}, any, any, keyword) ::
          {:next_state, any}
          | {:next_state, any, non_neg_integer}
          | {:steps_done, any, any, map}
          | {:error, term}
          | any
  def run(mod, {state_name, event}, params, state, opts \\ []) do
    steps_all = Map.get(mod.pipelines(), {state_name, event}, [])

    # ---- compute 'steps' (no guards using `in`, no ambiguous do:)
    steps_opt = Keyword.get(opts, :steps, :all)

    steps =
      cond do
        steps_opt == :all ->
          steps_all

        is_list(steps_opt) ->
          validate_subset!(steps_opt, steps_all)

        match?({:from, _}, steps_opt) ->
          {:from, step} = steps_opt
          if Enum.member?(steps_all, step) do
            Enum.drop_while(steps_all, &(&1 != step))
          else
            raise ArgumentError,
                  "invalid :steps {:from, #{inspect(step)}} not in pipeline #{inspect(steps_all)}"
          end

        match?({:until, _}, steps_opt) ->
          {:until, step} = steps_opt
          if Enum.member?(steps_all, step) do
            Enum.take_while(steps_all, &(&1 != step)) ++ [step]
          else
            raise ArgumentError,
                  "invalid :steps {:until, #{inspect(step)}} not in pipeline #{inspect(steps_all)}"
          end

        match?({:range, _, _}, steps_opt) ->
          {:range, from, until} = steps_opt
          if Enum.member?(steps_all, from) and Enum.member?(steps_all, until) do
            after_from = Enum.drop_while(steps_all, &(&1 != from))
            Enum.take_while(after_from, &(&1 != until)) ++ [until]
          else
            raise ArgumentError,
                  "invalid :steps {:range, #{inspect(from)}, #{inspect(until)}} not in pipeline #{inspect(steps_all)}"
          end

        true ->
          raise ArgumentError, "invalid :steps option: #{inspect(steps_opt)}"
      end

    params_by_step = Keyword.get(opts, :params_by_step, %{})
    mode = Keyword.get(opts, :mode, :full)
    on_error = Keyword.get(opts, :on_error, :halt)

    base_acc = %{
      status: :ok,
      steps: [],
      meta: %{
        handler: mod,
        transition: {state_name, event},
        at: System.system_time(:millisecond)
      }
    }

    case mode do
      :dry_run ->
        acc = %{base_acc | steps: Enum.map(steps, &{&1, :dry_run})}
        return_steps_result(mod, {state_name, event}, :dry_run, params, state, acc)

      _ ->
        {params, state, acc} =
          Enum.reduce_while(steps, {params, state, base_acc}, fn step, {p, s, a} ->
            p_step = Map.get(params_by_step, step, p)

            case apply(mod, state_name, [{step, p_step}, s]) do
              {:ok, p2, s2} ->
                {:cont, {p2, s2, put_step(a, step, :ok)}}

              {:error_continue, reason, p2, s2} ->
                {:cont, {p2, s2, put_step(a, step, {:error_continue, reason}) |> warn!()}}

              {:error, reason, p2, s2} ->
                a2 = put_step(a, step, {:error, reason}) |> error!()
                if on_error == :continue, do: {:cont, {p2, s2, a2}}, else: {:halt, {p2, s2, a2}}

              other ->
                raise ArgumentError,
                      "step #{inspect(step)} returned invalid value: #{inspect(other)}"
            end
          end)

        return_steps_result(mod, {state_name, event}, mode, params, state, acc)
    end
  end

  # --------- helpers ---------

  defp return_steps_result(_mod, _key, :steps_only, params, state, acc),
    do: {:steps_done, params, state, acc}

  defp return_steps_result(_mod, _key, :dry_run, params, state, acc),
    do: {:steps_done, params, state, acc}

  defp return_steps_result(mod, {st, ev}, :full, params, state, acc) do
    out_fun =
      Map.get(mod.pipeline_outputs(), {st, ev}) ||
        String.to_atom("__output__#{st}_#{ev}")

    apply(mod, out_fun, [params, state, acc])
  end

  defp validate_subset!(list, steps_all) do
    invalid = list -- steps_all
    if (invalid != []), do: raise(ArgumentError, "invalid steps: #{inspect(invalid)}")
    wanted = MapSet.new(list)
    # keep execution order of pipeline, not user-supplied order
    Enum.filter(steps_all, &MapSet.member?(wanted, &1))
  end

  defp put_step(acc, step, tag), do: %{acc | steps: acc.steps ++ [{step, tag}]}
  defp warn!(acc), do: %{acc | status: (acc.status == :error && :error) || :warning}
  defp error!(acc), do: %{acc | status: :error}
end

# =============================================================================
# Machine (glue)
# =============================================================================

defmodule ExFSM.V2.Machine do
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

  @doc "return the FSM as a map of transitions %{{state,action}=>{handler,[dest_states]}} based on handlers"
  # Enum.into can remove same deftrans between modules -> change to a group_by
  @spec fsm([exfsm_module :: atom]) :: ExFSM.V2.fsm_spec
  def fsm(handlers) when is_list(handlers), do: transition_map(handlers, :fsm)
  def event_bypasses(handlers) when is_list(handlers), do: transition_map(handlers, :event_bypasses)
  def transition_map(handlers, method), do:
    (handlers |> Enum.map(&(apply(&1, method, []))) |> Enum.concat |> Enum.group_by(fn {k, _} -> k end, fn {_, v} -> v end))

  @doc "find the ExFSM.V2 Module from the list `handlers` implementing the event `action` from `state_name`"
  @spec find_handlers({state_name::atom,event_name::atom},[exfsm_module :: atom]) :: exfsm_module :: atom | nil
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
  @doc """
  Apply a transition using the handler resolved from the state's handlers.
  """
  @type meta_event_reply :: {:next_state,ExFSM.V2.Machine.State.t} | {:next_state,ExFSM.V2.Machine.State.t,timeout :: integer} | {:error,:illegal_action}
  @spec event(ExFSM.V2.Machine.State.t,{event_name :: atom, event_params :: any}) :: meta_event_reply
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
    fsm_actions = ExFSM.V2.Machine.fsm(handlers)
      |> Enum.filter(fn {{from, _}, _} -> from == State.state_name(state) end)
      |> Enum.map(fn {{_, action}, _} -> action end)
    bypasses_actions = ExFSM.V2.Machine.event_bypasses(handlers) |> Map.keys
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

  # ---------------------------------------------------------------------------
  # Replay / Planning
  # ---------------------------------------------------------------------------

  @doc """
  Rejoue une transition précise `{state_name, event}` avec options:
    - :steps -> :all | [:step] | {:from, s} | {:until, s} | {:range, s1, s2}
    - :mode  -> :full | :steps_only | :dry_run
    - :params -> base params
    - :params_by_step -> %{step => params_override}
    - :on_error -> :halt | :continue
  """
  @spec retry(any, atom, keyword) ::
          {:steps_done, any, any, map}
          | {:next_state, any}
          | {:next_state, any, non_neg_integer}
          | {:error, :illegal_action | {:invalid_steps, [atom]}}
  def retry(state, event, opts \\ []) do
    handlers = State.handlers(state)
    state_name = State.state_name()

    case find_handlers({state_name, event}, handlers) do
      [handler | _] ->
        steps_all = handler.pipelines()[{state_name, event}] || []

        with :ok <- validate_steps_opt(Keyword.get(opts, :steps, :all), steps_all) do
          params = Keyword.get(opts, :params, %{})
          ExFSM.V2.Pipeline.run(handler, {state_name, event}, params, state, opts)
        else
          {:error, invalid} -> {:error, {:invalid_steps, invalid}}
        end

      _ ->
        {:error, :illegal_action}
    end
  end

  defp validate_steps_opt(:all, _), do: :ok

  defp validate_steps_opt(list, steps_all) when is_list(list) do
    invalid = list -- steps_all
    if invalid == [], do: :ok, else: {:error, invalid}
  end

  defp validate_steps_opt({:from, s}, steps_all) do
    if Enum.member?(steps_all, s), do: :ok, else: {:error, [{:from, s}]}
  end

  defp validate_steps_opt({:until, s}, steps_all) do
    if Enum.member?(steps_all, s), do: :ok, else: {:error, [{:until, s}]}
  end

  defp validate_steps_opt({:range, a, b}, steps_all) do
    cond do
      Enum.member?(steps_all, a) and Enum.member?(steps_all, b) -> :ok
      true -> {:error, [{:range, a, b}]}
    end
  end

  defp validate_steps_opt(other, _), do: {:error, [other]}

  @doc """
  Steps restants (non-:ok) pour `{state_name, event}` d'un `state`.
  Si le handler a changé entre `acc` et l'état courant, renvoie
  `{:handler_changed, current, expected, steps}`.
  """
  @spec remaining_steps(any, atom, map | nil) ::
          {:ok, [atom]} | {:handler_changed, module, module, [atom]} | {:error, :illegal_action}
  def remaining_steps(state, event, acc \\ nil) do
    handlers = State.handlers(state)
    state_name = State.state_name()

    case find_handlers({state_name, event}, handlers) do
      [handler | _] ->
        steps = handler.pipelines()[{state_name, event}] || []

        case acc do
          %{meta: %{handler: expected}} when expected != handler ->
            {:handler_changed, handler, expected, steps}

          %{steps: trace} ->
            done = for {step, :ok} <- trace, do: step
            {:ok, Enum.reject(steps, &(&1 in done))}

          _ ->
            {:ok, steps}
        end

        _ ->
        {:error, :illegal_action}
    end
  end

  @doc """
  Plan de rejeu = steps restants + handler + transition.
  """
  @spec replay_plan(any, atom, map | nil) ::
          {:ok, %{steps: [atom], handler: module, transition: {atom, atom}}}
          | {:handler_changed, module, module, [atom]}
          | {:error, :illegal_action}
  def replay_plan(state, event, acc \\ nil) do
    state_name = State.state_name()
    case remaining_steps(state, {state_name, event}, acc) do
      {:ok, steps} ->
        {:ok,
         %{
           steps: steps,
           handler: find_handlers({state_name, event}, State.handlers(state)),
           transition: {state_name, event}
         }}

      other ->
        other
    end
  end
end
