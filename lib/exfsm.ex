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

    fsm              = Map.get(snap, :fsm)              || (Module.get_attribute(mod, :fsm)              || %{})
    bypasses         = Map.get(snap, :bypasses)         || (Module.get_attribute(mod, :bypasses)         || %{})
    docs             = Map.get(snap, :docs)             || (Module.get_attribute(mod, :docs)             || %{})
    pipelines        = Map.get(snap, :pipelines)        || (Module.get_attribute(mod, :pipelines)        || %{})
    pipeline_outputs = Map.get(snap, :pipeline_outputs) || (Module.get_attribute(mod, :pipeline_outputs) || %{})

    quote do
      def fsm,              do: unquote(Macro.escape(fsm))
      def event_bypasses,   do: unquote(Macro.escape(bypasses))
      def docs,             do: unquote(Macro.escape(docs))
      def pipelines,        do: unquote(Macro.escape(pipelines))
      def pipeline_outputs, do: unquote(Macro.escape(pipeline_outputs))

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
  Define a function of type `transition` describing a state and its transition.
  The function name is the state name, the transition is the first argument. A
  state object can be modified and is the second argument.

      deftrans opened({:close_door,_params},state) do
        {:next_state,:closed,state}
      end
  """
  @type transition :: ({event_name :: atom, event_param :: any}, state :: any ->
                         {:next_state, event_name :: atom, state :: any})
  defmacro deftrans({state, _meta, [{trans, _param} | _rest]} = signature, body_block) do
    quote do
      @fsm Map.put(
             @fsm,
             {unquote(state), unquote(trans)},
             {__MODULE__, @to || unquote(Enum.uniq(find_nextstates(body_block[:do])))}
           )
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs, {:transition_doc, unquote(state), unquote(trans)}, doc)
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

  defmacro defbypass({event, _meta, _args} = signature, body_block) do
    quote do
      @bypasses Map.put(@bypasses, unquote(event), __MODULE__)
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs, {:event_doc, unquote(event)}, doc)
      Module.delete_attribute(__MODULE__, :doc)
      def unquote(signature), do: unquote(body_block[:do])
    end
  end
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
  Glue layer to use FSMs defined with ExFSM.V2.
  """

  defprotocol State do
    @doc "retrieve current state handlers from state object, return [Handler1,Handler2]"
    def handlers(state)
    @doc "retrieve current state name from state object"
    def state_name(state)
    @doc "set new state name"
    def set_state_name(state, state_name)
  end

  @doc "return the FSM as a map of transitions %{{state,action}=>{handler,[dest_states]}} based on handlers"
  @spec fsm([exfsm_module :: atom]) :: ExFSM.V2.fsm_spec()
  def fsm(handlers) when is_list(handlers),
    do: handlers |> Enum.map(& &1.fsm()) |> Enum.concat() |> Enum.into(%{})

  def fsm(state), do: fsm(State.handlers(state))

  def event_bypasses(handlers) when is_list(handlers),
    do: handlers |> Enum.map(& &1.event_bypasses()) |> Enum.concat() |> Enum.into(%{})

  def event_bypasses(state), do: event_bypasses(State.handlers(state))

  @doc "find the ExFSM.V2 Module from the list `handlers` implementing the event `action` from `state_name`"
  @spec find_handler({state_name :: atom, event_name :: atom}, [exfsm_module :: atom]) ::
          exfsm_module :: atom | nil
  def find_handler({state_name, action}, handlers) when is_list(handlers) do
    case Map.get(fsm(handlers), {state_name, action}) do
      {handler, _} -> handler
      _ -> nil
    end
  end

  @doc "same as `find_handler/2` but using a 'meta' state implementing `ExFSM.V2.Machine.State`"
  def find_handler({state, action}),
    do: find_handler({State.state_name(state), action}, State.handlers(state))

  def find_bypass(handlers_or_state, action) do
    event_bypasses(handlers_or_state)[action]
  end

  def infos(handlers, _action) when is_list(handlers) do
    handlers |> Enum.map(& &1.docs()) |> Enum.concat() |> Enum.into(%{})
  end

  def infos(state, action), do: infos(State.handlers(state), action)

  def find_info(state, action) do
    docs = infos(state, action)

    if doc = docs[{:transition_doc, State.state_name(state), action}] do
      {:known_transition, doc}
    else
      {:bypass, docs[{:event_doc, action}]}
    end
  end

  @doc """
  Apply a transition using the handler resolved from the state's handlers.
  """
  @type meta_event_reply ::
          {:next_state, ExFSM.V2.Machine.State.t()}
          | {:next_state, ExFSM.V2.Machine.State.t(), timeout :: integer}
          | {:error, :illegal_action}
  @spec event(ExFSM.V2.Machine.State.t(), {event_name :: atom, event_params :: any}) ::
          meta_event_reply
  def event(state, {action, params}) do
    case find_handler({state, action}) do
      nil ->
        case find_bypass(state, action) do
          nil ->
            {:error, :illegal_action}

          handler ->
            case apply(handler, action, [params, state]) do
              {:keep_state, state} ->
                {:next_state, state}

              {:next_state, state_name, state, timeout} ->
                {:next_state, State.set_state_name(state, state_name), timeout}

              {:next_state, state_name, state} ->
                {:next_state, State.set_state_name(state, state_name)}

              other ->
                other
            end
        end

      handler ->
        case apply(handler, State.state_name(state), [{action, params}, state]) do
          {:next_state, state_name, state, timeout} ->
            {:next_state, State.set_state_name(state, state_name), timeout}

          {:next_state, state_name, state} ->
            {:next_state, State.set_state_name(state, state_name)}

          other ->
            other
        end
    end
  end

  @spec available_actions(ExFSM.V2.Machine.State.t()) :: [action_name :: atom]
  def available_actions(state) do
    fsm_actions =
      ExFSM.V2.Machine.fsm(state)
      |> Enum.filter(fn {{from, _}, _} -> from == State.state_name(state) end)
      |> Enum.map(fn {{_, action}, _} -> action end)

    bypasses_actions = ExFSM.V2.Machine.event_bypasses(state) |> Map.keys()
    Enum.uniq(fsm_actions ++ bypasses_actions)
  end

  @spec action_available?(ExFSM.V2.Machine.State.t(), action_name :: atom) :: boolean
  def action_available?(state, action) do
    action in available_actions(state)
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

    case find_handler({state_name, event}, handlers) do
      nil ->
        {:error, :illegal_action}

      mod ->
        steps_all = mod.pipelines()[{state_name, event}] || []

        with :ok <- validate_steps_opt(Keyword.get(opts, :steps, :all), steps_all) do
          params = Keyword.get(opts, :params, %{})
          ExFSM.V2.Pipeline.run(mod, {state_name, event}, params, state, opts)
        else
          {:error, invalid} -> {:error, {:invalid_steps, invalid}}
        end
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

    case find_handler({state_name, event}, handlers) do
      nil ->
        {:error, :illegal_action}

      mod ->
        steps = mod.pipelines()[{state_name, event}] || []

        case acc do
          %{meta: %{handler: expected}} when expected != mod ->
            {:handler_changed, mod, expected, steps}

          %{steps: trace} ->
            done = for {step, :ok} <- trace, do: step
            {:ok, Enum.reject(steps, &(&1 in done))}

          _ ->
            {:ok, steps}
        end
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
           handler: find_handler({state_name, event}, State.handlers(state)),
           transition: {state_name, event}
         }}

      other ->
        other
    end
  end
end
