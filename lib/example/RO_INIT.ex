# defmodule RO.Init.Resa do
#   @moduledoc """
#   FSM de démonstration avec un **graphe dense** (bifurcations), pour tests visuels.
#   - Transitions: {:init,:go} et {:review,:proceed}
#   - Rules: :a..:p (plusieurs chemins, warnings & erreurs)
#   - Paramètres de pilotage:
#       * params.path : :ok_path | :warn_path | :error_path | :mix_path
#       * params.flags : MapSet (ex: MapSet.new([:fast_track, :needs_review, :skip_validation]))
#   - State shape (indicatif): %{__state__: atom(), seq: [atom()], ctx?: any()}
#   """

#   use ExFSM
#   use ExFSM.Rule.DSL

#   defimpl ExFSM.Machine.State, for: Map do
#     def handlers(_state, _params) do
#       IO.inspect("Complex FSM")
#       [Example.ComplexFSM]
#     end
#     def state_name(state), do: Map.fetch!(state, :__state__)
#     def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
#   end

#   # --------------------------------------------------------------------
#   # Transition 1 : {:init, :go}
#   # Graphe orienté "pipeline" avec éventails, cycles courts et exits multiples.
#   # --------------------------------------------------------------------
#   deftrans_rules init({:create, params}, state) do
#     # ------------------ Règle d'entrée -------------------
#     defrule create_ro(params, state) do

#       # params -> Information pour creer les lignes
#       # state une ro vide

#       #init RO -> create header
#       # RO.System.format_ro()

#       next_rule(:create_lines, {params, state}, :ok)
#     end

#     defrule create_lines(params, state) do
#       process = Task.await_many([
#         Task.aync(ExFSM.Machine.create(...))
#       ])
#       result = process.await()

#       next_rules(:process_lines, params ++ result, state)
#     end

#     defrule process_lines(params, state) do
#       spawn(...) # call good movement creation
#       rules_exit(...)
#     end

#   defrules_commit(entry: :create)

#   # # Même mapping d’`acc.exit` → next_state
#   defrules_exit(_new_params, new_state, _proposed) do
#     meta = ExFSM.meta()
#     case meta.acc.exit do
#       {:ok, _}      -> {:next_state, :active,   new_state}
#       {:warning, _} -> {:next_state, :line_creation_warning, new_state}
#       {:error, _}   -> {:next_state, :line_creation_error, new_state}
#       _             -> {:next_state, :unknown,new_state}
#     end
#   end
# end

# defmodule RO.Init.NominalPath do
#   @moduledoc """
#   FSM de démonstration avec un **graphe dense** (bifurcations), pour tests visuels.
#   - Transitions: {:init,:go} et {:review,:proceed}
#   - Rules: :a..:p (plusieurs chemins, warnings & erreurs)
#   - Paramètres de pilotage:
#       * params.path : :ok_path | :warn_path | :error_path | :mix_path
#       * params.flags : MapSet (ex: MapSet.new([:fast_track, :needs_review, :skip_validation]))
#   - State shape (indicatif): %{__state__: atom(), seq: [atom()], ctx?: any()}
#   """

#   use ExFSM

#   deftrans_rules init({:create, params}, state) do
#     # ------------------ Règle d'entrée -------------------
#     defrule create_ro(params, state) do

#       # params -> Information pour creer les lignes
#       # state une ro vide

#       #init RO -> create header
#       # RO.System.format_ro()

#       next_rule(:create_lines, {params, state}, :ok)
#     end

#     defrule create_lines(params, state) do
#       process = Task.await_many([
#         Task.aync(ExFSM.Machine.create(...))
#       ])
#       result = process.await()

#       next_rules(:process_lines, params ++ result, state)
#     end

#   defrules_commit(entry: :create)

#   # # Même mapping d’`acc.exit` → next_state
#   defrules_exit(_new_params, new_state, _proposed) do
#     meta = ExFSM.meta()
#     case meta.acc.exit do
#       {:ok, _}      -> {:next_state, :active,   new_state}
#       {:warning, _} -> {:next_state, :line_creation_warning, new_state}
#       {:error, _}   -> {:next_state, :line_creation_error, new_state}
#       _             -> {:next_state, :unknown,new_state}
#     end
#   end
# end

# defmodule RO.Init.SourcingAtStart do
#   @moduledoc """
#   FSM de démonstration avec un **graphe dense** (bifurcations), pour tests visuels.
#   - Transitions: {:init,:go} et {:review,:proceed}
#   - Rules: :a..:p (plusieurs chemins, warnings & erreurs)
#   - Paramètres de pilotage:
#       * params.path : :ok_path | :warn_path | :error_path | :mix_path
#       * params.flags : MapSet (ex: MapSet.new([:fast_track, :needs_review, :skip_validation]))
#   - State shape (indicatif): %{__state__: atom(), seq: [atom()], ctx?: any()}
#   """

#   use ExFSM
#   use ExFSM.Rule.DSL

#   deftrans_rules init({:create, params}, state) do
#     # ------------------ Règle d'entrée -------------------
#     defrule create_ro(params, state) do

#       # params -> Information pour creer les lignes
#       # state une ro vide

#       #init RO -> create header
#       # RO.System.format_ro()

#       next_rule(:create_lines, {params, state}, :ok)
#     end

#     defrule create_lines(params, state) do
#       process = Task.await_many([
#         Task.aync(ExFSM.Machine.create(...))
#       ])
#       result = process.await()

#       next_rules(:call_atp, params ++ result, state)
#     end

#     defrule call_atp(params, state) do
#       rules_exit(...)
#     end

#   defrules_commit(entry: :create)

#   # # Même mapping d’`acc.exit` → next_state
#   defrules_exit(_new_params, new_state, _proposed) do
#     meta = ExFSM.meta()
#     case meta.acc.exit do
#       {:ok, _}      -> {:next_state, :active,   new_state}
#       {:warning, _} -> {:next_state, :line_creation_warning, new_state}
#       {:error, _}   -> {:next_state, :line_creation_error, new_state}
#       _             -> {:next_state, :unknown,new_state}
#     end
#   end
# end
