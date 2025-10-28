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

      # ---- helpers rules (taggable next) ----
      def next_rule({rule, params}), do: {:__next__, {rule, params}, :ok}
      def next_ok({rule, params}),   do: {:__next__, {rule, params}, :ok}
      def next_warn({rule, params}), do: {:__next__, {rule, params}, :warn}
      def next_error({rule, params}), do: {:__next__, {rule, params}, :error}
      def rules_exit(params), do: {:__exit__, params}

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

    rules_graph = Module.get_attribute(mod, :rules_graph) || %{}
    %{entry: entry0, graph: graph0, weights: weights0} =
      Map.get(rules_graph, {st, ev}, %{entry: nil, graph: %{}, weights: %{}})

    {opts_term, _} = Code.eval_quoted(opts, [], __CALLER__)
    user_entry = opts_term[:entry] || entry0
    user_weights =
      case opts_term[:weights] do
        nil -> (weights0 || %{})
        m when is_map(m) -> m
        kw when is_list(kw) -> Map.new(kw)
        _ -> %{}
      end

    entry =
      case (user_entry || entry0) do
        nil -> ExFSM.RuleEngine.infer_entry_rule(graph0)
        e   -> e
      end

    if entry == nil do
      raise ArgumentError,
            "No entry rule for #{inspect({st, ev})}. " <>
            "Set entry: ... or ensure a start node (no predecessors)."
    end

    # Snapshot -> inject literal in the compiled module
    graph_lit   = Macro.escape(graph0)
    weights_lit = Macro.escape(user_weights)

    quote do
      @rules_graph Map.put(
        @rules_graph || %{},
        {unquote(st), unquote(ev)},
        %{
          entry: unquote(entry),
          graph: unquote(Macro.escape(graph0)),
          weights: unquote(Macro.escape(user_weights))
        }
      )
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
  def find_next_rules(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:next_rule, _, [arg]} = node, acc ->
          {node, maybe_put_rule(acc, arg)}

        {:next_ok, _, [arg]} = node, acc ->
          {node, maybe_put_rule(acc, arg)}

        {:next_warn, _, [arg | _]} = node, acc ->
          {node, maybe_put_rule(acc, arg)}

        {:next_error, _, [arg | _]} = node, acc ->
          {node, maybe_put_rule(acc, arg)}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(acc)
  end

  defp maybe_put_rule(acc, {name, _}) when is_atom(name), do: MapSet.put(acc, name)

  defp maybe_put_rule(acc, kw) when is_list(kw) and kw != [] do
    # handle keyword form: next_ok reserve: p
    case kw do
      [{name, _}] when is_atom(name) -> MapSet.put(acc, name)
      _ -> acc
    end
  end

  defp maybe_put_rule(acc, _), do: acc

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

  @type tag :: :ok | {:warn, any} | {:error, any} | :exit
  @type step :: %{
          rule: atom(),
          tag: tag(),
          in: any(),
          out: any() | nil,
          time: non_neg_integer(),
        }
  @type acc :: %{
          rules_applied: [step],
          exit: any() | nil,
          plan: [atom()],
          chosen: [atom()]
        }

  @doc """
  Exécute la transition {state,event}.
  Options possibles :
    - mode: :full | :steps_only | :dry_run   (par défaut :full – dry_run est à relayer dans tes rules)
    - params_override: %{rule => params}     (remplace les params au passage d'une rule)
  """
  @spec run(module, {atom, atom}, any, any, keyword) ::
          {:next_state, any}
          | {:next_state, any, non_neg_integer}
          | {:steps_done, any, any, acc}
          | {:error, term}
  def run(mod, {_st, _ev} = key, params, state, opts \\ []) do
    %{entry: entry, graph: graph, weights: weights0} =
      Map.get(mod.rules_graph(), key) ||
        raise(ArgumentError, "No ruleset for #{inspect(key)}")

    weights = normalize_weights(weights0)
    path = plan_path(graph, weights, entry)
    params_override = Keyword.get(opts, :params_override, %{})
    mode = Keyword.get(opts, :mode, :full)

    {acc, params2, halted?} = exec_path(mod, path, params, %{rules_applied: [], exit: nil}, params_override, mode)

    case mode do
      :steps_only ->
        {:steps_done, params2, state, acc}

      _ ->
        out_fun =
          Map.get(mod.rules_outputs(), key) ||
            raise ArgumentError, "No rules_exit for #{inspect key}"

        apply(mod, out_fun, [params, state, acc])
    end
  end

  # ---- runtime normalization helpers ----------------------------------------
  defp normalize_weights(w) when is_map(w), do: w
  defp normalize_weights(w) when is_list(w), do: Map.new(w)
  defp normalize_weights(_), do: %{}

  # ------------------------------ Planner -------------------------------------

  @doc """
  Renvoie le plan nominal (liste ordonnée de rules) calculé en DFS glouton par poids.
  """
  @spec plan(module, {atom, atom}) :: [atom]
  def plan(mod, key = {st, ev}) do
    %{entry: entry, graph: graph, weights: weights} =
      Map.get(mod.rules_graph(), key) ||
        raise ArgumentError, "No ruleset for #{inspect key}"

    plan_path(graph, weights, entry)
  end

  @doc """
  Dry-run structurel : ne touche pas aux rules, renvoie seulement plan, graph et entry.
  """
  @spec dry_run(module, {atom, atom}) :: {:ok, %{plan: [atom], graph: map, entry: atom}}
  def dry_run(mod, key) do
    %{entry: entry, graph: graph, weights: weights} =
      Map.get(mod.rules_graph(), key) ||
        raise ArgumentError, "No ruleset for #{inspect key}"

    {:ok, %{plan: plan_path(graph, weights, entry), graph: graph, entry: entry}}
  end

  defp plan_path(graph, weights, entry) do
    do_plan(graph, weights, entry, [])
  end

  defp do_plan(_graph, _weights, nil, acc), do: Enum.reverse(acc)
  defp do_plan(graph, weights, rule, acc) do
    acc2 = acc ++ [rule]
    # AVANT: links = get_in(graph, [rule, :links]) || []
    nexts = get_in(graph, [rule, :next]) || []

    case nexts do
      [] -> acc2
      ls ->
        next =
          ls
          |> Enum.sort_by(fn r -> {-Map.get(weights, r, 0), to_string(r)} end)
          |> List.first()

        do_plan(graph, weights, next, acc2)
    end
  end

  # ------------------------------ Executor ------------------------------------
  defp push(acc, rule, tag, params, opts \\ []) do
    step =
      %{rule: rule, tag: tag, params: params}
      |> maybe_put(:chosen, Keyword.get(opts, :chosen))

    %{acc | rules_applied: acc.rules_applied ++ [step]}
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v),   do: Map.put(map, k, v)

  defp exec_path(_mod, [], params, acc, _ovr, _mode), do: {acc, params, false}
  defp exec_path(mod, [rule | rest], params, acc, ovr, mode) do
    p_step = Map.get(ovr, rule, params)

    case apply(mod, rule, [p_step]) do
      {:__next__, {next, p2}} ->
        acc2 = push(acc, rule, :ok, p2, chosen: next)
        exec_path(mod, [next | rest], p2, acc2, ovr, mode)

      {:__next__, {next, p2}, :ok} ->
        acc2 = push(acc, rule, :ok, p2, chosen: next)
        exec_path(mod, [next | rest], p2, acc2, ovr, mode)

      {:__next__, {next, p2}, tag} when tag in [:warn, :error] ->
        acc2 = push(acc, rule, tag, p2, chosen: next)
        if mode == :steps_only, do: {acc2, p2, true}, else: exec_path(mod, [next | rest], p2, acc2, ovr, mode)

      {:__exit__, exit} ->
        if mode == :steps_only do
          {acc, params, true}
        else
          acc2 = push(acc, rule, :exit, params)
          {%{acc2 | exit: exit}, params, true}
        end
    end
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

  # ----------------------------- Remaining ------------------------------------

  def plan_from(mod, {st, ev}, from_rule) do
    %{graph: graph, weights: weights0} =
      Map.get(mod.rules_graph(), {st, ev}) ||
        raise ArgumentError, "No ruleset for #{inspect {st,ev}}"

    weights = normalize_weights(weights0)
    do_plan(graph, weights, from_rule, [])
  end

  @doc """
  Steps “restants” selon le plan nominal (plan – rules :ok déjà passées).
  """
  def remaining_rules(state, {st, ev} = key, rules_applied) do
    # 1/ resolve handler pour être sûr du module
    handler =
      ExFSM.Machine.find_handlers({state, ev, %{}}) |> List.first() ||
        raise ArgumentError, "No handler for #{inspect key}"

    # 3/ Si aucune règle exécutée : plan complet depuis l'entry
    case rules_applied do
      [] ->
        %{entry: entry} = Map.fetch!(handler.rules_graph(), key)
        plan_from(handler, key, entry)

      applied when is_list(applied) ->
        # Dernière règle « réussie » (ok/warn) — on tolère warn comme progression
        last =
          applied
          |> Enum.reverse()
          |> Enum.find(fn e -> e.tag in [:ok, :warn] end)

        cond do
          is_nil(last) ->
            # Seules des erreurs/exit : on repart de l’entry
            %{entry: entry} = Map.fetch!(handler.rules_graph(), key)
            plan_from(handler, key, entry)

          true ->
            # Si le step a un chosen, on repart de ce chosen
            from_rule = last[:chosen] || last[:rule]
            full = plan_from(handler, key, from_rule)

            # Éliminer les nodes déjà "ok/warn" après ce point
            done_ok =
              applied
              |> Enum.filter(&(&1.tag in [:ok, :warn]))
              |> Enum.map(& &1.rule)
              |> MapSet.new()

            Enum.reject(full, &MapSet.member?(done_ok, &1))
        end
    end
  end

  # ------------------------------ Replay --------------------------------------

  # @spec replay(any, {atom, atom}, map, map, atom) ::
  #         {:ok, map} | {:next_state, any} | {:next_state, any, non_neg_integer} | {:error, term}
  def replay(state, {st, ev} = key, params_override \\ %{}, acc, mode \\ :full) do
    handler =
      ExFSM.Machine.find_handlers({state, ev, %{}}) |> List.first() ||
        raise ArgumentError, "No handler for #{inspect key}"

    remaining = remaining_rules(state, key, acc[:rules_applied])
    # Paramètre de départ : si on a un dernier step, reprend ses params,
    # sinon laisse le call-site fournir ses params à run/5 s’il préfère.
    base_params =
      acc[:rules_applied]
      |> List.last()
      |> case do
        %{params: p} -> p
        _ -> %{}
      end

      {acc2, _params2, _halted?} = exec_path(handler, remaining, base_params, acc, params_override, mode)

    if mode == :steps_only do
      {:ok, acc2}
    else
      out_fun =
        Map.get(handler.rules_outputs(), key) ||
          raise ArgumentError, "No rules_exit for #{inspect key}"

      # NB: ici, on ne change pas l’état — on délègue à defrules_exit/3
      case apply(handler, out_fun, [base_params, state, acc2]) do
        {:next_state, state_name, state2, timeout} ->
            {:next_state, ExFSM.Machine.State.set_state_name(state2, state_name, ExFSM.Machine.to_list(ExFSM.Machine.State.handlers(state, base_params))), timeout}

        {:next_state, state_name, state2} ->
            {:next_state, ExFSM.Machine.State.set_state_name(state2, state_name, ExFSM.Machine.to_list(ExFSM.Machine.State.handlers(state, base_params)))}

        other ->
            other
      end
    end
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
