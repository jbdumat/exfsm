# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix deps.get      # Install dependencies
mix compile       # Compile the project
mix test          # Run all tests
mix test test/simple_fsm_test.exs   # Run a single test file
mix format        # Format code (uses .formatter.exs)
```

## Architecture

ExFSM is a composable, function-based finite state machine library for Elixir. It is **not** related to Erlang's `:gen_fsm` -- it has no process management and focuses on pure rule-based transitions.

### Core layers

**`lib/exfsm.ex`** -- Macro DSL. Defines `deftrans_rules`, `defrule`, `defrules_commit`, and `defrules_exit`. At compile time, these macros generate:
- `__rule__<name>/2` functions for each rule
- `__rules_exit__<state>_<event>/3` exit handler functions
- A rule graph stored as `%{{state, event} => %{entry: atom, graph: %{rule => %{next: [rules]}}, weights: %{rule => weight}}}`
- Also supports classic `deftrans` (v1-style single-function transitions) and `defbypass` (state-independent event handlers)

**`lib/rule_engine.ex`** -- Executes the rule graph. Two fsm_modes:
- `:steps_only` -- traverses rules, records steps in an accumulator, does not call exit handler. Returns `{:steps_done, params, state, ext_state, acc}`
- `:full` -- traverses rules then calls exit handler. Returns `{:next_state, ...}` or `{:error, ...}`
- `replay/6` -- re-runs from the first non-ok step, or from a targeted rule (`:from` option). Supports `:params_override` and `:merge_params`
- `remaining_rules/3` and `dry_run/2` -- plan inspection without execution

**`lib/machine.ex`** -- Protocol (`ExFSM.Machine.State`) and dispatch logic. `Machine.event(state, {action, params})` is the unified entry point. Dispatches to rule engine (for `deftrans_rules`) or classic engine (for `deftrans`). The protocol requires implementing `handlers/2`, `state_name/1`, and `set_state_name/3`.

**`lib/meta.ex`** -- Process-scoped context via `Process.get/put`. Stores initial state, initial params, accumulator, and delta during execution. Only safe when each FSM execution runs in a single dedicated process (transactor pattern).

**`lib/accumulator.ex`** -- `ExFSM.Acc` struct: `steps`, `exit`, `params`, `state`. Each step records `rule`, `tag`, `in`/`out` snapshots, `chosen` (next rule or `:exit`), and `time_ms`.

**`lib/momfsm.ex`** -- Multi-FSM orchestration via `MomFSM`. Composes multiple FSM handler modules, handles FSM switching across state transitions. Uses `@before_compile` to inject `evaluate/2`, `set_state_name/3`, `get_switch_statuses/0`, etc.

**`lib/visualisation/`** -- Graph visualization utilities (Graphviz / JSON output).

### Execution flow

1. Declare FSM with `use ExFSM` and `deftrans_rules state({:event, params}, ext_state)` blocks
2. Call `Machine.event(state, {action, params})` at runtime
3. Machine resolves the handler(s) from the state via the `ExFSM.Machine.State` protocol
4. `dispatch_engine/4` checks `supports_rules_key?` to route to rules engine vs classic engine
5. Rule engine traverses the graph via `exec_from/7`, building an `ExFSM.Acc` accumulator
6. After traversal, `defrules_exit` is called with final `(params, state, proposed_exit)`
7. Returns `{:next_state, next, new_state, acc}` or `{:error, reason, acc}`

### Two transition styles

- **v2 (rules-based)**: `deftrans_rules` with `defrule`, `defrules_commit`, `defrules_exit` -- supports step-by-step execution, replay, introspection
- **v1 (classic)**: `deftrans state({:event, params}, ext_state)` -- single function, no accumulator. Both styles can coexist in the same module.

### Defining an FSM

```elixir
defmodule MyFSM do
  use ExFSM

  # Implement the protocol for your state shape
  defimpl ExFSM.Machine.State, for: Map do
    def handlers(_state, _params), do: [MyFSM]
    def state_name(state), do: Map.fetch!(state, :__state__)
    def set_state_name(state, name, _handlers), do: Map.put(state, :__state__, name)
  end

  deftrans_rules init({:go, _}, state) do
    defrule step_a(params, state) do
      next_rule({:step_b, params, state}, :ok)
    end

    defrule step_b(params, state) do
      rules_exit(:done, params, state, :ok)
    end

    defrules_commit(entry: :step_a)

    defrules_exit(new_params, new_state, proposed) do
      case proposed do
        :done -> {:next_state, :finished, new_state}
        _ -> {:error, :failed}
      end
    end
  end
end

# Usage:
state = %{__state__: :init}
ExFSM.Machine.event(state, {:go, %{}})
```

### Key macros inside `deftrans_rules`

| Macro | Purpose |
|---|---|
| `defrule name(params, state)` | Define a rule node |
| `next_rule({:name, params, state}, tag)` | Continue to next rule (tag: `:ok`, `:warning`, `:error`) |
| `rules_exit(payload, params, state, tag)` | Terminate rule traversal |
| `defrules_commit(entry: :rule_name)` | Finalize the graph, set entry point (inferred if omitted) |
| `defrules_exit(params, state, proposed)` | Handler called after traversal; must return `{:next_state, ...}` / `{:error, ...}` |

### Introspection

```elixir
MyFSM.rules_graph()                    # Full graph map with weights
MyFSM.rules_outputs()                  # %{{state, event} => exit_fun_atom}
MyFSM.__rules_entry__({:init, :go})    # Entry rule for a given {state, event}
MyFSM.fsm()                            # Classic transition map
ExFSM.Machine.available_actions({state, params})  # All actions from current state
ExFSM.RuleEngine.dry_run(MyFSM, {:init, :go})     # Structural plan without execution
```

### Important conventions

- Rule bodies must return `next_rule(...)` or `rules_exit(...)` -- any other return raises `ArgumentError`
- `ExFSM.Meta` uses `Process.get/put` -- safe only in single-process-per-execution (transactor) pattern
- Steps in the accumulator are stored newest-first (cons to head)
- Step timing uses microseconds (`time_us` field)
- Cycle detection: `exec_from` raises `ArgumentError` if a rule is visited twice
- Dependencies: `ex_doc` (dev only)

### Rules when working

- Ignore all content in tmp/
- Ignore all content in priv/ and its subdirectories