# cc-local-llm Project Rules

## Model Management Rules

A `config.yaml` under `llama-swap/` holds values only — rationale goes to `docs/tuning.md`, decisions to `docs/history.md`.

## Docs Update Rules

When a `config.yaml` under `llama-swap/` changes, also update the `model-annotations.yaml` beside it.

Adding or renaming a model key requires a matching entry with `role`; changing an entry's flags requires updating its `notes`.

The reverse direction: when a model key leaves `config.yaml`, its annotation may stay only
while the judgement behind it is still live. Keep it by writing that judgement in `retained:`
— it has to say what decision the entry will be consulted for. An annotation nobody can write
a `retained:` line for is deleted with the key. This holds for every host directory, not just
the one that first needed it.

Host directories are named `<chip>-<memory>` — see [llama-swap/README.md](llama-swap/README.md).

## Design Docs

Architecture, tuning, ops, and decision history: `docs/` — see `README.md` for the map.
