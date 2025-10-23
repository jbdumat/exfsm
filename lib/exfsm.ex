defmodule ExFSM do
  @moduledoc """
  DSL de FSM basé sur *rules* (graphes conditionnels).
  Transitions déclarées avec `deftrans_rules/2` puis règles avec `defrule/2`,
  et clôture par `defrules_commit/1` + `defrules_exit/4`.

  Introspection:
    * rules_graph/0     -> %{{state,event} => %{entry:, graph:, weights: %{rule=>weight}}}
    * rules_outputs/0   -> %{{state,event} => exit_fun_atom}
    * fsm/0             -> %{{state,event} => {__MODULE__, to_states}}
    * event_bypasses/0  -> %{event => __MODULE__}

  """

  # ------------------------------- __using__ ----------------------------------
  defmacro __using__(_opts) do
    quote do
      import ExFSM

      @fsm %{}
      @docs %{}
      @bypasses %{}
      @to nil               # dests de fallback pour fsm/0

      # Rules
      @rules_graph %{}      # %{{state,event} => %{entry:, graph: %{rule => %{links: [...] }}, weights: %{rule=>weight}}}
      @rules_outputs %{}    # %{{state,event} => :__rules_exit__...}
      @current_ruleset nil  # {state,event}
      @entry_rule nil       # override possible dans un bloc
      @weights %{}          # weights optionnels par règle

      @before_compile ExFSM
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def fsm, do: @fsm || %{}
      def docs, do: @docs || %{}
      def event_bypasses, do: @bypasses || %{}
      def rules_graph, do: @rules_graph || %{}
      def rules_outputs, do: @rules_outputs || %{}
    end
  end

  # ------------- helpers visibles depuis les modules utilisateurs -------------
  def next_rule({rule, params}), do: {:__next__, {rule, params}}
  def rules_exit(exit), do: {:__exit__, exit}
  def dbg(mod, tag, attr) do
    IO.inspect(Module.get_attribute(mod, attr), label: "#{tag}")
  end

  # ---------------------------------------------------------------------------
  # Classic deftrans / defbypass
  # ---------------------------------------------------------------------------

  @type transition ::
          ({event_name :: atom, event_param :: any}, state :: any ->
             {:next_state, event_name :: atom, state :: any}
           | {:next_state, event_name :: atom, state :: any, non_neg_integer}
           | {:keep_state, state :: any}
           | {:error, term})

  defmacro deftrans({state, _m, [{event, _param} | _]} = signature, body_block) do
    quote do
      @fsm Map.put(
             @fsm || %{},
             {unquote(state), unquote(event)},
             {__MODULE__, @to || unquote(Enum.uniq(ExFSM.find_nextstates(body_block[:do])))}
           )

      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs || %{}, {:transition_doc, unquote(state), unquote(event)}, doc)
      def unquote(signature), do: unquote(body_block[:do])
      @to nil
    end
  end

  defmacro defbypass({event, _m, [_params, _obj]} = signature, body) do
    quote do
      @bypasses Map.put(@bypasses || %{}, unquote(event), __MODULE__)
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs || %{}, {:event_doc, unquote(event)}, doc)
      def unquote(signature), do: unquote(body[:do])
    end
  end

  # ------------------------- rules: entrée de transition ----------------------
  @doc """
  Déclare une transition (état + évènement) contrôlée par un graphe de règles.
  À l’intérieur : `defrule/2` pour chaque nœud, `defrules_commit/1`, `defrules_exit/4`.
  """
  defmacro deftrans_rules({state_ast, _m, [{event_ast, _} | _]} = _sig, do: block) do
    mod = __CALLER__.module
    # mark the active ruleset for the block
    Module.put_attribute(mod, :current_ruleset, {state_ast, event_ast})

    # ensure we have a rules_graph entry to mutate from defrule/2
    rg = Module.get_attribute(mod, :rules_graph) || %{}
    Module.put_attribute(mod, :rules_graph, Map.put_new(rg, {state_ast, event_ast}, %{entry: nil, graph: %{}, weights: %{}}))

    quote do
      unquote(block)
      # do NOT reset @current_ruleset here — defrules_exit/3 still needs it
    end
  end

  # ------------------------------- defrule/2 ----------------------------------
  @doc """
  Déclare un nœud de rule (`def rule_name(params) do ... end`).
  Le corps doit retourner `next_rule({...})` ou `rules_exit(...)`.
  """
  defmacro defrule({rule_name, _ctx, _args_ast} = sig, do: body) do
    mod = __CALLER__.module
    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrule must be inside deftrans_rules")

    # find outgoing edges from the rule body
    nexts = ExFSM.find_next_rules(body)

    # mutate the rules_graph *now* so defrules_commit can see it
    rules_graph = Module.get_attribute(mod, :rules_graph) || %{}
    ruleset = Map.get(rules_graph, {st, ev}, %{entry: nil, graph: %{}, weights: %{}})
    graph = Map.put(ruleset.graph || %{}, rule_name, %{next: nexts})
    rules_graph2 = Map.put(rules_graph, {st, ev}, %{ruleset | graph: graph})
    Module.put_attribute(mod, :rules_graph, rules_graph2)

    quote do
      def unquote(sig), do: unquote(body)
    end
  end

  # --------------------------- defrules_commit/1 ------------------------------
  @doc """
  Clôt le bloc de rules : calcule le point d'entrée si absent, finalise le graphe,
  et **persiste** @rules_graph dans le module (comme on le fait pour @fsm/@rules_outputs).

  Usage:
    defrules_commit(entry: :validate, weights: %{reserve: 10})
  """
  defmacro defrules_commit(opts \\ []) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrules_commit must be inside deftrans_rules")

    # snapshot des constructions faites par defrule/2
    rules_graph = Module.get_attribute(mod, :rules_graph) || %{}
    %{entry: entry0, graph: graph0, weights: weights0} =
      Map.get(rules_graph, {st, ev}, %{entry: nil, graph: %{}, weights: %{}})

    user_entry   = Keyword.get(opts, :entry)
    user_weights = Keyword.get(opts, :weights, weights0 || %{})

    entry =
      case (user_entry || entry0) do
        nil -> ExFSM.RuleEngine.infer_entry_rule(graph0)
        e   -> e
      end

    if entry == nil do
      raise ArgumentError,
            "No entry rule for #{inspect({st, ev})}. " <>
            "Set @entry_rule or ensure a 'start' node (no predecessors)."
    end

    # On **persiste** maintenant dans le module via une assignation *dans le quote*.
    # On escape le graphe pour l’injecter dans l’AST.
    quote do
      @rules_graph Map.put(
        @rules_graph || %{},
        {unquote(st), unquote(ev)},
        %{
          entry:   unquote(entry),
          graph:   unquote(Macro.escape(graph0)),
          weights: unquote(Macro.escape(user_weights))
        }
      )
      # On ne reset PAS @current_ruleset ici (defrules_exit va s’en servir).
      :ok
    end
  end

  # ---------------------------- defrules_exit/4 --------------------------------
  @doc """
  Épilogue runtime: traduit `acc.exit` en `{:next_state, ...}`.
  Définit aussi le wrapper de transition qui exécute le RuleEngine.
  """
  defmacro defrules_exit(params_ast, state_ast, acc_ast, do: body_ast) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrules_exit must be inside deftrans_rules")

    out_fun = String.to_atom("__rules_exit__#{st}_#{ev}")

    quote do
      # Make the exit function visible to RuleEngine
      @rules_outputs Map.put(@rules_outputs || %{}, {unquote(st), unquote(ev)}, unquote(out_fun))
      # Register this transition in the FSM (fallback @to is honored)
      @fsm Map.put(@fsm || %{}, {unquote(st), unquote(ev)}, {__MODULE__, @to || []})

      # Reset markers for the next block
      @current_ruleset nil
      @to nil
      @entry_rule nil
      @weights %{}

      def unquote(out_fun)(unquote(params_ast), unquote(state_ast), unquote(acc_ast)) do
        unquote(body_ast)
      end

      def unquote(st)({unquote(ev), params}, state) do
        ExFSM.RuleEngine.run(__MODULE__, {unquote(st), unquote(ev)}, params, state)
      end
    end
  end

  # ---------------------------- AST helpers (public) ---------------------------
  # Collect next_rule(...) calls from a rule body
  def find_next_rules({:next_rule, _, [tuple]}) when is_tuple(tuple) do
    case tuple do
      {name, _} when is_atom(name) -> [name]
      _ -> []
    end
  end
  def find_next_rules({_, _, args}) when is_list(args), do: Enum.flat_map(args, &find_next_rules/1)
  def find_next_rules(list) when is_list(list), do: Enum.flat_map(list, &find_next_rules/1)
  def find_next_rules(_), do: []

   # Classic introspection
  def find_nextstates({:{}, _, [:next_state, state | _]}) when is_atom(state), do: [state]
  def find_nextstates({_, _, asts}), do: find_nextstates(asts)
  def find_nextstates({_, asts}), do: find_nextstates(asts)
  def find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts, &find_nextstates/1)
  def find_nextstates(_), do: []
