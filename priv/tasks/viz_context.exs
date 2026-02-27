# Usage :
#   mix run priv/tasks/viz_context.exs Example.ComplexFSM data/acc.json
#   mix run priv/tasks/viz_context.exs Example.ComplexFSM data/acc_chain.json
#
# - Si le JSON est un objet (map), il est interprété comme un acc unique.
# - Si le JSON est une liste, chaque élément doit contenir "transition": ["state","event"],
#   et sera mappé vers %{{state,event} => acc_map} pour le visualizer.

Mix.Task.run("app.start")

[mod_str, json_path] =
  case System.argv() do
    [m, p] -> [m, p]
    _ ->
      IO.puts("""
      Usage:
        mix run priv/tasks/viz_context.exs <HandlerModule> <acc_or_chain.json>

      <HandlerModule> doit être le nom complet du module handler (ex: Example.ComplexFSM)
      <acc_or_chain.json> :
        - soit un acc unique (objet JSON)
        - soit une liste d'accs encodés (AccJSON.encode_chain/1)
      """)
      System.halt(1)
  end

handler = Module.concat([mod_str])

{:ok, bin} =
  File.read(json_path)

{:ok, data} = Poison.decode(bin)

{acc_or_map, opts} =
  case data do
    # Chaîne multi-transitions (AccJSON.encode_chain/1)
    [%{} | _] = list ->
      pairs =
        list
        |> Enum.map(fn m ->
          case Map.get(m, "transition") do
            [s, e] ->
              key = {String.to_atom(s), String.to_atom(e)}
              {key, m}

            other ->
              raise ArgumentError,
                    "Chaque élément doit avoir \"transition\": [\"state\",\"event\"], reçu: #{inspect(other)}"
          end
        end)

      acc_map = Map.new(pairs)
      order   = Enum.map(pairs, &elem(&1, 0))
      {acc_map, [order: order]}

    # Acc unique
    %{} = m ->
      {m, []}

    other ->
      raise ArgumentError, "Format JSON inattendu: #{inspect(other)}"
  end

mmd = ExFSM.Visualizer.mermaid_context(handler, acc_or_map, opts)

out_dir  = "tmp/viz"
File.mkdir_p!(out_dir)

mmd_path = Path.join(out_dir, "context.mmd")
svg_path = Path.rootname(mmd_path) <> ".svg"

File.write!(mmd_path, mmd)

IO.puts("→ Mermaid context : #{mmd_path}")
IO.puts("Pour générer le SVG :")
IO.puts("  mmdc -i #{mmd_path} -o #{svg_path}")
