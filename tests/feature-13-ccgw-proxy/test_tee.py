# Tests: proxy/tee.py
# Tags: scope:issue-specific, layer:TL1, tee, logging
#
# Scenario (issue #41 / detail plan, Phase 3): the proxy now normalizes two
# body shapes, so a tee dump alone no longer says which rule set produced it.
# TeeLogger.log() gains an optional `shape` parameter that is folded into the
# FILENAME STEM (<ts>-<seq>-<shape>-pre.json) — never into the JSON payload,
# because the shape is a property of the route, not data the client sent.
#
# `shape=None` keeps the current naming, so existing callers and existing dumps
# stay readable.
#
# Security case: the tee writes bodies only. Auth material lives in headers and
# must never appear in a dump, whatever the shape.
#
# TL3 gap: real concurrent connections writing into the same log dir from the
# live proxy (this suite drives TeeLogger directly, single-process).
# Closest-to-action mitigation: covered by the manual cutover smoke run in
# docs/ops.md (serverctl logs proxy with CCGW_PROXY_TEE=on).

import json

import pytest

from proxy.tee import TeeLogger

_TS = "20260815T120000000000Z"
_PRE = {"messages": [{"role": "user", "content": "before"}]}
_POST = {"messages": [{"role": "user", "content": "after"}]}


def _names(tmp_path):
    return sorted(p.name for p in tmp_path.glob("*.json"))


def test_shape_is_absent_from_stem_when_not_supplied(tmp_path):
    """Backward compatibility: the current naming must survive verbatim."""
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST)

    assert _names(tmp_path) == [f"{_TS}-00000-post.json", f"{_TS}-00000-pre.json"]


@pytest.mark.parametrize("shape", ["anthropic", "openai"])
def test_shape_is_folded_into_the_stem(tmp_path, shape):
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape=shape)

    assert _names(tmp_path) == [
        f"{_TS}-00000-{shape}-post.json",
        f"{_TS}-00000-{shape}-pre.json",
    ]


def test_explicit_none_shape_matches_the_omitted_form(tmp_path):
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape=None)

    assert _names(tmp_path) == [f"{_TS}-00000-post.json", f"{_TS}-00000-pre.json"]


def test_the_two_shapes_never_collide_on_one_stem(tmp_path):
    """Distinct shapes at the same timestamp must not overwrite each other."""
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape="anthropic")
    tee.log(_TS, _PRE, _POST, shape="openai")

    names = _names(tmp_path)
    assert len(names) == 4
    assert len(set(names)) == 4


def test_sequence_counter_still_advances_across_shapes(tmp_path):
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape="anthropic")
    tee.log(_TS, _PRE, _POST, shape="openai")

    assert f"{_TS}-00000-anthropic-pre.json" in _names(tmp_path)
    assert f"{_TS}-00001-openai-pre.json" in _names(tmp_path)


def test_shape_is_not_written_into_the_body_json(tmp_path):
    """The dump must remain a faithful copy of the request body.

    Injecting a "shape" key would make a tee dump non-replayable against the
    upstream, which is the whole point of keeping the pair on disk.
    """
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape="openai")

    pre = json.loads(
        (tmp_path / f"{_TS}-00000-openai-pre.json").read_text(encoding="utf-8")
    )
    post = json.loads(
        (tmp_path / f"{_TS}-00000-openai-post.json").read_text(encoding="utf-8")
    )
    assert pre == _PRE
    assert post == _POST


@pytest.mark.parametrize("shape", [None, "anthropic", "openai"])
def test_disabled_logger_writes_nothing_for_any_shape(tmp_path, shape):
    tee = TeeLogger(enabled=False, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape=shape)

    assert _names(tmp_path) == []


def test_no_auth_material_reaches_disk(tmp_path):
    """Security: bodies only — a header-borne token must never be teed."""
    tee = TeeLogger(enabled=True, log_dir=tmp_path)

    tee.log(_TS, _PRE, _POST, shape="openai")

    for path in tmp_path.glob("*.json"):
        content = path.read_text(encoding="utf-8")
        assert "Authorization" not in content
        assert "x-api-key" not in content


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
