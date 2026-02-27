defmodule ExFSM.RuleEngine do
  @type tag :: :ok | :warning | :error

  @spec run(module, {atom, atom}, map(), any, keyword) ::
          {:next_state, atom, any, ExFSM.Acc.t()}
          | {:keep_state, atom, any, ExFSM.Acc.t()}
          | {:error, term, ExFSM.Acc.t()}
          | {:steps_done, map(), map(), any, ExFSM.Acc.t()}
  def run(handler, {state_name, event} = key, params, external_state, opts \\ []) do
    mode = Keyword.get(opts, :mode, :full)

    acc0 = %ExFSM.Acc{params: params, state: external_state, steps: [], exit: nil}
    ExFSM.Meta.init(external_state, params, acc0)

    case mode do
      :steps_only ->
        {acc2, _prop} =
          exec_from(
            handler,
            key,
            entry_rule!(handler, key),
            params,
            external_state,
            acc0,
            :steps_only
          )

        {:steps_done, acc2.params, acc2.state, external_state, acc2}

      :full ->
        {acc2, proposed} = exec_from(handler, key, entry_rule!(handler, key), params, external_state, acc0, :full)
        apply_exit(handler, {state_name, event}, proposed, acc2)
    end
  end

  @spec replay(module, {atom, atom}, map(), any, ExFSM.Acc.t(), keyword) ::
          {:next_state, atom, any, ExFSM.Acc.t()}
          | {:keep_state, atom, any, ExFSM.Acc.t()}
          | {:error, term, ExFSM.Acc.t()}
          | {:steps_done, map(), map(), any, ExFSM.Acc.t()}
  def replay(
        handler,
        {state_name, event} = key,
        base_params,
        external_state,
        %ExFSM.Acc{} = acc,
        opts \\ []
      ) do
    mode = Keyword.get(opts, :mode, :full)

    # Prépare params (override/merge)
    params1 =
      case {Keyword.get(opts, :params_override), Keyword.get(opts, :merge_params)} do
        {nil, nil} -> base_params
        {ov, nil} when is_map(ov) -> ov
        {nil, m} when is_map(m) -> Map.merge(base_params, m)
        # ov prioritaire, puis merge
        {ov, m} when is_map(ov) and is_map(m) -> Map.merge(ov, m)
        _ -> base_params
      end

    # Init meta avec l'external_state et les params de (re)lancement
    ExFSM.Meta.init(external_state, params1, acc)

    # Déterminer le point de reprise
    start_rule =
      case Keyword.get(opts, :from) do
        r when not is_nil(r) and is_atom(r) -> r
        _ -> pick_replay_start_rule(acc)
      end

    cond do
      acc.exit != nil and start_rule == nil ->
        # Déjà sorti ET rien à rejouer → juste appliquer la sortie si :full
        proposed = derive_next_state(acc)

        case mode do
          :steps_only -> {:steps_done, acc.params, acc.state, external_state, acc}
          :full -> apply_exit(handler, {state_name, event}, proposed, acc)
        end

      true ->
        # Applique éventuellement des params sur l'acc (si override/merge voulus)
        acc1 =
          if params1 != acc.params,
            do: %ExFSM.Acc{acc | params: params1},
            else: acc

        case mode do
          :steps_only ->
            {acc2, _prop} =
              exec_from(
                handler,
                key,
                start_rule || entry_rule!(handler, key),
                acc1.params,
                acc1.state,
                acc1,
                :steps_only
              )

            {:steps_done, acc2.params, acc2.state, external_state, acc2}

          :full ->
            {acc2, proposed} =
              exec_from(
                handler,
                key,
                start_rule || entry_rule!(handler, key),
                acc1.params,
                acc1.state,
                acc1,
                :full
              )

            apply_exit(handler, {state_name, event}, proposed, acc2)
        end
    end
  end

  # --------- helpers replay ---------

  # 1) 1ère règle à rejouer : la première avec tag != :ok (depuis le début)
  # steps est stocké "newest first" (on cons au head)
  defp pick_replay_start_rule(%ExFSM.Acc{steps: []}), do: nil

  # 1) Cas le plus fréquent: on a déjà quitté par une règle non-ok (chosen: :exit)
  defp pick_replay_start_rule(%ExFSM.Acc{steps: [%{chosen: :exit, rule: r} | _]}), do: r

  defp pick_replay_start_rule(%ExFSM.Acc{steps: steps} = _acc) do
    # plus ancien -> plus récent
    chrono = Enum.reverse(steps)

    # 2) Première règle non-ok en ordre chronologique
    case Enum.find(chrono, fn step -> step.tag != :ok end) do
      %{rule: r} ->
        r

      nil ->
        # 3) Tout était ok et pas d'exit -> on tente la "prochaine" après la dernière
        case List.last(chrono) do
          # si la dernière a choisi une autre règle, on repart de celle-ci
          %{chosen: r} when is_atom(r) and r != :exit -> r
          _ -> nil
        end
    end
  end

  defp derive_next_state(%ExFSM.Acc{exit: {tag, payload}})
       when tag in [:ok, :warning, :error] and is_atom(payload),
       do: payload

  defp derive_next_state(%ExFSM.Acc{}), do: nil

  defp entry_rule!(handler, key), do: apply(handler, :__rules_entry__, [key])

  # ----------------------------- Remaining ------------------------------------

  def plan_from(mod, {st, ev}, from_rule) do
    %{graph: graph, weights: weights0} =
      Map.get(mod.rules_graph(), {st, ev}) ||
        raise ArgumentError, "No ruleset for #{inspect({st, ev})}"

    weights = normalize_weights(weights0)
    do_plan(graph, weights, from_rule, [])
  end

  @doc """
  Steps “restants” selon le plan nominal (plan – rules :ok déjà passées).
  """
  def remaining_rules(state, {_st, ev} = key, rules_applied) do
    # 1/ resolve handler pour être sûr du module
    handler =
      ExFSM.Machine.find_handlers({state, ev, %{}}) |> List.first() ||
        raise ArgumentError, "No handler for #{inspect(key)}"

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

  # -------- Dry Run ----------

  @doc """
  Dry-run structurel : ne touche pas aux rules, renvoie seulement plan, graph et entry.
  """
  @spec dry_run(module, {atom, atom}) :: {:ok, %{plan: [atom], graph: map, entry: atom}}
  def dry_run(mod, key) do
    %{entry: entry, graph: graph, weights: weights} =
      Map.get(mod.rules_graph(), key) ||
        raise ArgumentError, "No ruleset for #{inspect(key)}"

    {:ok, %{plan: plan_path(graph, weights, entry), graph: graph, entry: entry}}
  end

  # -------- core ----------

  defp exec_from(_handler, _key, :exit, params, state_flow, %ExFSM.Acc{} = acc, _mode) do
    acc2 = %{acc | params: params, state: state_flow, exit: acc.exit || {:ok, :done}}
    ExFSM.Meta.update_acc(acc2)
    {acc2, derive_next_state(acc2)}
  end

  defp exec_from(handler, key, rule, params, state_flow, %ExFSM.Acc{} = acc, mode) do
    t0 = System.monotonic_time()

    case apply(handler, :"__rule__#{rule}", [params, state_flow]) do
      {:__next__, next_rule, params2, state2, tag} ->
        step = %{
          rule: rule,
          tag: tag,
          in: %{params: params, state: acc.state},
          out: %{params: params2, state: state2},
          chosen: next_rule,
          time_ms: dt_ms(t0)
        }

        acc2 = %ExFSM.Acc{acc | params: params2, state: state2, steps: [step | acc.steps]}
        ExFSM.Meta.update_acc(acc2)
        exec_from(handler, key, next_rule, params2, state2, acc2, mode)

      {:__exit__, payload, params2, state2, tag} ->
        step = %{
          rule: rule,
          tag: tag,
          in: %{params: params, state: acc.state},
          out: %{params: params2, state: state2},
          chosen: :exit,
          time_ms: dt_ms(t0)
        }

        acc2 = %ExFSM.Acc{
          acc
          | params: params2,
            state: state2,
            steps: [step | acc.steps],
            exit: {tag, payload}
        }

        ExFSM.Meta.update_acc(acc2)
        {acc2, derive_next_state(acc2)}

      other ->
        raise ArgumentError,
              "defrule #{inspect(rule)} must return {:__next__|:__exit__}, got: #{inspect(other)}"
    end
  end

  defp apply_exit(handler, {state_name, event}, proposed_next_state, %ExFSM.Acc{} = acc) do
    out_fun =
      case function_exported?(handler, :rules_outputs, 0) do
        true -> Map.get(handler.rules_outputs(), {state_name, event})
        false -> nil
      end || :__rules_exit__

    case apply(handler, out_fun, [acc.params, acc.state, proposed_next_state]) do
      {:next_state, name, new_external_state} -> {:next_state, name, new_external_state, acc}
      {:keep_state, name, same_external_state} -> {:keep_state, name, same_external_state, acc}
      {:error, reason} -> {:error, reason, acc}
      other -> {:error, {:invalid_rules_exit_return, other}, acc}
    end
  end

  defp dt_ms(t0),
    do: System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

  # ---- runtime plannification helpers ----------------------------------------
  defp plan_path(graph, weights, entry) do
    do_plan(graph, weights, entry, [])
  end

  defp do_plan(_graph, _weights, nil, acc), do: Enum.reverse(acc)

  defp do_plan(graph, weights, rule, acc) do
    acc2 = acc ++ [rule]
    nexts = get_in(graph, [rule, :next]) || []

    case nexts do
      [] ->
        acc2

      ls ->
        next =
          ls
          |> Enum.sort_by(fn r -> {-Map.get(weights, r, 0), to_string(r)} end)
          |> List.first()

        do_plan(graph, weights, next, acc2)
    end
  end

  # ---- runtime normalization helpers ----------------------------------------
  defp normalize_weights(w) when is_map(w), do: w
  defp normalize_weights(w) when is_list(w), do: Map.new(w)
  defp normalize_weights(_), do: %{}
end
