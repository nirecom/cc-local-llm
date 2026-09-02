# Tests: litellm-server/config.yaml
# Tags: scope:issue-specific, layer:TL1, config, routing, ccgw-tiers, fixture
#
# Not a suite: the S2 annotation grammar as executable code, split out of
# test_route_tier_annotations.py when that file passed the 500-line hard limit
# of rules/coding/file-split.md. It states the grammar exactly once (CPR-SSOT)
# so the case file holds only cases. Placement is half of that grammar, because
# the routes are separated by two-space `# --- ... ---` section comments: an
# annotation written one line too early lands inside the PREVIOUS route's block
# and silently re-tiers the wrong backend. Rationale: docs/tuning.md.

import re
import subprocess
from pathlib import Path

CONFIG_PATH = "litellm-server/config.yaml"

# A route block starts at a two-space `- model_name:` item and runs until the
# next item, the next non-indented line, or EOF.
BLOCK_START_RE = re.compile(r"^  - model_name:[ ]+(\S+)[ ]*$")

# Format P (preferred): a real YAML key on the route, one-line flow sequence.
FORMAT_P_RE = re.compile(r"^      ccgw_tiers:[ ]*\[([^\]]*)\][ ]*$")

# Format F (fallback): a comment, accepted ONLY on the line immediately after
# the block start, for a config hand-edited without a YAML tool.
FORMAT_F_RE = re.compile(r"^    # ccgw-tiers:[ ]+(.+)$")

# Anything that merely looks like an annotation. Deliberately loose: a line the
# writer meant as one but spelled wrong must be a hard error, never a comment.
# Loose means all four axes a hand-typed near miss varies on -- case
# (`CCGW_TIERS`), number (`ccgw_tier`), separator (`ccgwtiers`) and the
# separator's flavour -- because each of them, matched too narrowly, turns the
# writer's intended annotation into an ordinary comment and leaves the route
# silently untiered. No word boundary: `ccgw` is specific enough that the only
# strings carrying it are annotations and prose about them.
LOOKALIKE_RE = re.compile(r"ccgw[-_]?tiers?", re.IGNORECASE)

# The closed vocabulary: Claude Code has exactly these routing slots, so a
# sixth word is a typo rather than an extension.
TIER_VOCAB = ("haiku", "sonnet", "fable", "opus", "subagent")

MODEL_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

# Every line that OFFERS a route name, well-formed or not. BLOCK_START_RE only
# recognises the well-formed ones, so a name the contract rejects would
# otherwise not be a route at all -- and its annotation would be attributed to
# the route above it, re-tiering a backend nobody edited.
MODEL_NAME_LINE_RE = re.compile(r"^  - model_name:(.*)$")
ENV_REF_PREFIX = "os.environ/"
MIN_ANNOTATION_INDENT = 4


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
        cwd=Path(__file__).resolve().parent,
    )
    return Path(result.stdout.strip())


def config_text() -> str:
    """Collection-safe: a missing config yields '', never an import-time error."""
    path = repo_root() / CONFIG_PATH
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


class Route:
    """One `- model_name:` block and the annotations found inside it."""

    def __init__(self, model_name: str, start: int) -> None:
        self.model_name = model_name
        self.start = start  # 0-based index of the block-start line
        self.end = start + 1  # exclusive
        self.annotations: list[tuple[int, str, str]] = []  # (lineno, fmt, payload)

    @property
    def tiers(self) -> list[str]:
        out: list[str] = []
        for _lineno, fmt, payload in self.annotations:
            out.extend(split_payload(payload, fmt))
        return out


def split_payload(payload: str, fmt: str) -> list[str]:
    """P separates with commas, F with whitespace (detail.md S1/S4).

    The separator is part of each form, not a detail: `[opus subagent]` is one
    unknown token and `# ccgw-tiers: opus, subagent` yields `opus,`. Splitting
    both on commas would silently accept each form written in the other's
    spelling -- and the shell and PowerShell readers, which do not, would then
    derive a different tier map from the same file.
    """
    parts = payload.split(",") if fmt == "P" else payload.split()
    return [item.strip() for item in parts if item.strip()]


