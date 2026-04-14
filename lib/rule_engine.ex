defmodule ExFSM.RuleEngine do
  @moduledoc """
  Executes rule graphs declared by `deftrans_rules`.

  Two execution modes:
    * `:full` — traverses all rules, then calls `defrules_exit` handler.
      Returns `{:next_state, atom, state, acc}` or `{:error, reason, acc}`.
    * `:steps_only` — traverses rules and records steps in the accumulator
      without calling the exit handler. Returns `{:steps_done, params, state, ext_state, acc}`.

  Also supports:
    * `replay/6` — re-runs from the first non-ok step (or a targeted rule via `:from` option).
    * `dry_run/2` — structural plan inspection without executing any rules.
    * `remaining_rules/3` — returns the planned rules not yet executed.
  """
  @type tag :: :ok | :warning | :error

  @spec run(module, {atom, atom}, map(), any, keyword) ::
          {:next_state, atom, any, ExFSM.Acc.t()}
          | {:error, term, ExFSM.Acc.t()}
          | {:steps_done, map(), map(), any, ExFSM.Acc.t()}
  def run(handler, {state_name, event} = key, params, external_state, opts \\ []) do
    fsm_mode = Keyword.get(opts, :fsm_mode, :full)

    acc0 = %ExFSM.Acc{params: params, state: external_state, steps: [], exit: nil}
    ExFSM.Meta.init(external_state, params, acc0)

    case fsm_mode do
      :steps_only ->
        {acc2, _prop} =
          exec_from(
            handler,
            key,
            entry_rule!(handler, key),
            params,
            external_state,
            acc0,
            :steps_only,
            MapSet.new()
          )

        {:steps_done, acc2.params, acc2.state, external_state, acc2}

      :full ->
        {acc2, proposed} =
          exec_from(
            handler,
            key,
            entry_rule!(handler, key),
            params,
            external_state,
            acc0,
            :full,
            MapSet.new()
          )

        apply_exit(handler, {state_name, event}, proposed, acc2)
    end
  end

  @spec replay(module, {atom, atom}, map(), any, ExFSM.Acc.t(), keyword) ::
          {:next_state, atom, any, ExFSM.Acc.t()}
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
    fsm_mode = Keyword.get(opts, :fsm_mode, :full)

    # Prepare params (override/merge)
    params1 =
      case {Keyword.get(opts, :params_override), Keyword.get(opts, :merge_params)} do
        {nil, nil} -> base_params
        {ov, nil} when is_map(ov) -> ov
        {nil, m} when is_map(m) -> Map.merge(base_params, m)
        # override takes priority, then merge
        {ov, m} when is_map(ov) and is_map(m) -> Map.merge(ov, m)
        _ -> base_params
      end

    # Init meta with the external_state and the (re)launch params
    ExFSM.Meta.init(external_state, params1, acc)

    # Determine the replay start point
    start_rule =
      case Keyword.get(opts, :from) do
        r when not is_nil(r) and is_atom(r) -> r
        _ -> pick_replay_start_rule(acc)
      end

    cond do
      acc.exit != nil and start_rule == nil ->
        # Already exited AND nothing to replay -> just apply exit if :full
        proposed = derive_next_state(acc)

        case fsm_mode do
          :steps_only -> {:steps_done, acc.params, acc.state, external_state, acc}
          :full -> apply_exit(handler, {state_name, event}, proposed, acc)
        end

      true ->
        # Optionally apply param overrides on the acc
        acc1 =
          if params1 != acc.params,
            do: %ExFSM.Acc{acc | params: params1},
            else: acc

        case fsm_mode do
          :steps_only ->
            {acc2, _prop} =
              exec_from(
                handler,
                key,
                start_rule || entry_rule!(handler, key),
                acc1.params,
                acc1.state,
                acc1,
                :steps_only,
                MapSet.new()
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
                :full,
                MapSet.new()
              )

            apply_exit(handler, {state_name, event}, proposed, acc2)
        end
    end
  end

  # --------- replay helpers ---------

  # First rule to replay: the first with tag != :ok (from the start).
  # Steps are stored newest-first (consed to head).
  defp pick_replay_start_rule(%ExFSM.Acc{steps: []}), do: nil

  # Most common case: already exited via a non-ok rule (chosen: :exit)
  defp pick_replay_start_rule(%ExFSM.Acc{steps: [%{chosen: :exit, rule: r} | _]}), do: r

  defp pick_replay_start_rule(%ExFSM.Acc{steps: steps} = _acc) do
    # oldest -> newest
    chrono = Enum.reverse(steps)

    # First non-ok rule in chronological order
    case Enum.find(chrono, fn step -> step.tag != :ok end) do
      %{rule: r} ->
        r

      nil ->
        # Everything was ok and no exit -> try the "next" after the last rule
        case List.last(chrono) do
          # if the last step chose another rule, restart from it
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
    do_plan(graph, weights, from_rule, [], MapSet.new()) |> Enum.reverse()
  end

  @doc """
  Remaining steps according to the nominal plan (plan minus already-ok rules).
  """
  def remaining_rules(state, {_st, ev} = key, rules_applied) do
    # 1/ resolve handler to be sure of the module
    handler =
      ExFSM.Machine.find_handlers({state, ev, %{}}) |> List.first() ||
        raise ArgumentError, "No handler for #{inspect(key)}"

    # 3/ If no rules were executed: full plan from the entry
    case rules_applied do
      [] ->
        %{entry: entry} = Map.fetch!(handler.rules_graph(), key)
        plan_from(handler, key, entry)

      applied when is_list(applied) ->
        # Last successful rule (ok/warn) -- warn is tolerated as progression
        last =
          applied
          |> Enum.reverse()
          |> Enum.find(fn e -> e.tag in [:ok, :warn] end)

        cond do
          is_nil(last) ->
            %{entry: entry} = Map.fetch!(handler.rules_graph(), key)
            plan_from(handler, key, entry)

          true ->
            from_rule = Map.get(last, :chosen) || Map.get(last, :rule)
            full = plan_from(handler, key, from_rule)

            # Remove nodes already "ok/warn" after this point
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
  Structural dry-run: does not execute rules, returns only plan, graph and entry.
  """
  @spec dry_run(module, {atom, atom}) :: {:ok, %{plan: [atom], graph: map, entry: atom}}
  def dry_run(mod, key) do
    %{entry: entry, graph: graph, weights: weights} =
      Map.get(mod.rules_graph(), key) ||
        raise ArgumentError, "No ruleset for #{inspect(key)}"

    {:ok, %{plan: plan_path(graph, weights, entry), graph: graph, entry: entry}}
  end

  # -------- core ----------

  defp exec_from(
         _handler,
         key,
         :exit,
         params,
         state_flow,
         %ExFSM.Acc{} = acc,
         _fsm_mode,
         _visited
       ) do
    exit_val =
      case acc.exit do
        nil ->
          # A defrule routed next_rule to :exit without calling rules_exit/4.
          # This is a graph authoring mistake: rules_exit/4 must always be used to
          # terminate a rule chain. We surface it as an error rather than silently
          # returning {:ok, :done}.
          raise ArgumentError,
                "A rule in #{inspect(key)} routed to :exit without calling rules_exit/4. " <>
                  "Use rules_exit(payload, params, state, tag) to terminate a rule chain."

        val ->
          val
      end

    acc2 = %{acc | params: params, state: state_flow, exit: exit_val}
    ExFSM.Meta.update_acc(acc2)
    {acc2, derive_next_state(acc2)}
  end

  defp exec_from(handler, key, rule, params, state_flow, %ExFSM.Acc{} = acc, fsm_mode, visited) do
    if MapSet.member?(visited, rule) do
      raise ArgumentError,
            "Cycle detected in #{inspect(key)}: rule #{inspect(rule)} was already visited. " <>
              "Visited rules: #{inspect(MapSet.to_list(visited))}"
    end

    visited = MapSet.put(visited, rule)
    t0 = System.monotonic_time()

    case apply(handler, :"__rule__#{rule}", [params, state_flow]) do
      {:__next__, next_rule, params2, state2, tag} ->
        step = %{
          rule: rule,
          tag: tag,
          in: %{params: params, state: acc.state},
          out: %{params: params2, state: state2},
          chosen: next_rule,
          time_us: dt_us(t0)
        }

        acc2 = %ExFSM.Acc{acc | params: params2, state: state2, steps: [step | acc.steps]}
        ExFSM.Meta.update_acc(acc2)
        exec_from(handler, key, next_rule, params2, state2, acc2, fsm_mode, visited)

      {:__exit__, payload, params2, state2, tag} ->
        step = %{
          rule: rule,
          tag: tag,
          in: %{params: params, state: acc.state},
          out: %{params: params2, state: state2},
          chosen: :exit,
          time_us: dt_us(t0)
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
      end

    cond do
      is_nil(out_fun) ->
        {:error, {:missing_rules_exit, {state_name, event}}, acc}

      not function_exported?(handler, out_fun, 3) ->
        {:error, {:missing_rules_exit, {state_name, event}}, acc}

      true ->
        case apply(handler, out_fun, [acc.params, acc.state, proposed_next_state]) do
          {:next_state, name, new_external_state} ->
            {:next_state, name, new_external_state, acc}

          {:keep_state_name, new_external_state} ->
            {:next_state, state_name, new_external_state, acc}

          :keep_state ->
            {:next_state, state_name, acc.state, acc}

          {:error, reason} ->
            {:error, reason, acc}

          other ->
            {:error, {:invalid_rules_exit_return, other}, acc}
        end
    end
  end

  defp dt_us(t0),
    do: System.convert_time_unit(System.monotonic_time() - t0, :native, :microsecond)

  # ---- runtime plannification helpers ----------------------------------------
  defp plan_path(graph, weights, entry) do
    do_plan(graph, weights, entry, [], MapSet.new()) |> Enum.reverse()
  end

  defp do_plan(_graph, _weights, nil, acc, _visited), do: acc

  defp do_plan(graph, weights, rule, acc, visited) do
    if MapSet.member?(visited, rule) do
      # Cycle detected: stop traversal here, do not infinite-loop
      acc
    else
      acc2 = [rule | acc]
      visited2 = MapSet.put(visited, rule)
      nexts = get_in(graph, [rule, :next]) || []

      case nexts do
        [] ->
          acc2

        ls ->
          next =
            ls
            |> Enum.sort_by(fn r -> {-Map.get(weights, r, 0), to_string(r)} end)
            |> List.first()

          do_plan(graph, weights, next, acc2, visited2)
      end
    end
  end

  # ---- runtime normalization helpers ----------------------------------------
  defp normalize_weights(w) when is_map(w), do: w
  defp normalize_weights(w) when is_list(w), do: Map.new(w)
  defp normalize_weights(_), do: %{}
end
