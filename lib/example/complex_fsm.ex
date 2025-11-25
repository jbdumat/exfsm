# defmodule Example.ComplexFSM do
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
#   deftrans_rules init({:go, params}, state) do
#     # ------------------ Règle d'entrée -------------------
#     defrule a(params, state) do
#       IO.inspect params
#       # On enrichit la trace "seq"
#       state = put_in(state[:seq], (state[:seq] || []) ++ [:a])

#       cond do
#         params[:path] == :error_path ->
#           # Bifurcation "early error"
#           next_rule({:err_early, params, state}, :error)

#         params[:path] == :warn_path ->
#           # Va vers une branche qui produit des warnings contrôlés
#           next_rule({:b, params, state}, :warning)

#         true ->
#           # Chemin nominal: a -> b
#           next_rule({:b, params, state}, :ok)
#       end
#     end

#     # ------------------ Branche nominale -------------------
#     defrule b(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:b])
#       flags = Map.get(params, :flags, MapSet.new())

#       cond do
#         MapSet.member?(flags, :fast_track) ->
#           # fast-track : on saute la validation classique
#           next_rule({:d, params, state}, :ok)

#         MapSet.member?(flags, :skip_validation) ->
#           # on saute vers une autre zone du graphe (fork)
#           next_rule({:e, params, state}, :ok)

#         true ->
#           # chemin standard : validator
#           next_rule({:c, params, state}, :ok)
#       end
#     end

#     defrule c(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:c])

#       case params[:path] do
#         :mix_path ->
#           # En mix: parfois on lève un warning soft (ex: seuil non bloquant)
#           next_rule({:d, params, state}, :warning)

#         _ ->
#           next_rule({:d, params, state}, :ok)
#       end
#     end

#     defrule d(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:d])

#       cond do
#         params[:path] == :warn_path ->
#           # On part vers un sous-ensemble de rules "atténuées"
#           next_rule({:f, params, state}, :warning)

#         params[:path] == :error_path ->
#           # Erreur tardive (ex: contrôle de cohérence final)
#           next_rule({:err_late, params, state}, :error)

#         true ->
#           # Branching large pour visualiser (d -> e/g/i)
#           _ = :ok
#           next_rule({:e, params, state}, :ok)
#       end
#     end

#     # ------------------ Fourche e -> ... -------------------
#     defrule e(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:e])

#       # Multiples sorties pour densifier le graphe
#       case params[:path] do
#         :mix_path ->
#           # e -> g et parfois e -> h (le graphe retiendra les 2 arêtes)
#           if :rand.uniform() < 0.5 do
#             next_rule({:g, params, state}, :ok)
#           else
#             next_rule({:h, params, state}, :ok)
#           end

#         _ ->
#           next_rule({:g, params, state}, :ok)
#       end
#     end

#     defrule f(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:f])

#       # f -> g (warn branch)
#       next_rule({:g, params, state}, :warning)
#     end

#     defrule g(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:g])

#       # g peut aller vers h ou i selon flags
#       flags = Map.get(params, :flags, MapSet.new())
#       if MapSet.member?(flags, :needs_review) do
#         next_rule({:h, params, state}, :warning)
#       else
#         next_rule({:i, params, state}, :ok)
#       end
#     end

#     defrule h(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:h])

#       # h -> i (post-review)
#       next_rule({:i, params, state}, :ok)
#     end

#     defrule i(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:i])

#       # i -> j/k (bifurcation supplémentaire pour densifier)
#       case params[:path] do
#         :mix_path -> next_rule({:k, params, state}, :ok)
#         _         -> next_rule({:j, params, state}, :ok)
#       end
#     end

#     defrule j(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:j])
#       # j -> m (regroupement)
#       next_rule({:m, params, state}, :ok)
#     end

#     defrule k(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:k])
#       # k -> l -> m (chemin plus long)
#       next_rule({:l, params, state}, :ok)
#     end

#     defrule l(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:l])
#       next_rule({:m, params, state}, :ok)
#     end

#     # ------------------ Regroupement & sorties -------------------
#     defrule m(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:m])

#       # m -> n ou m -> p (sorties)
#       case params[:path] do
#         :error_path ->
#           next_rule({:err_terminal, params, state}, :error)

#         :warn_path ->
#           next_rule({:n, params, state}, :warning)

