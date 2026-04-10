defmodule MomFSM do
  defmacro __before_compile__(_env) do
    quote do
      def evaluate(obj, params), do: MomFSM.evaluate(__MODULE__, obj, params)

      def set_state_name(transaction, name, handlers),
        do: MomFSM.set_state_name(__MODULE__, transaction, name, handlers)

      def get_switch_statuses(), do: MomFSM.Utils.get_switch_statuses(__MODULE__)
      def all_used_fsms(), do: MomFSM.Utils.all_used_fsms(__MODULE__)
      def all_possible_statuses(), do: MomFSM.Utils.all_statuses_by_fsm(__MODULE__)

      def get_mapping(from \\ :init, to \\ nil),
        do: MomFSM.Traversal.get_mapping(__MODULE__, %{from: from, to: to})

      def get_mapping_out(), do: @mapping_out

      def temp_chart(), do: MomFSM.temp_chart(__MODULE__)
    end
  end

  defmacro __using__(_opts) do
    quote do
      import MomFSM
      @before_compile MomFSM
      @after_compile MomFSM
      use ExFSM
      @mapping_out %{}
    end
  end

  defmacro __after_compile__(_, _) do
    quote do
    end
  end

  def temp_chart(module) do
    replace_elixir = fn m -> String.replace(Atom.to_string(m), "Elixir.", "") end

    links_between_fsm =
      MomFSM.Utils.get_formatted_transitions(module)
      |> Enum.group_by(fn [from, _, _] -> from end, fn [_, _, fsm] -> fsm end)

    str =
      MomFSM.Utils.all_used_fsms(module)
      |> Enum.map(fn fsm ->
        fsm_name = replace_elixir.(fsm)

        {formatted, links} =
          MomFSM.Utils.get_formatted_transitions(fsm)
          |> Enum.reduce({[], []}, fn [from, trans, to], {acc, links} ->
            new = "#{fsm_name}.#{from} --> |#{trans}| #{fsm_name}.#{to}"

            lbf =
              if !is_nil(fsms = links_between_fsm[to]) do
                Enum.map(fsms, fn fsm -> "#{fsm_name}.#{to} --> #{replace_elixir.(fsm)}.#{to}" end)
              end || []

            {[new | acc], links ++ lbf}
          end)

        formatted = Enum.join(formatted, "\n\t\t")
        links = Enum.join(links, "\n\t")

        """
            subgraph #{fsm_name}
                #{formatted}
            end
            #{links}
        """
      end)
      |> Enum.join("\n\n")

    str = """
    graph TD;
    #{str}
    """

    File.write!("data/export.txt", str)
  end

  # Chooses which FSM should be used for the given object and params.
  def evaluate(module, obj, params) do
    fake_obj = Map.put(obj, :type, module)

    # if action is not available you dont need to change the current FSM so you use the current one
    res =
      case ExFSM.Machine.action_available?(fake_obj, params, :evaluate) do
        true ->
          case ExFSM.Machine.event(fake_obj, {:evaluate, params}) do
            {:use, res} when is_list(res) ->
              {:ok, res}

            {:use, res} ->
              {:ok, [res]}

            {:error, error} ->
              {:error, error}

            error ->
              {:error, error}
          end

        false ->
          {:ok, obj[:current_fsm]}
      end

    case res do
      {:ok, res} ->
        res

      {:error, error} ->
        IO.inspect(error)
        nil
    end
  end

  # # set state + current_fsm if needed
  def set_state_name(module, transaction, name, handlers) do
    old_state = transaction[:status][:state]

    if old_state in module.get_switch_statuses() do
      # It would be better to have the current_fsm directly from exFSM. Not a huge change
      put_in(transaction, [:status, :state], name)
      |> put_in([:current_fsm], handlers)
    else
      put_in(transaction, [:status, :state], name)
    end
  end

  # declare a simplified deftrans
  defmacro defusefsm({name, line, [state, params]}, body) do
    header = {name, line, [{:evaluate, params}, state]}

    quote do
      @to unquote(Enum.uniq(MomFSM.Utils.find_fsm_use(body[:do])))
      deftrans(unquote(header), do: unquote(body[:do]))
    end
  end

  defmodule Traversal do
    def get_mapping(module, opts \\ %{}) do
      from = opts[:from]
      to = opts[:to]
      transitions = MomFSM.Utils.get_formatted_transitions(module)

      all_fsms_used =
        transitions
        |> Enum.map(&List.last/1)
        |> Enum.uniq()
        |> Map.new(&{&1, MomFSM.Utils.get_formatted_transitions(&1)})

      all_possibilities =
        transitions
        |> Enum.reduce([], fn [start, _, fsm], acc ->
          result = init_traverse(all_fsms_used[fsm], start)
          acc ++ Enum.map(result, &{start, fsm, &1})
        end)
        |> Enum.group_by(fn {start, _fsm, res} -> {start, List.last(res)} end, fn {_, fsm, res} ->
          {fsm, res}
        end)
        |> Enum.map(fn {{from, to}, v} ->
          [from, Enum.group_by(v, &elem(&1, 0), &elem(&1, 1)), to]
        end)

      if is_nil(from) do
        Map.new(module.get_switch_statuses(), &{&1, init_traverse(all_possibilities, &1, to)})
      else
        init_traverse(all_possibilities, from, to)
      end
    end

    def init_traverse(all_transitions, starting_status, ending_status \\ nil) do
      group_by_status_in = Enum.group_by(all_transitions, fn [i, _, _] -> i end)
      start = group_by_status_in[starting_status] || []
      status_done = start |> Map.new(&{&1, 1})
      results = traverse_v3(start, start, status_done, group_by_status_in)

      cond do
        is_nil(ending_status) ->
          results

        is_list(ending_status) ->
          Enum.filter(results, fn list -> List.last(list) in ending_status end)

        true ->
          Enum.filter(results, fn list -> List.last(list) == ending_status end)
      end
    end

    def remove_last(list) when is_list(list), do: :lists.reverse(list) |> tl() |> :lists.reverse()

    @doc """
    Utility: full graph traversal producing all possible paths.

    **Not intended for use in hot paths or production call stacks.**
    The number of paths can grow exponentially with the size of the transition
    graph. Use only for offline introspection, visualisation, or test helpers.
    """
    def traverse_v3(transitions, acc, status_done, statuses_in) do
      Enum.reduce(transitions, acc, fn possibility, acc ->
        last = List.last(possibility)

        add_to_status_done =
          (statuses_in[last] || []) |> Enum.filter(&((status_done[&1] || 0) < 1))

        next_possibilities = add_to_status_done |> Enum.map(&(remove_last(possibility) ++ &1))

        case next_possibilities do
          [] ->
            acc

          _ ->
            new_status_done =
              Enum.reduce(add_to_status_done, status_done, fn status, acc ->
                put_in(acc, [status], (acc[status] || 0) + 1)
              end)

            acc ++
              traverse_v3(next_possibilities, next_possibilities, new_status_done, statuses_in)
        end
      end)
    end
  end

  defmodule Utils do
    def get_formatted_transitions(module) do
      module.fsm()
      |> Enum.reduce(MapSet.new(), fn {{status, tname}, {_module, next_status_or_fsm_list}},
                                      acc ->
        MapSet.new(next_status_or_fsm_list, &[status, tname, &1]) |> MapSet.union(acc)
      end)
      |> Enum.to_list()
    end

    def get_switch_statuses(module),
      do: Enum.map(module.fsm, fn {{status, _}, _} -> status end) |> Enum.uniq()

    def all_used_fsms(module),
      do: Enum.flat_map(module.fsm, fn {_, {_, fsms}} -> fsms end) |> Enum.uniq()

    def all_statuses_by_fsm(module),
      do: Map.new(all_used_fsms(module), &{&1, all_statuses_in_fsm(&1)})

    def all_statuses_in_fsm(module_fsm) do
      module_fsm.fsm()
      |> Enum.reduce(MapSet.new(), fn {{from, _}, {_, to}}, acc ->
        MapSet.union(acc, MapSet.new([from | to]))
      end)
    end

    def send_warning(msg, module, _line \\ 0), do: IO.warn("#{module}: #{msg}")

    # from exfsm
    def find_fsm_use({:use, {_, _, smth}}), do: [Module.concat(smth)]
    def find_fsm_use({_, _, asts}), do: find_fsm_use(asts)
    def find_fsm_use({_, asts}), do: find_fsm_use(asts)
    def find_fsm_use(asts) when is_list(asts), do: Enum.flat_map(asts, &find_fsm_use/1)
    def find_fsm_use(_), do: []
  end
end