end

# ============================== RuleEngine ====================================

defmodule ExFSM.RuleEngine do
  @moduledoc false

  @type acc :: %{
          rules_applied: [map()],
          exit: any() | nil
        }

  @spec run(module, {atom, atom}, any, any, keyword) ::
          {:next_state, any}
          | {:next_state, any, non_neg_integer}
          | {:error, term}
  def run(mod, {_st, _ev} = key, params, state, _opts \\ []) do
    %{entry: entry, graph: graph, weights: weights} =
      Map.get(mod.rules_graph(), key) ||
        raise ArgumentError, "No ruleset for #{inspect key}"

    path = plan_path(graph, weights, entry)

    {acc, _last_params} =
      exec_path(mod, path, params, %{
        rules_applied: [],
        exit: nil
      })

    out_fun =
      Map.get(mod.rules_outputs(), key) ||
        raise ArgumentError, "No rules_exit for #{inspect key}"

    apply(mod, out_fun, [params, state, acc])
  end

  # -------- planner: DFS greedy by weight (fallback: ordre alphabétique) ------
  defp plan_path(graph, weights, entry) do
    do_plan(graph, weights, entry, [])
  end

  defp do_plan(graph, weights, rule, acc) do
    acc2 = acc ++ [rule]
    links = get_in(graph, [rule, :links]) || []

    case links do
      [] -> acc2
      ls ->
        next =
          ls
          |> Enum.sort_by(fn r -> {-Map.get(weights, r, 0), to_string(r)} end)
          |> List.first()

        do_plan(graph, weights, next, acc2)
    end
  end

  # ------------------------------- executor -----------------------------------
  defp exec_path(mod, [rule | rest], params, acc) do
    case apply(mod, rule, [params]) do
      {:__next__, {next, p2}} ->
        # si l’utilisateur pointe ailleurs que rest[0], on suit sa décision (branch dynamique)
        exec_path(mod, [next | rest], p2, push(acc, rule, :ok, p2))

      {:__exit__, exit} ->
        {%{acc | exit: exit} |> push(rule, :exit, params), params}

      other ->
        raise ArgumentError, "rule #{inspect(rule)} returned invalid value: #{inspect other}"
    end
  end

  defp exec_path(_mod, [], params, acc), do: {acc, params}

  defp push(acc, rule, status, params) do
    step = %{rule: rule, status: status, params: params}
    %{acc | rules_applied: acc.rules_applied ++ [step]}
  end

  # Choose a node with no predecessors
  def infer_entry_rule(graph) when map_size(graph) == 0, do: nil
  def infer_entry_rule(graph) when is_map(graph) do
    preds =
      graph
      |> Enum.flat_map(fn {_rule, %{next: ns}} -> ns || [] end)
      |> MapSet.new()

    graph
    |> Map.keys()
    |> Enum.find(fn r -> not MapSet.member?(preds, r) end)
  end
end

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
  defp to_list(nil), do: []
  defp to_list(list) when is_list(list), do: list
  defp to_list(one), do: [one]

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
