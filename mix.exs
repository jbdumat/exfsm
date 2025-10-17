defmodule ExFSM.V2.Mixfile do
  use Mix.Project

  def project do
    [
      app: :exfsm_v2,
      version: "0.1.6",
      elixir:
        if Mix.env() == :dev do
          ">= 1.15.0"
        else
          ">= 1.11.0"
        end,
      build_embedded: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      docs: [
        main: "ExFSM.V2",
        source_url: "https://github.com/kbrw/exfsm/tree/v0.1.6",
        source_ref: "master"
      ],
      description: """
        Simple elixir library to define composable FSM as function
        (not related at all with `:gen_fsm`, no state/process management)
      """,
      package: [
        maintainers: ["Arnaud Wetzel"],
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/kbrw/exfsm",
          "Doc" => "http://hexdocs.pm/exfsm"
        }
      ],
      deps: [
        {:ex_doc, ">= 0.0.0", only: :dev}
      ]
    ]
  end
end
