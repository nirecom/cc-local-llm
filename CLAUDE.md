# cc-local-llm Project Rules

## Model Management Rules

`llama-swap/config.yaml` holds values only — rationale goes to `docs/tuning.md`, decisions to `docs/history.md`.

## Docs Update Rules

When `llama-swap/config.yaml` changes, also update in-repo `llama-swap/model-annotations.yaml`.

Adding or renaming a model key requires a matching entry with `role`; changing an entry's flags requires updating its `notes`.

Format follows the Windows host's own llama-swap `model-annotations.yaml`, minus the llama.cpp-only `optimizer:` key.

## Design Docs

Architecture, tuning, ops, and decision history: `docs/` — see `README.md` for the map.
