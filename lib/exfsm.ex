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
      import ExFSM, only: [
        # blocs
        deftrans_rules: 2,
        defrule: 2, defrule: 4,
        defrules_commit: 1,
        defrules_exit: 4,    # (new_params, new_state_flow, proposed) do ... end

        # sucres (macros + fonctions) — IMPORTER TOUTES LES ARITÉS NÉCESSAIRES
        next_rule: 2,        # si tu as aussi une variante /3, ajoute-la ici
        rules_exit: 2, rules_exit: 3, rules_exit: 4,
        next_ok: 3, next_ok: 4,
        next_exit: 3, next_exit: 4,
        next_warn: 3,
        next_error: 3,

        # meta helpers
        meta: 0
      ]

      @fsm %{}
      @docs %{}
      @bypasses %{}
      @to nil
      @rules_graph %{}
      @rules_outputs %{}
      @current_ruleset nil
      @entry_rule nil
      @weights %{}

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

  # === Helpers META (fonctions publiques) ===
  def meta, do: ExFSM.Meta.get()

  # === Sucres explicites (fonctions publiques) ===
  def next_ok(next_rule, params, state, tag \\ :ok),
    do: {:__next__, next_rule, params, state, tag}

  def next_exit(payload, params, state, tag \\ :ok),
    do: {:__exit__, payload, params, state, tag}

  def next_warn(payload, params, state),
    do: {:__exit__, payload, params, state, :warning}

  def next_error(payload, params, state),
    do: {:__exit__, payload, params, state, :error}

  # === Macros tolérants (utilisent var!/1 pour capturer les variables de l'appelant) ===

  # ------------------------------------------------------
  # next_rule({:rule, params, state}, tag \\ :ok)
  # ou forme implicite: next_rule({:rule, params}, tag)
  # ------------------------------------------------------
  defmacro next_rule(arg_ast, tag_ast \\ :ok) do
    {rule_ast, params_ast, state_ast} =
      case arg_ast do
        # {:rule, params, state}
        {:{}, _, [r_ast, p_ast, s_ast]} -> {r_ast, p_ast, s_ast}

        # {:rule, params}
        {:{}, _, [r_ast, p_ast]} -> {r_ast, p_ast, Macro.var(:state, nil)}

        # forme keyword [rule: params]
        [{r_atom, p_ast}] when is_atom(r_atom) ->
          {r_atom, p_ast, Macro.var(:state, nil)}

        # tuple “plat” {rule, params, state}
        {r_ast, p_ast, s_ast} -> {r_ast, p_ast, s_ast}

        other ->
          raise ArgumentError,
                "next_rule attend {:rule, params, state} ou {:rule, params}, reçu: #{Macro.to_string(other)}"
      end

    quote do
      {:__next__, unquote(rule_ast), unquote(params_ast), unquote(state_ast), unquote(tag_ast)}
    end
  end

  # ------------------------------------------------------
  # rules_exit(payload, params_override \\ var!(params),
  #                        state_override \\ var!(state),
  #                        tag \\ :ok)
  # ------------------------------------------------------
  defmacro rules_exit(payload_ast, params_override_ast \\ nil, state_override_ast \\ nil, tag_ast \\ :ok) do
    quote do
      {:__exit__,
      unquote(payload_ast),
      (unquote(params_override_ast) || var!(params)),
      (unquote(state_override_ast) || var!(state)),
      unquote(tag_ast)}
    end
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
  À l’intérieur : `defrule a(params, tmp)`, `defrules_commit/1`, `defrules_exit/2`.
  """
  defmacro deftrans_rules({state_ast, _m, [{event_ast, _} | _]} = _sig, do: block) do
    mod = __CALLER__.module
    # mark the active ruleset for the block
    Module.put_attribute(mod, :current_ruleset, {state_ast, event_ast})

    # ensure we have a rules_graph entry to mutate from defrule/2
    rg = Module.get_attribute(mod, :rules_graph) || %{}

    Module.put_attribute(
      mod,
      :rules_graph,
      Map.put_new(rg, {state_ast, event_ast}, %{entry: nil, graph: %{}, weights: %{}})
    )

    quote do
      unquote(block)
      # do NOT reset @current_ruleset here — defrules_exit/3 still needs it
    end
  end

  # ------------------------------- defrule/2 ----------------------------------
  @doc """
  Forme explicite : defrule :a, params, state do ... end
  Déclare un nœud de rule via `defrule a(params, state) do ... end`.
  Le corps doit retourner `next_rule({...})` ou `rules_exit(...)`.
  """
  defmacro defrule(name_ast, params_ast, state_ast, do: body) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrule must be inside deftrans_rules")

    nexts = ExFSM.find_next_rules(body)

    rules_graph = Module.get_attribute(mod, :rules_graph) || %{}
    ruleset = Map.get(rules_graph, {st, ev}, %{entry: nil, graph: %{}, weights: %{}})
    graph = Map.put(ruleset.graph || %{}, name_ast, %{next: nexts})

    Module.put_attribute(
      mod,
      :rules_graph,
      Map.put(rules_graph, {st, ev}, %{ruleset | graph: graph})
    )

    fun = String.to_atom("__rule__" <> Atom.to_string(name_ast))

    quote do
      def unquote(fun)(unquote(params_ast), unquote(state_ast)), do: unquote(body)
    end
  end

  @doc "Forme implicite : defrule a(params, state) do ... end"
  defmacro defrule({name_ast, _ctx, [params_ast, state_ast]}, do: body) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrule must be inside deftrans_rules")

    # introspection des sorties depuis le body
    nexts = ExFSM.find_next_rules(body)

    rules_graph = Module.get_attribute(mod, :rules_graph) || %{}
    ruleset = Map.get(rules_graph, {st, ev}, %{entry: nil, graph: %{}, weights: %{}})
    graph = Map.put(ruleset.graph || %{}, name_ast, %{next: nexts})

    Module.put_attribute(mod, :rules_graph, Map.put(rules_graph, {st, ev}, %{ruleset | graph: graph}))

    fun = String.to_atom("__rule__" <> Atom.to_string(name_ast))

    quote do
      def unquote(fun)(unquote(params_ast), unquote(state_ast)), do: unquote(body)
    end
  end

  # --------------------------- defrules_commit/1 ------------------------------

  # Helper commit
  defp infer_entry_rule(graph) when map_size(graph) == 0, do: nil

  defp infer_entry_rule(graph) when is_map(graph) do
    preds =
      graph
      |> Enum.flat_map(fn {_rule, %{next: ns}} -> ns || [] end)
      |> MapSet.new()

    graph
    |> Map.keys()
    |> Enum.find(fn r -> not MapSet.member?(preds, r) end)
  end

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
    user_entry   = opts_term[:entry]   || entry0
    user_weights =
      case opts_term[:weights] do
        nil -> (weights0 || %{})
        m when is_map(m) -> m
        kw when is_list(kw) -> Map.new(kw)
        _ -> %{}
      end

    # Si pas d'entry explicit, on l’infère depuis le graphe
    entry =
      case (user_entry || entry0) do
        nil -> infer_entry_rule(graph0)
        e   -> e
      end

    if entry == nil do
      raise ArgumentError,
            "No entry rule for #{inspect({st, ev})}. " <>
            "Set entry: ... or ensure a start node (no predecessors)."
    end

    quote do
      # Persiste le graphe/poids/entry pour introspection
      @rules_graph Map.put(
        @rules_graph || %{},
        {unquote(st), unquote(ev)},
        %{
          entry:   unquote(entry),
          graph:   unquote(Macro.escape(graph0)),
          weights: unquote(Macro.escape(user_weights))
        }
      )
      def __rules_entry__({unquote(st), unquote(ev)}), do: unquote(entry)
      :ok
    end
  end


  # ---------------------------- defrules_exit/2 --------------------------------
  @doc """
  Forme : defrules_exit(new_params, new_state) do ... end
  Épilogue: reçoit `new_params` (params finaux) et `new_state` (proposé), puis
  retourne `{:next_state, ...}` / `{:keep_state, ...}` / `{:error, ...}`.
  Accède à `ExFSM.meta()` pour `initial_state`, `initial_params`, `acc`, `delta`.
  """
  # defrules_exit(new_params, new_state_flow, proposed_next_state) do ... end
  defmacro defrules_exit(new_params_ast, new_state_ast, proposed_ast, do: body_ast) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrules_exit must be inside deftrans_rules")

    out_fun = String.to_atom("__rules_exit__#{st}_#{ev}")

    quote do
      @rules_outputs Map.put(@rules_outputs || %{}, {unquote(st), unquote(ev)}, unquote(out_fun))
      @fsm Map.put(@fsm || %{}, {unquote(st), unquote(ev)}, {__MODULE__, @to || []})

      @current_ruleset nil
      @to nil
      @entry_rule nil
      @weights %{}

      def unquote(out_fun)(unquote(new_params_ast), unquote(new_state_ast), unquote(proposed_ast)) do
        unquote(body_ast)
      end

      def unquote(st)({unquote(ev), params}, state) do
        ExFSM.RuleEngine.run(__MODULE__, {unquote(st), unquote(ev)}, params, state)
      end
    end
  end

  # --- ExFSM: graph introspection ---

  def find_next_rules(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        # next_rule({:rule, params}) | next_rule({:rule, params, state})
        {:next_rule, _, [arg]} = node, acc ->
          {node, put_next_from_tuple_or_kw(acc, arg)}

        # next_rule({:rule, params}, tag) | next_rule({:rule, params, state}, tag)
        {:next_rule, _, [arg, _tag]} = node, acc ->
          {node, put_next_from_tuple_or_kw(acc, arg)}

        # next_ok(:rule, params, state)  (tag optionnel /3 ou /4)
        {:next_ok, _, [rule_ast, _params, _state]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        {:next_ok, _, [rule_ast, _params, _state, _tag]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        # D'autres continuations explicites ? (si tu en ajoutes)
        {:next_continue, _, [rule_ast | _]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        # Retour littéral déjà expansé: {:__next__, rule, params, state, tag}
        {:{}, _, [:__next__, rule_ast, _p, _s, _tag]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        # Tout le reste: inchangé
        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(acc)
  end

  # --- helpers internes de détection ---

  defp put_next_from_rule_atom(acc, rule_ast) when is_atom(rule_ast),
    do: MapSet.put(acc, rule_ast)

  defp put_next_from_rule_atom(acc, {:|>, _, _} = _pipe), do: acc
  defp put_next_from_rule_atom(acc, {name, _, _ctx}) when is_atom(name),
    do: MapSet.put(acc, name)
  defp put_next_from_rule_atom(acc, _), do: acc

  # {:rule, params} | {:rule, params, state} | [rule: params]
  defp put_next_from_tuple_or_kw(acc, {:{}, _, [rule_ast, _p]}) do
    put_next_from_rule_atom(acc, rule_ast)
  end

  defp put_next_from_tuple_or_kw(acc, {:{}, _, [rule_ast, _p, _s]}) do
    put_next_from_rule_atom(acc, rule_ast)
  end

  defp put_next_from_tuple_or_kw(acc, [{rule, _p}]) when is_atom(rule) do
    MapSet.put(acc, rule)
  end

  defp put_next_from_tuple_or_kw(acc, {rule, _p}) when is_atom(rule),
    do: MapSet.put(acc, rule)

  defp put_next_from_tuple_or_kw(acc, other),
    do: put_next_from_rule_atom(acc, other)

  # Classic introspection
  def find_nextstates({:{}, _, [:next_state, state | _]}) when is_atom(state), do: [state]
  def find_nextstates({_, _, asts}), do: find_nextstates(asts)
  def find_nextstates({_, asts}), do: find_nextstates(asts)
  def find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts, &find_nextstates/1)
  def find_nextstates(_), do: []
end
