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

ExFSM is a composable, function-based finite state machine library for Elixir. It is **not** related to Erlang's `:gen_fsm` — it has no process management and focuses on pure rule-based transitions.

### Core layers

**`lib/exfsm.ex`** — Macro DSL. Defines `deftrans_rules`, `defrule`, `defrules_commit`, and `defrules_exit`. At compile time, these macros generate:
- `__rule__<name>/2` functions for each rule
- `__rules_exit__<state>_<event>/3` exit handler functions
- A rule graph stored as `%{{state, event} => %{entry: atom, graph: %{rule => %{next: [rules]}}}}`

**`lib/rule_engine.ex`** — Executes the rule graph. Two modes:
- `:steps_only` — traverses rules, records steps in an accumulator, does not call exit handler
- `:full` — traverses rules then calls exit handler
- Smart replay: can re-run from the first non-ok step, or from a targeted rule

**`lib/machine.ex`** — Protocol (`ExFSM.Machine.State`) and dispatch logic. `Machine.event(state, {action, params})` is the unified entry point. Dispatches to rule engine (for `deftrans_rules`) or classic engine (for `deftrans`).

**`lib/meta.ex`** — Process-scoped context via `Process.get/put`. Stores initial state, initial params, accumulator, and delta during execution.

**`lib/accumulator.ex`** — `ExFSM.Acc` struct: `steps`, `exit`, `params`, `state`. Each step records execution time.

**`lib/momfsm.ex`** — Multi-FSM orchestration. Composes multiple FSM handler modules, handles FSM switching across state transitions.

**`lib/visualisation/`** — Graph visualization utilities (Graphviz / JSON output).

### Execution flow

1. Declare FSM with `use ExFSM` and `deftrans_rules state({:event, params}, ext_state)` blocks
2. Call `Machine.event(state, {action, params})` at runtime
3. Machine resolves the handler(s) from the state via the `ExFSM.Machine.State` protocol
4. Rule engine traverses the graph, building an `ExFSM.Acc` accumulator
5. After traversal, `defrules_exit` is called with final `(params, state, proposed_exit)`
6. Returns `{:next_state, next, new_state, acc}` or `{:keep_state, ...}` / `{:error, ...}`

### Defining an FSM

```elixir
defmodule MyFSM do
  use ExFSM

  deftrans_rules init({:go, _}, ext_state) do
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
```

### Key macros inside `deftrans_rules`

| Macro | Purpose |
|---|---|
| `defrule name(params, state)` | Define a rule node |
| `next_rule({:name, params, state}, status)` | Continue to next rule |
| `rules_exit(tag, params, state, status)` | Terminate rule traversal |
| `defrules_commit(entry: :rule_name)` | Finalize the graph, set entry point |
| `defrules_exit(params, state, proposed)` | Handler called after traversal |

### Introspection

```elixir
MyFSM.rules_graph()    # Full graph map
MyFSM.rules_outputs()  # All possible outputs
MyFSM.__rules_entry__({:init, :go})  # Entry rule for a given {state, event}
```
