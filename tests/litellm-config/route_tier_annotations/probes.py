# Shared fixture builder for the ccgw_tiers grammar cases.
#
# Two case files put the same question to the grammar -- test_route_tier_annotations.py
# asks which spellings are accepted, test_route_tier_annotations_2.py asks which
# near misses must be refused -- and both need a probe route sitting in a file
# that is otherwise valid. Kept here rather than in either file so the two
# cannot drift into asking their questions of two different fixtures (CPR-SSOT).


def probe_config(form: str, annotation: str, placement: str) -> str:
    """One route claiming opus beside a neighbour claiming haiku in `form`.

    `head` is the block's second line -- the only place format F is read;
    `body` is inside litellm_params, where format P is written; `above` is the
    line before the item, where a human writes a heading and no annotation may
    live. The neighbour is annotated in the same form as the probe so that a
    rejected probe is never confounded with a P/F mix.
    """
    lines = ["model_list:", "  - model_name: grammar-neighbour"]
    if form == "F":
        lines.append("    # ccgw-tiers: haiku")
    lines += ["    litellm_params:", "      model: openai/Backend-N"]
    if form == "P":
        lines.append("      ccgw_tiers: [haiku]")
    lines += ["", "  # --- the probe route ---"]
    if placement == "above":
        lines.append(annotation)
    lines.append("  - model_name: grammar-probe")
    if placement == "head":
        lines.append(annotation)
    lines += ["    litellm_params:", "      model: openai/Backend-P"]
    if placement == "body":
        lines.append(annotation)
    return "\n".join(lines) + "\n"
