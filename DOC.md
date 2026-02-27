# ExFSM – Résumé d’ancrage (snapshot stable)

## 1. Objectif général
`ExFSM` est un DSL Elixir de machine à états sans processus, centré sur la notion de **règles (`rules`)** chaînées à l’intérieur de transitions (`deftrans_rules`).

Il permet :
- de **déclarer** des graphes de règles conditionnelles,
- de **simuler** ou **exécuter** les transitions (modes `:steps_only` et `:full`),
- de **rejouer** partiellement des transitions (`replay` ciblé ou auto),
- de conserver des **métadonnées complètes** (`params` initiaux, `state` initial, `delta`, `trace des steps`, `exit tags`, etc.).

---

## 2. Structure générale

### Macros principales
| Macro | Rôle | Signature |
|-------|------|-----------|
| `deftrans_rules` | Définit une transition `{state,event}` gouvernée par un graphe de rules. | `deftrans_rules state({:event, params}, external_state) do ... end` |
| `defrule` | Définit une règle (noeud du graphe). | `defrule name(params, state) do ... end` |
| `defrules_commit` | Fige le graphe, calcule l’entrée, et génère `__rules_entry__/1`. | `defrules_commit entry: :a, weights: %{...}` |
| `defrules_exit` | Décrit la sortie finale (mapping de `acc.exit` vers la transition FSM). | `defrules_exit(new_params, new_state, acc) do ... end` |

### Helpers usuels
- `next_rule({:rule, params, state}, tag \\ :ok)`
- `rules_exit(payload, params_override \\ var!(params), state_override \\ var!(state), tag \\ :ok)`
- Sucres : `next_ok`, `next_warn`, `next_error`, `next_exit`
- Accès contextuel : `meta()`, `merge_delta/1`, `put_delta/1`

---

## 3. Mécanisme de propagation
Chaque `defrule` reçoit **`params`** et **`state`**.  
Elle renvoie soit :
- un `next_rule(...)` pour poursuivre, en propageant des `params/state` modifiés,
- soit un `rules_exit(...)` pour terminer, avec un **tag** `:ok | :warning | :error`.

Le moteur enregistre tout dans un `%ExFSM.Acc{}` :
```elixir
%Acc{
  steps: [%{rule: :a, tag: :ok, in: ..., out: ..., chosen: :b}, ...],
  params: %{...},      # derniers params propagés
  state: %{...},       # dernier state propagé
  exit: {:ok, :done},  # ou {:warning, :warned}, {:error, :failed}
  meta: %{initial_params: ..., initial_state: ..., delta: ...}
}
```

---

## 4. Graphe et introspection

`defrules_commit` calcule automatiquement les arêtes (`:next`) à partir des appels `next_rule/…` dans le corps des règles.  
Le graphe est stocké dans :
```elixir
Example.SimpleFSM.rules_graph()
# => %{
#   {:init, :go} => %{
#     entry: :a,
#     graph: %{a: %{next: [:b]}, b: %{next: [:c]}, c: %{next: [:d]}, d: %{next: []}},
#     weights: %{}}
# }
```

`__rules_entry__({state,event})` retourne `:a`.  
Chaque règle est compilée en fonction `__rule__a/2`, `__rule__b/2`, etc.  
La sortie finale est `__rules_exit__init_go/3`.

---

## 5. Modes d’exécution

### `:steps_only`
- Parcourt le graphe des règles, exécute chaque node, construit l’`acc`.
- Ne passe **pas** par `defrules_exit`.

Renvoie :
```elixir
{:steps_done, params, state, external_state, acc}
```

### `:full`
- Identique mais termine par l’appel du `__rules_exit__*` correspondant.

Renvoie :
```elixir
{:next_state, next_state_name, new_state, acc}
```

---

## 6. Rejeu (`replay`)

Deux modes :

### a. Smart replay (auto)
Relance automatiquement depuis la **première règle non-OK** d’un `acc` existant.
```elixir
RuleEngine.replay(handler, key, base_params, external_state, acc,
  mode: :full,
  merge_params: %{...}
)
```
- Si l’acc contenait un `exit`, il détecte la règle du dernier step (`chosen: :exit`) et rejoue à partir de là.
- Si `:from` est explicitement donné, on reprend à partir de cette règle.

### b. Targeted replay
```elixir
RuleEngine.replay(handler, key, base_params, external_state, acc,
  mode: :full,
  from: :b,
  params_override: %{...},
  merge_params: %{...}
)
```
Le replay exécute uniquement les rules à partir du point choisi.

---

## 7. Meta et Acc

`ExFSM.Meta` stocke le contexte courant :
```elixir
%{ initial_state: ..., initial_params: ..., acc: ..., delta: ... }
```
Accès via `ExFSM.meta/0` dans les règles.

---

## 8. Tests validés (Example.SimpleFSM)

Les tests vérifient :
- construction du graphe (`rules_graph`, `__rules_entry__/1`, `__rules_exit__/3`),
- exécution `:full` / `:steps_only`,
- chemins OK / WARN / ERROR,
- `replay` auto et ciblé,
- cohérence de l’`acc`.

---

## 9. État fonctionnel actuel

✅ Compilation clean  
✅ Graphe correctement généré  
✅ Modes `:steps_only` et `:full` stables  
✅ Replay auto et ciblé fonctionnels  
✅ Meta et Acc cohérents  
🚧 Prochaines itérations prévues : optimisation `exec_from`, support multi-graphes (branching/merge), gestion fine des deltas et rollback.
