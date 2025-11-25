Mix.Task.run("app.start")

[mod_str] =
  case System.argv() do
    [m] -> [m]
    _ ->
      IO.puts("Usage: mix run priv/tasks/viz_global.exs <HandlerModule>")
      System.halt(1)
  end

handler = Module.concat([mod_str])
mmd = ExFSM.Visualizer.mermaid_global(handler)

out_dir = "tmp/viz"
File.mkdir_p!(out_dir)
mmd_path = Path.join(out_dir, "global.mmd")
svg_path = Path.rootname(mmd_path) <> ".svg"

File.write!(mmd_path, mmd)
IO.puts("→ Mermaid : #{mmd_path}")
IO.puts("mmdc -i #{mmd_path} -o #{svg_path}")
