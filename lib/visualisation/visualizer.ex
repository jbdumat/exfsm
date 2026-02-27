defmodule ExFSM.Visualizer do
  @moduledoc """
  Visualisation Mermaid minimaliste pour ExFSM, **sans modifier le DSL**.

  Idées de base :

  - Global :
      * un subgraph par transition `{state, event}`
      * chaque rule `r` flèche ses `next_rule` (d'après `rules_graph/0`)
      * les transitions sont chainées entre elles par une flèche
        `entry(state_i,event_i) -.-> entry(state_j,event_j)` dans un ordre donné.

  - Contexte :
      * même représentation globale
      * si on fournit un accumulateur :
          - soit un seul `acc` (une transition)
          - soit une map `%{{state,event} => acc, ...}` pour un même objet FSM
        alors :
          - les arêtes réellement parcourues sont colorées :
              :ok      -> vert
              :warning -> jaune
              :error   -> rouge
          - le reste (rules / transitions non traversées) reste en style par défaut
            => "reste à faire" visible naturellement.

  Aucun changement à ExFSM :
  - on n'exige ni macros de tagging, ni modifications de `next_rule`.
  """

  @type handler :: module()
  @type key :: {atom(), atom()}

  # Couleurs
  @c_ok       "#10b981"
  @c_warn     "#f59e0b"
  @c_error    "#ef4444"
  @c_entry    "#3b82f6"
  @c_node_st  "#374151"
  @c_node_txt "#111827"

  # =====================================================================================
  # PUBLIC API
  # =====================================================================================

  @doc """
  Visu globale :

  - un subgraph par `{state,event}`
  - chaque rule flèche ses `next_rule`
  - les transitions sont chaînées dans l'ordre choisi.

  `opts` :
    * `:order` – liste explicite de clés `{state,event}` pour le chainage.
                 À défaut : tri alphabétique par `{state,event}`.
  """
  @spec mermaid_global(handler, keyword) :: String.t()
  def mermaid_global(handler, opts \\ []) do
    rg    = handler.rules_graph()
    order = pick_order(rg, Keyword.get(opts, :order))

    {subgraphs, keyed_edges} =
      rg
      |> Enum.map(fn {k, m} ->
        {sg, edges} = subgraph_snippet(k, m)
        {sg, {k, edges}}
      end)
      |> Enum.unzip()

    _edges_by_key = Map.new(keyed_edges)

    chain_edges =
      order
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [k1, k2] ->
        chain_edges_between(rg, k1, k2)
        |> Enum.map(&elem(&1, 0))   # on ne garde que la ligne Mermaid
      end)

    ["flowchart LR" | subgraphs ++ chain_edges]
    |> Enum.join("\n")
  end


  @doc """
  Visu contexte :

  - Sans accumulateur (`acc_or_map = nil`) :
      * identique à `mermaid_global/2`.

  - Avec `acc` simple (une transition) :
      * détection de la clé `{state,event}` via :
          - `acc.meta.transition`
          - ou overlap des rules présentes dans `acc.steps`
      * FSM complète affichée
      * arêtes de cette transition colorées selon `steps[*].tag`.

  - Avec map d'accumulateurs :
      * `acc_or_map` = `%{{state,event} => acc, ...}` (ou clé `[state,event]` ou converted)
      * FSM complète affichée
      * toutes les transitions présentes dans la map sont colorées selon leurs `steps`.

  `opts` :
    * `:key`   – force la clé de focus pour l'acc simple
    * `:order` – comme pour `mermaid_global/2`
  """
  @spec mermaid_context(handler, map() | nil, keyword) :: String.t()
  def mermaid_context(handler, acc_or_map \\ nil, opts \\ []) do
    rg    = handler.rules_graph()
    order = pick_order(rg, Keyword.get(opts, :order))

    {subgraphs, keyed_edges} =
      rg
      |> Enum.map(fn {k, m} ->
        {sg, edges} = subgraph_snippet(k, m)
        {sg, {k, edges}}
      end)
      |> Enum.unzip()

    edges_by_key = Map.new(keyed_edges)

    # chain_edges_raw :: [{line :: String.t(), key_source :: {state,event}}]
    chain_edges_raw =
      order
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [k1, k2] ->
        chain_edges_between(rg, k1, k2)
      end)

    {chain_edges, cross_info} = Enum.unzip(chain_edges_raw)

    # cross_meta :: [{{key_source, rule_source}, idx_local}]
    cross_meta =
      cross_info
      |> Enum.with_index(0)
      |> Enum.map(fn {info, idx_local} -> {info, idx_local} end)

    {link_styles, node_styles} =
      case acc_or_map do
        nil ->
          {[], []}

        %{} = acc ->
          if multi_acc_map?(acc) do
            acc_map = normalize_multi_acc_map(acc)
            build_styles_from_accs(acc_map, edges_by_key, rg, cross_meta)
          else
            key = acc_focus_key(rg, acc, opts[:key])
            acc_map = %{key => acc}
            build_styles_from_accs(acc_map, edges_by_key, rg, cross_meta)
          end
      end

    ["flowchart LR" | subgraphs ++ chain_edges ++ node_styles ++ link_styles]
    |> Enum.join("\n")
  end

  # =====================================================================================
  # SUBGRAPHS & EDGES
  # =====================================================================================

  # Retourne {snippet, edges}, edges = [{key, from, to}] dans l'ordre d'émission.
  defp subgraph_snippet(key = {state, event}, %{entry: entry, graph: g}) do
    header     = "subgraph #{state} - #{event}"
    decl_entry = "  " <> node_decl(key, entry)

    {edge_lines, edges} =
      g
      |> Enum.flat_map(fn {rule, %{next: nexts}} ->
        Enum.map(nexts, fn nxt ->
          line = edge_decl({key, rule}, {key, nxt})
          {line, {key, rule, nxt}}
        end)
      end)
      |> Enum.unzip()

    footer = "end"

    snippet =
      [header, decl_entry | edge_lines]
      |> Enum.concat([footer])
      |> Enum.join("\n")

    {snippet, edges}
  end

  defp node_decl(key, rule),
    do: ~s(#{node_id(key, rule)}["#{Atom.to_string(rule)}"])

  defp edge_decl({key1, r1}, {key2, r2}) do
    ~s(  #{node_id(key1, r1)}["#{Atom.to_string(r1)}"] --> #{node_id(key2, r2)}["#{Atom.to_string(r2)}"])
  end

  defp node_id({state, event}, rule),
    do: "n_#{state}_#{event}_#{rule}"

  # Génère toutes les flèches terminal(rule) -.-> entry(next_transition)
  # et retourne {line, {key_source, rule_source}} pour pouvoir les styler ensuite.
  defp chain_edges_between(rules_graph, key1, key2) do
    %{entry: entry2} = Map.fetch!(rules_graph, key2)
    t_rules = terminal_rules(Map.fetch!(rules_graph, key1))

    Enum.map(t_rules, fn r1 ->
      line = ~s(  #{node_id(key1, r1)} -.-> #{node_id(key2, entry2)})
      {line, {key1, r1}}
    end)
  end

  # =====================================================================================
  # STYLES À PARTIR DES ACCS
  # =====================================================================================

  # acc_map :: %{key => acc}
  # edges_by_key :: %{key => [{key, from, to}]}
  # rules_graph :: %{key => %{entry: atom, graph: %{...}}}
  # cross_meta :: [{{key_source, rule_source}, idx_local}]
  defp build_styles_from_accs(acc_map, edges_by_key, rules_graph, cross_meta) do
    # 1) Index global des edges internes (rule -> next_rule)
    all_edges =
      rules_graph
      |> Map.keys()
      |> Enum.flat_map(fn key ->
        Map.get(edges_by_key, key, [])
      end)

    edge_index =
      all_edges
      |> Enum.with_index(0)
      |> Map.new(fn {{key, from, to}, idx} -> {{key, from, to}, idx} end)

    # 1.a styles internes (r -> next)
    link_styles_internal =
      acc_map
      |> Enum.flat_map(fn {key, acc} ->
        steps = get_steps(acc)

        steps
        |> Enum.map(&normalize_step/1)
        |> Enum.flat_map(fn %{rule: r, tag: t, chosen: ch} ->
          case ch do
            nil   -> []
            :exit -> []    # pas d’edge interne vers :exit
            nxt   -> [{{key, r, nxt}, t}]
          end
        end)
        |> Enum.map(fn {{edge_key, from, to}, tag} ->
          case Map.get(edge_index, {edge_key, from, to}) do
            nil -> nil
            idx ->
              color =
                case tag do
                  :ok      -> @c_ok
                  :warning -> @c_warn
                  :error   -> @c_error
                  _        -> @c_ok
                end

              "linkStyle #{idx} stroke:#{color},stroke-width:3px,opacity:1"
          end
        end)
        |> Enum.reject(&is_nil/1)
      end)

    # nodes d’entrée des transitions parcourues
    entry_map =
      rules_graph
      |> Enum.map(fn {k, %{entry: e}} -> {k, e} end)
      |> Map.new()

    node_styles =
      acc_map
      |> Map.keys()
      |> Enum.map(fn key ->
        case Map.get(entry_map, key) do
          nil   -> nil
          entry -> style_node(key, entry, @c_entry)
        end
      end)
      |> Enum.reject(&is_nil/1)

    # 2) edges inter-transitions (pointillés)
    # elles viennent APRES toutes les arêtes internes
    cross_base_idx = length(all_edges)

    link_styles_cross =
      cross_meta
      |> Enum.map(fn {{key_src, rule_src}, idx_local} ->
        case Map.get(acc_map, key_src) do
          nil ->
            nil

          acc_src ->
            case step_tag_for_exit_rule(acc_src, rule_src) do
              nil ->
                # règle terminale non empruntée -> pas de style
                nil

              tag ->
                color =
                  case tag do
                    :ok      -> @c_ok
                    :warning -> @c_warn
                    :error   -> @c_error
                    _        -> @c_ok
                  end

                idx = cross_base_idx + idx_local
                "linkStyle #{idx} stroke:#{color},stroke-width:3px,opacity:1,stroke-dasharray:5 5"
            end
        end
      end)
      |> Enum.reject(&is_nil/1)

    {link_styles_internal ++ link_styles_cross, node_styles}
  end

  defp style_node(key, rule, color) do
    ~s(style #{node_id(key, rule)} fill:#{color},stroke:#{@c_node_st},stroke-width:1px,color:#{@c_node_txt})
  end

  # =====================================================================================
  # HELPERS ACC
  # =====================================================================================

  defp get_steps(acc),
    do: Map.get(acc, :steps) || Map.get(acc, "steps") || []

  defp normalize_step(%{} = step) do
    %{
      rule:   get_atom(step, :rule),
      tag:    get_atom(step, :tag),
      chosen: get_atom(step, :chosen)
    }
  end

  defp get_atom(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      a when is_atom(a)   -> a
      s when is_binary(s) -> String.to_atom(s)
      _ -> nil
    end
  end

  # =====================================================================================
  # HELPERS POUR ACC SIMPLE / MULTI
  # =====================================================================================

  # Heuristique : multi acc map si toutes les keys ressemblent à une clé de FSM
  # ({state,event} ou [state,event]).
  defp multi_acc_map?(acc) when is_map(acc) do
    acc
    |> Map.keys()
    |> Enum.all?(fn
      {_, _} -> true
      [_, _] -> true
      _      -> false
    end)
  end

  defp normalize_multi_acc_map(acc) do
    acc
    |> Enum.map(fn
      {{s, e}, v} when is_atom(s) and is_atom(e) ->
        {{s, e}, v}

      {[s, e], v} ->
        {{to_atom(s), to_atom(e)}, v}

      {k, v} ->
        {k, v}
    end)
    |> Map.new()
  end

  defp to_atom(x) when is_atom(x),   do: x
  defp to_atom(x) when is_binary(x), do: String.to_atom(x)
  defp to_atom(x),                   do: x

  # Choix de la clé pour un acc simple
  defp acc_focus_key(rules_graph, _acc, explicit_key) when not is_nil(explicit_key) do
    case explicit_key do
      {s, e} when is_atom(s) and is_atom(e) -> {s, e}
      [s, e]                                -> {to_atom(s), to_atom(e)}
      _                                     -> hd(Map.keys(rules_graph))
    end
  end

  defp acc_focus_key(rules_graph, acc, nil) do
    case get_in(acc, ["meta", "transition"]) || get_in(acc, [:meta, :transition]) do
      [s, e] when is_binary(s) and is_binary(e) -> {String.to_atom(s), String.to_atom(e)}
      {s, e} when is_atom(s) and is_atom(e)     -> {s, e}
      _ ->
        # fallback par overlap de rules
        seen =
          get_steps(acc)
          |> Enum.map(&normalize_step/1)
          |> Enum.map(& &1.rule)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        rules_graph
        |> Enum.map(fn {k, %{graph: g}} ->
          overlap =
            g
            |> Map.keys()
            |> MapSet.new()
            |> MapSet.intersection(seen)
            |> MapSet.size()
          {k, overlap}
        end)
        |> Enum.max_by(&elem(&1, 1), fn -> {hd(Map.keys(rules_graph)), -1} end)
        |> elem(0)
    end
  end

  defp step_tag_for_exit_rule(acc, rule) do
    acc
    |> get_steps()
    |> Enum.map(&normalize_step/1)
    |> Enum.find_value(fn %{rule: r, tag: tag, chosen: chosen} ->
      if r == rule and chosen == :exit do
        tag
      else
        nil
      end
    end)
  end

  # Rules "terminales" pour une transition :
  # - soit next == []
  # - soit next contient :exit
  defp terminal_rules(%{graph: g}) do
    g
    |> Enum.flat_map(fn {rule, %{next: nexts}} ->
      cond do
        nexts == [] -> [rule]
        is_list(nexts) and :exit in nexts -> [rule]
        true -> []
      end
    end)
  end

  # =====================================================================================
  # ORDRE DES TRANSITIONS
  # =====================================================================================

  defp pick_order(rules_graph, nil) do
    rules_graph
    |> Map.keys()
    |> Enum.sort_by(fn {s, e} -> {to_string(s), to_string(e)} end)
  end

  defp pick_order(_rules_graph, order) when is_list(order), do: order
end