#         :mix_path ->
#           # densifier les arêtes
#           if :rand.uniform() < 0.3 do
#             next_rule({:n, params, state}, :ok)
#           else
#             next_rule({:p, params, state}, :ok)
#           end

#         _ ->
#           next_rule({:p, params, state}, :ok)
#       end
#     end

#     defrule n(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:n])
#       # Sortie warning
#       rules_exit(%{result: :warned}, params, state, :warning)
#     end

#     defrule p(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:p])
#       # Sortie ok
#       rules_exit(%{result: :done}, params, state, :ok)
#     end

#     # ------------------ Branches d'erreur -------------------
#     defrule err_early(params, state) do
#       state = put_in(state[:seq], (state[:seq] || []) ++ [:err_early])
#       rules_exit(%{error: :early}, params, state, :error)
#     end

#     defrule err_late(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:err_late])
#       rules_exit(%{error: :late}, params, state, :error)
#     end

#     defrule err_terminal(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:err_terminal])
#       rules_exit(%{error: :terminal}, params, state, :error)
#     end

#     # Point d’entrée
#     defrules_commit(entry: :a)
#   end

#   # Mappe l'Acc.exit → transition FSM
#   defrules_exit(_new_params, new_state, next_state) do
#     meta = ExFSM.meta()
#     case meta.acc.exit do
#       {:ok, _}      -> {:next_state, :review, new_state}
#       {:warning, _} -> {:next_state, :warned, new_state}
#       {:error, _}   -> {:next_state, :failed, new_state}
#       _             -> {:next_state, :unknown,new_state}
#     end
#   end

#   # --------------------------------------------------------------------
#   # Transition 2 : {:review, :proceed}
#   # Graphe plus ramifié, convergent vers :z_ok / :z_warn / :z_err.
#   # --------------------------------------------------------------------
#   deftrans_rules review({:proceed, params}, state) do
#     defrule r(params, state) do
#       state = put_in(state[:seq], (state[:seq] || []) ++ [:r])

#       cond do
#         params[:path] == :error_path ->
#           next_rule({:x_err, params, state}, :error)

#         params[:path] == :warn_path ->
#           next_rule({:s, params, state}, :warning)

#         true ->
#           next_rule({:s, params, state}, :ok)
#       end
#     end

#     defrule s(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:s])

#       # fan-out lourd
#       case params[:path] do
#         :mix_path ->
#           if :rand.uniform() < 0.5, do: next_rule({:t, params, state}, :ok), else: next_rule({:u, params, state}, :ok)
#         _ ->
#           next_rule({:t, params, state}, :ok)
#       end
#     end

#     defrule t(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:t])
#       next_rule({:v, params, state}, :ok)
#     end

#     defrule u(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:u])
#       next_rule({:v, params, state}, :ok)
#     end

#     defrule v(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:v])
#       # v -> w | y
#       if params[:path] == :warn_path do
#         next_rule({:w, params, state}, :warning)
#       else
#         next_rule({:y, params, state}, :ok)
#       end
#     end

#     defrule w(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:w])
#       next_rule({:y, params, state}, :warning)
#     end

#     defrule y(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:y])

#       case params[:path] do
#         :error_path -> next_rule({:z_err,  params, state}, :error)
#         :warn_path  -> next_rule({:z_warn, params, state}, :warning)
#         _           -> next_rule({:z_ok,   params, state}, :ok)
#       end
#     end

#     defrule x_err(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:x_err])
#       rules_exit(%{review: :hard_fail}, params, state, :error)
#     end

#     defrule z_err(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:z_err])
#       rules_exit(%{review: :err}, params, state, :error)
#     end

#     defrule z_warn(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:z_warn])
#       rules_exit(%{review: :warn}, params, state, :warning)
#     end

#     defrule z_ok(params, state) do
#       state = put_in(state[:seq], state[:seq] ++ [:z_ok])
#       rules_exit(%{review: :ok}, params, state, :ok)
#     end

#     defrules_commit(entry: :r)
#   end

#   # # Même mapping d’`acc.exit` → next_state
#   defrules_exit(_new_params, new_state, _proposed) do
#     meta = ExFSM.meta()
#     case meta.acc.exit do
#       {:ok, _}      -> {:next_state, :done,   new_state}
#       {:warning, _} -> {:next_state, :warned, new_state}
#       {:error, _}   -> {:next_state, :failed, new_state}
#       _             -> {:next_state, :unknown,new_state}
#     end
#   end
# end
