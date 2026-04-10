defmodule ExFSM do
  @moduledoc """
  Rule-based FSM DSL using conditional graphs.

  Transitions are declared with `deftrans_rules/2`, rules with `defrule/2`,
  and finalized with `defrules_commit/1` + `defrules_exit/4`.
  Classic single-function transitions use `deftrans/2`, bypasses use `defbypass/2`.

  Introspection:
    * `rules_graph/0`     -> `%{{state, event} => %{entry: atom, graph: map, weights: map}}`
    * `rules_outputs/0`   -> `%{{state, event} => exit_fun_atom}`
    * `fsm/0`             -> `%{{state, event} => {module, to_states}}`
    * `event_bypasses/0`  -> `%{event => module}`
  """

  # ------------------------------- __using__ ----------------------------------

  defmacro __using__(_opts) do
    quote do
      import ExFSM

      @fsm %{}
      @check %{}
      @docs %{}
      @bypasses %{}
      # @to is a mutable compile-time attribute used to pass target states
      # between deftrans/defusefsm and @before_compile. It is set before
      # the macro expands and reset to nil afterward. This relies on
      # sequential evaluation of module attributes during compilation.
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
      def fsm, do: @fsm
      def check, do: @check
      def docs, do: @docs
      def event_bypasses, do: @bypasses
      def rules_graph, do: @rules_graph
      def rules_outputs, do: @rules_outputs
      def match_trans(_, _, _, _), do: false
    end
  end

  # === Meta helpers (public) ===
  def meta, do: ExFSM.Meta.get()

  # === Explicit sugar (public helpers) ===
  def next_ok(next_rule, params, state, tag \\ :ok),
    do: {:__next__, next_rule, params, state, tag}

  def next_exit(payload, params, state, tag \\ :ok),
    do: {:__exit__, payload, params, state, tag}

  def next_warn(payload, params, state),
    do: {:__exit__, payload, params, state, :warning}

  def next_error(payload, params, state),
    do: {:__exit__, payload, params, state, :error}

  # === Tolerant macros (use var!/1 to capture caller's variables) ===

  # ------------------------------------------------------
  # next_rule({:rule, params, state}, tag \\ :ok)
  # or implicit form: next_rule({:rule, params}, tag)
  # ------------------------------------------------------
  defmacro next_rule(arg_ast, tag_ast \\ :ok) do
    {rule_ast, params_ast, state_ast} =
      case arg_ast do
        # {:rule, params, state}
        {:{}, _, [r_ast, p_ast, s_ast]} ->
          {r_ast, p_ast, s_ast}

        # {:rule, params}
        {:{}, _, [r_ast, p_ast]} ->
          {r_ast, p_ast, Macro.var(:state, nil)}

        # keyword form [rule: params]
        [{r_atom, p_ast}] when is_atom(r_atom) ->
          {r_atom, p_ast, Macro.var(:state, nil)}

        # tuple “plat” {rule, params, state}
        {r_ast, p_ast, s_ast} ->
          {r_ast, p_ast, s_ast}

        other ->
          raise ArgumentError,
                "next_rule expects {:rule, params, state} or {:rule, params}, got: #{Macro.to_string(other)}"
      end

    quote do
      {:__next__, unquote(rule_ast), unquote(params_ast), unquote(state_ast), unquote(tag_ast)}
    end
  end

  # ------------------------------------------------------
  # rules_exit(payload, params_override \\ var!(params),
  #            state_override \\ var!(state), tag \\ :ok)
  # ------------------------------------------------------
  defmacro rules_exit(
             payload_ast,
             params_override_ast \\ nil,
             state_override_ast \\ nil,
             tag_ast \\ :ok
           ) do
    quote do
      {:__exit__, unquote(payload_ast), unquote(params_override_ast) || var!(params),
       unquote(state_override_ast) || var!(state), unquote(tag_ast)}
    end
  end

  # ---------------------------------------------------------------------------
  # Classic deftrans / defbypass
  # ---------------------------------------------------------------------------

  @type transition ::
          ({event_name :: atom, event_param :: any}, state :: any ->
             {:next_state, next_state :: atom, state :: any}
             | {:next_state, next_state :: atom, state :: any, non_neg_integer}
             | {:keep_state, state :: any}
             | {:error, term})

  defmacro deftrans({state, _meta, [{trans, params}, obj | _]} = signature, body_block) do
    quote do
      @fsm Map.put(
             @fsm,
             {unquote(state), unquote(trans)},
             {__MODULE__, @to || unquote(Enum.uniq(ExFSM.find_nextstates(body_block[:do])))}
           )
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs, {:transition_doc, unquote(state), unquote(trans)}, doc)
      def match_trans(
            unquote(state),
            unquote(trans),
            unquote(ExFSM.underscore_vars(obj)),
            unquote(ExFSM.underscore_vars(params))
          ),
          do: true

      def unquote(signature), do: unquote(body_block[:do])
      @to nil
    end
  end

  defmacro defbypass({event, _meta, [params, obj]} = signature, body_block) do
    quote do
      @bypasses Map.put(@bypasses, unquote(event), __MODULE__)
      doc = Module.get_attribute(__MODULE__, :doc)
      @docs Map.put(@docs, {:event_doc, unquote(event)}, doc)
      def match_bypass(
            unquote(event),
            unquote(ExFSM.underscore_vars(obj)),
            unquote(ExFSM.underscore_vars(params))
          ),
          do: true

      def unquote(signature), do: unquote(body_block[:do])
    end
  end

  # ------------------------- rules: transition entry --------------------------
  @doc """
  Declares a transition (state + event) controlled by a rule graph.
  Inside: `defrule a(params, state)`, `defrules_commit/1`, `defrules_exit/3`.
  """
  defmacro deftrans_rules({state_ast, _m, [{event_ast, params}, obj | _]} = _sig, do: block) do
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
      def match_trans(
            unquote(state_ast),
            unquote(event_ast),
            unquote(ExFSM.underscore_vars(obj)),
            unquote(ExFSM.underscore_vars(params))
          ),
          do: true

      unquote(block)
      # do NOT reset @current_ruleset here — defrules_exit/3 still needs it
    end
  end

  def underscore_vars({t, {_, _, _} = a}), do: {t, underscore_vars(a)}

  def underscore_vars({t, a}) when is_tuple(a),
    do: {t, List.to_tuple(underscore_vars(Tuple.to_list(a)))}

  def underscore_vars({a, m, p}) when is_atom(a) do
    case Atom.to_charlist(a) do
      [c | _] = charlist when c in ?a..?z ->
        {String.to_atom("_" <> "#{charlist}"), m, underscore_vars(p)}

      _ ->
        {a, m, underscore_vars(p)}
    end
  end

  def underscore_vars({a, m, p}), do: {a, m, underscore_vars(p)}
  def underscore_vars(list) when is_list(list), do: Enum.map(list, &underscore_vars/1)
  def underscore_vars(v), do: v

  # Classic transition introspection
  def find_nextstates({:{}, _, [:next_state, state | _]}) when is_atom(state), do: [state]
  def find_nextstates({_, _, asts}), do: find_nextstates(asts)
  def find_nextstates({_, asts}), do: find_nextstates(asts)
  def find_nextstates(asts) when is_list(asts), do: Enum.flat_map(asts, &find_nextstates/1)
  def find_nextstates(_), do: []

  # ------------------------------- defrule/2 ----------------------------------
  @doc """
  Explicit form: `defrule :a, params, state do ... end`.
  Declares a rule node via `defrule a(params, state) do ... end`.
  The body must return `next_rule({...})` or `rules_exit(...)`.
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

  @doc "Implicit form: `defrule a(params, state) do ... end`"
  defmacro defrule({name_ast, _ctx, [params_ast, state_ast]}, do: body) do
    mod = __CALLER__.module

    {st, ev} =
      Module.get_attribute(mod, :current_ruleset) ||
        raise(ArgumentError, "defrule must be inside deftrans_rules")

    # introspect next rules from the body AST
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

  # --------------------------- defrules_commit/1 ------------------------------

  # Commit helper: infer entry rule from graph
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
  Closes the rule block: computes the entry point if absent, finalizes the graph,
  and persists `@rules_graph` in the module (like `@fsm` / `@rules_outputs`).

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

    opts_term = ExFSM.extract_literal_opts!(opts)
    user_entry = opts_term[:entry] || entry0

    user_weights =
      case opts_term[:weights] do
        nil -> weights0 || %{}
        m when is_map(m) -> m
        kw when is_list(kw) -> Map.new(kw)
        _ -> %{}
      end

    # If no explicit entry, infer it from the graph
    entry =
      case user_entry || entry0 do
        nil -> infer_entry_rule(graph0)
        e -> e
      end

    if entry == nil do
      raise ArgumentError,
            "No entry rule for #{inspect({st, ev})}. " <>
              "Set entry: ... or ensure a start node (no predecessors)."
    end

    quote do
      # Persist graph/weights/entry for introspection
      @rules_graph Map.put(
                     @rules_graph || %{},
                     {unquote(st), unquote(ev)},
                     %{
                       entry: unquote(entry),
                       graph: unquote(Macro.escape(graph0)),
                       weights: unquote(Macro.escape(user_weights))
                     }
                   )
      def __rules_entry__({unquote(st), unquote(ev)}), do: unquote(entry)
      :ok
    end
  end

  # ---------------------------- defrules_exit/2 --------------------------------
  @doc """
  Exit handler: `defrules_exit(new_params, new_state, proposed) do ... end`.

  Receives final `new_params`, `new_state` (flow state), and `proposed` (the exit payload
  from `rules_exit/4`). Must return `{:next_state, ...}` / `{:keep_state, ...}` / `{:error, ...}`.
  Access `ExFSM.meta()` for `initial_state`, `initial_params`, `acc`, `delta`.
  """
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

  # --- Compile-time literal opts extraction ---

  @doc false
  # Accepts keyword-list AST whose values are literals (atoms, integers, maps).
  # Raises a compile-time ArgumentError if any value is a runtime expression.
  def extract_literal_opts!([]), do: []

  def extract_literal_opts!(kw_ast) when is_list(kw_ast) do
    Enum.map(kw_ast, fn
      {k, v} when is_atom(k) ->
        {k, extract_literal_value!(v)}

      other ->
        raise ArgumentError,
              "defrules_commit: opts must be a literal keyword list, got: #{Macro.to_string(other)}"
    end)
  end

  def extract_literal_opts!(other) do
    raise ArgumentError,
          "defrules_commit: opts must be a literal keyword list, got: #{Macro.to_string(other)}"
  end

  defp extract_literal_value!(v) when is_atom(v) or is_integer(v) or is_float(v) or is_binary(v),
    do: v

  # %{...} map literal in AST form: {:%{}, _meta, pairs}
  defp extract_literal_value!({:%{}, _, pairs}) do
    Map.new(pairs, fn {k, v} -> {extract_literal_value!(k), extract_literal_value!(v)} end)
  end

  # keyword list as value: [{k, v}, ...]
  defp extract_literal_value!(list) when is_list(list) do
    Enum.map(list, fn
      {k, v} -> {extract_literal_value!(k), extract_literal_value!(v)}
      v -> extract_literal_value!(v)
    end)
  end

  defp extract_literal_value!(other) do
    raise ArgumentError,
          "defrules_commit: expected a literal value, got: #{Macro.to_string(other)}"
  end

  # --- Graph introspection helpers ---

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

        # Other explicit continuations
        {:next_continue, _, [rule_ast | _]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        # Already-expanded literal return: {:__next__, rule, params, state, tag}
        {:{}, _, [:__next__, rule_ast, _p, _s, _tag]} = node, acc ->
          {node, put_next_from_rule_atom(acc, rule_ast)}

        # Everything else: unchanged
        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(acc)
  end

  # --- Internal detection helpers ---

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
end