def parse_routes(text: str) -> list[Route]:
    lines = text.splitlines()
    routes: list[Route] = []
    for i, line in enumerate(lines):
        match = BLOCK_START_RE.match(line)
        if match:
            routes.append(Route(match.group(1), i))
    for idx, route in enumerate(routes):
        limit = routes[idx + 1].start if idx + 1 < len(routes) else len(lines)
        end = limit
        for i in range(route.start + 1, limit):
            if lines[i] and not lines[i][0].isspace():
                end = i
                break
        route.end = end
        for i in range(route.start + 1, route.end):
            p_match = FORMAT_P_RE.match(lines[i])
            if p_match:
                route.annotations.append((i, "P", p_match.group(1)))
                continue
            f_match = FORMAT_F_RE.match(lines[i])
            if f_match and i == route.start + 1:
                route.annotations.append((i, "F", f_match.group(1)))
    return routes


def annotation_violations(text: str) -> list[str]:
    """Every line that looks like an annotation but is not a valid one.

    One classifier for grammar AND placement: both failure modes reach the
    reader as the same symptom -- the tier is not where it was meant to be --
    and splitting them would let a line slip through by being wrong on both.
    """
    lines = text.splitlines()
    routes = parse_routes(text)
    accepted: dict[int, tuple[str, str]] = {}
    for route in routes:
        for lineno, fmt, payload in route.annotations:
            accepted[lineno] = (fmt, payload)

    violations: list[str] = []
    for i, line in enumerate(lines):
        if not LOOKALIKE_RE.search(line):
            continue
        if i in accepted:
            fmt, payload = accepted[i]
            bad = [w for w in split_payload(payload, fmt) if w not in TIER_VOCAB]
            if bad:
                violations.append(
                    f"line {i + 1}: {sorted(set(bad))} is not in the closed tier "
                    f"vocabulary {list(TIER_VOCAB)} -- {line.strip()!r}"
                )
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent < MIN_ANNOTATION_INDENT:
            violations.append(
                f"line {i + 1}: an annotation at indent {indent} sits outside "
                f"every route record and configures nothing -- {line.strip()!r}"
            )
            continue
        owner = next((r for r in routes if r.start < i < r.end), None)
        if owner is None:
            violations.append(
                f"line {i + 1}: out-of-block annotation -- it belongs to no "
                f"`- model_name:` record -- {line.strip()!r}"
            )
        else:
            violations.append(
                f"line {i + 1}: malformed annotation inside the route "
                f"{owner.model_name!r} (block starts at line {owner.start + 1}); "
                "accepted forms are `      ccgw_tiers: [a, b]` and, on the line "
                "immediately after the block start, `    # ccgw-tiers: a b` -- "
                f"{line.strip()!r}"
            )
    return violations


def formats_used(text: str) -> set[str]:
    return {fmt for r in parse_routes(text) for _l, fmt, _p in r.annotations}


def tier_owners(text: str) -> dict[str, list[str]]:
    owners: dict[str, list[str]] = {}
    for route in parse_routes(text):
        for tier in route.tiers:
            owners.setdefault(tier, []).append(route.model_name)
    return owners


def schema_violations(text: str) -> list[str]:
    """Every S2 schema breach in one file -- the writer's pre-commit check.

    `set-model.sh` validates its candidate file against the same contract before
    committing (detail.md S7 b'), so a case asking whether a file is acceptable
    has to ask the whole question, not just the annotation-grammar half of it.
    """
    out = list(annotation_violations(text))
    for i, line in enumerate(text.splitlines()):
        name_match = MODEL_NAME_LINE_RE.match(line)
        if not name_match:
            continue
        name = name_match.group(1).strip()
        if not name:
            out.append(f"line {i + 1}: a route record with no model_name at all")
        elif not MODEL_NAME_RE.fullmatch(name):
            out.append(
                f"line {i + 1}: model_name {name!r} is outside the routing-name "
                "contract ^[A-Za-z0-9._-]+$ -- set-model.sh cannot rewrite it and "
                "the launchers will not export it"
            )
    seen: dict[str, int] = {}
    for route in parse_routes(text):
        if route.model_name in seen:
            out.append(
                f"line {route.start + 1}: duplicate model_name {route.model_name!r}"
            )
        seen[route.model_name] = route.start
        if len(route.annotations) > 1:
            out.append(
                f"line {route.start + 1}: {route.model_name!r} carries "
                f"{len(route.annotations)} annotations"
            )
    for tier, owners in tier_owners(text).items():
        if len(owners) > 1:
            out.append(f"tier {tier!r} is claimed by {owners}")
    used = formats_used(text)
    if len(used) > 1:
        out.append(f"the file mixes annotation formats {sorted(used)}")
    return out
