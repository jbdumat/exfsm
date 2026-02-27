# priv/tasks/dump_acc.exs
Mix.Task.run("app.start")

acc = ""

json =
  acc
  |> ExFSM.AccJSON.encode()
  |> Poison.encode!(pretty: true)

File.mkdir_p!("data")
File.write!("data/acc_dump.json", json)

IO.puts("→ dump écrit : data/acc_dump.json")
