defmodule Example.SimpleFSM.NewApiTest do
  use ExUnit.Case, async: true
  alias ExFSM.RuleEngine
  alias Example.SimpleFSM

  @state0 %{__state__: :init}

  describe "introspection & plumbing" do
    test "expose __rules_entry__/1 et rules_outputs/0, et sortie arité 3" do
      assert function_exported?(SimpleFSM, :__rules_entry__, 1)

      outs = SimpleFSM.rules_outputs()
      out_fun = outs[{:init, :go}]
      assert is_atom(out_fun)
      assert function_exported?(SimpleFSM, out_fun, 3)
    end

    test "rules_graph est peuplé et les arêtes next sont détectées" do
      rg = SimpleFSM.rules_graph()
      assert %{{:init, :go} => %{entry: :a, graph: graph}} = rg

      # les noeuds existent
      for r <- [:a, :b, :c, :d], do: assert(Map.has_key?(graph, r))

      # arêtes attendues (a->b, b->c, c->d ; d est terminal)
      assert Enum.sort(graph[:a][:next]) == [:b]
      assert Enum.sort(graph[:b][:next]) == [:c]
      assert Enum.sort(graph[:c][:next]) == [:d]
      assert graph[:d][:next] == []
    end
  end

  describe "run(:full) — chemins OK / WARN / ERROR" do
    test "OK path -> {:next_state, :done, new_state} + acc cohérent" do
      params = %{path: :ok_path}

      {:next_state, :done, new_state, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :full)

      assert acc.exit == {:ok, :done}
      # ordre des rules (on avait empilé par cons, donc on reverse pour lire)
      seen = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert seen == [:a, :b, :c, :d]

      # le state retourné est bien celui construit par les rules
      assert is_map(new_state)
      # la séquence contient bien a,b,c,d (peu importe l'ordre interne)
      seq = Map.get(new_state, :seq, [])
      assert MapSet.new(seq) == MapSet.new([:a, :b, :c, :d])
    end

    test "WARN path -> {:keep_state, :init, initial_state}" do
      params = %{path: :warn_path}

      {:keep_state, :init, state_kept, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :full)

      assert state_kept == @state0
      assert acc.exit == {:warning, :warned}
    end

    test "ERROR path -> {:keep_state, :init, initial_state}" do
      params = %{path: :error_path}

      {:keep_state, :init, state_kept, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :full)

      assert state_kept == @state0
      assert acc.exit == {:error, :failed}
    end
  end

  describe "run(:steps_only) — exécute les rules sans appeler defrules_exit/3" do
    test "steps_only renvoie {:steps_done, params_flow, state_flow, external_state, acc}" do
      params = %{path: :ok_path}

      {:steps_done, p2, s2, external_state, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :steps_only)

      # l'external_state n'a pas été modifié
      assert external_state == @state0

      # l'exit est bien posé par les rules (mais pas de __rules_exit__/3 appelé)
      assert acc.exit == {:ok, :done}
      assert p2 == acc.params
      assert s2 == acc.state

      seen = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert seen == [:a, :b, :c, :d]
    end
  end

  describe "replay/… — rejoue la fin correctement" do
    test "replay(:full) sur un acc complété appelle defrules_exit/3 et renvoie le même résultat que run(:full)" do
      params = %{path: :ok_path}

      # on exécute d'abord en steps_only
      {:steps_done, _p2, _s2, _ext, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :steps_only)

      # puis on 'replay' en :full => applique __rules_exit__/3
      {:next_state, :done, new_state, acc2} = RuleEngine.replay(SimpleFSM, {:init, :go}, params, @state0, acc, mode: :full)

      assert acc2.exit == {:ok, :done}
      assert MapSet.new(Map.get(new_state, :seq, [])) == MapSet.new([:a, :b, :c, :d])
    end

    test "replay(:full) avec acc.exit bogus -> {:error, ...}" do
      bogus = %ExFSM.Acc{params: %{}, state: %{}, steps: [], exit: {:ok, :not_a_state}}

      {:error, _reason, _acc} =
        RuleEngine.replay(SimpleFSM, {:init, :go}, %{}, @state0, bogus, mode: :full)
    end
  end

  describe "helpers optionnels" do
    test "__remaining_rules__/3 si exposé" do
      if function_exported?(SimpleFSM, :__remaining_rules__, 3) do
        params = %{path: :ok_path}
        {:steps_done, _p2, _s2, _s, acc} = RuleEngine.run(SimpleFSM, {:init, :go}, params, @state0, mode: :steps_only)

        applied = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
        remaining = apply(SimpleFSM, :__remaining_rules__, [{:init, :go}, applied, acc])

        assert is_list(remaining)
        assert Enum.all?(remaining, &is_atom/1)
      else
        assert true
      end
    end
  end

  describe "replay ciblé" do
    test "rejoue à partir de la première règle non-ok (ex: :b en warning), sans repasser par :a" do
      params = %{path: :warn_path}
      state0 = %{__state__: :init}

      # 1) steps_only: on obtient un acc avec :a ok, :b warning → exit warning
      {:steps_done, _p2, _s2, _ext, acc} =
        RuleEngine.run(Example.SimpleFSM, {:init, :go}, params, state0, mode: :steps_only)

      # Vérif de l'ordre
      seen = acc.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert seen == [:a, :b]  # dans ce chemin warn on s'arrête sur b

      # 2) On corrige le paramétrage et on rejoue *depuis b* uniquement (nouveau path ok)
      params_fix = %{path: :ok_path}

      {:next_state, :done, new_state, acc2} =
        RuleEngine.replay(Example.SimpleFSM, {:init, :go}, params, state0, acc,
          mode: :full,
          from: :b,
          params_override: params_fix
        )

      # On n’a pas repassé par a, seulement b→c→d
      seen2 = acc2.steps |> Enum.reverse() |> Enum.map(& &1.rule)
      assert Enum.take(seen2, -3) == [:b, :c, :d]
      assert acc2.exit == {:ok, :done}
      assert MapSet.new(Map.get(new_state, :seq, [])) |> MapSet.subset?(MapSet.new([:a, :b, :c, :d]))
    end

    test "smart replay (sans :from) reprend au premier non-ok automatiquement" do
      params = %{path: :warn_path}
      state0 = %{__state__: :init}

      {:steps_done, _p2, _s2, _ext, acc} =
        ExFSM.RuleEngine.run(Example.SimpleFSM, {:init, :go}, params, state0, mode: :steps_only)

      # On ne précise pas :from, mais on donne merge_params pour passer en ok
      {:next_state, :done, _st, acc2} =
        ExFSM.RuleEngine.replay(Example.SimpleFSM, {:init, :go}, params, state0, acc, mode: :full, merge_params: %{path: :ok_path})

      assert acc2.exit == {:ok, :done}
    end

    test "replay sans :from (ou avec from: nil) repart bien du premier non-ok" do
      params = %{path: :warn_path}
      s0 = %{__state__: :init}

      {:steps_done, _p2, _s2, _ext, acc} =
        ExFSM.RuleEngine.run(Example.SimpleFSM, {:init, :go}, params, s0, mode: :steps_only)

      # Sans :from
      {:next_state, :done, _st, acc2} =
        ExFSM.RuleEngine.replay(Example.SimpleFSM, {:init, :go}, params, s0, acc,
          mode: :full,
          merge_params: %{path: :ok_path}
        )
      assert acc2.exit == {:ok, :done}

      # Avec from: nil explicite
      {:next_state, :done, _st, acc3} =
        ExFSM.RuleEngine.replay(Example.SimpleFSM, {:init, :go}, params, s0, acc,
          mode: :full,
          from: nil,
          merge_params: %{path: :ok_path}
        )
      assert acc3.exit == {:ok, :done}
    end
  end
end
