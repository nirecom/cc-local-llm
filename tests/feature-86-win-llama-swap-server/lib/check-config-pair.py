#!/usr/bin/env python3
"""Structural checker for one llama-swap host directory's config/annotation pair.

Answers C5's questions off a real parse, not off substrings: exact model /
group / annotation / retained-orphan counts, key-by-key correspondence in both
directions, group membership resolution, and the presence of the fields
llama-swap and CLAUDE.md each require.

Exits 0 when every requested assertion holds, 1 otherwise (diagnostics on
stderr), 2 when the input cannot be parsed at all. The caller supplies the
expected numbers, so the same checker runs against the real Windows pair and
against the synthetic mutation fixtures that prove it can fail.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from yamlmin import YamlError, load_file  # noqa: E402

# Fields every annotation entry must carry, and the field an orphan must add.
REQUIRED_ENTRY_FIELDS = ('role',)
ORPHAN_FIELD = 'retained'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', required=True)
    ap.add_argument('--annotations', required=True)
    ap.add_argument('--expect-models', type=int)
    ap.add_argument('--expect-groups', type=int)
    ap.add_argument('--expect-annotations', type=int)
    ap.add_argument('--expect-retained', type=int)
    ap.add_argument('--absent', action='append', default=[],
                    help='key that must NOT appear in either file')
    ap.add_argument('--require-text', action='append', default=[],
                    help='text that must appear somewhere in the annotations')
    args = ap.parse_args()

    try:
        cfg = load_file(args.config)
        ann = load_file(args.annotations)
    except (YamlError, OSError) as exc:
        sys.stderr.write('PARSE ERROR: %s\n' % exc)
        return 2

    bad = []

    def need(cond, msg):
        if not cond:
            bad.append(msg)

    # --- config shape -----------------------------------------------------
    need(isinstance(cfg, dict), 'config did not parse into a mapping')
    if not isinstance(cfg, dict):
        sys.stderr.write('FAIL: %s\n' % bad[0])
        return 1
    models = cfg.get('models')
    need(isinstance(models, dict) and models,
         'config has no non-empty `models:` mapping')
    models = models if isinstance(models, dict) else {}
    groups = cfg.get('groups') or {}
    need(isinstance(groups, dict), '`groups:` is present but not a mapping')
    groups = groups if isinstance(groups, dict) else {}

    if args.expect_models is not None:
        need(len(models) == args.expect_models,
             'expected %d models, parsed %d: %s'
             % (args.expect_models, len(models), sorted(models)))
    if args.expect_groups is not None:
        need(len(groups) == args.expect_groups,
             'expected %d groups, parsed %d: %s'
             % (args.expect_groups, len(groups), sorted(groups)))

    # Load smoke: llama-swap needs a cmd and a proxy per model, and every group
    # member has to name a model that exists. A config that fails either would
    # start and then fail at first request, which no grep-level check can see.
    for name, entry in sorted(models.items()):
        need(isinstance(entry, dict), 'model %r is not a mapping' % name)
        if not isinstance(entry, dict):
            continue
        need(entry.get('cmd'), 'model %r has no `cmd:`' % name)
        need(entry.get('proxy'), 'model %r has no `proxy:`' % name)

    seen_members = set()
    for gname, g in sorted(groups.items()):
        need(isinstance(g, dict), 'group %r is not a mapping' % gname)
        if not isinstance(g, dict):
            continue
        members = g.get('members')
        need(isinstance(members, list) and members,
             'group %r has no non-empty `members:` list' % gname)
        for m in (members or []):
            need(m in models,
                 'group %r lists member %r, which is not a model key'
                 % (gname, m))
            need(m not in seen_members,
                 'model %r appears in more than one group' % m)
            seen_members.add(m)

    # --- annotations shape ------------------------------------------------
    need(isinstance(ann, dict) and ann,
         'annotations did not parse into a non-empty mapping')
    ann = ann if isinstance(ann, dict) else {}
    if args.expect_annotations is not None:
        need(len(ann) == args.expect_annotations,
             'expected %d annotations, parsed %d: %s'
             % (args.expect_annotations, len(ann), sorted(ann)))

    for name, entry in sorted(ann.items()):
        need(isinstance(entry, dict), 'annotation %r is not a mapping' % name)
        if not isinstance(entry, dict):
            continue
        for f in REQUIRED_ENTRY_FIELDS:
            need(entry.get(f) not in (None, ''),
                 'annotation %r is missing a non-empty `%s:`' % (name, f))

    # --- key-by-key correspondence (both directions) ----------------------
    for name in sorted(models):
        need(name in ann, 'model %r has no annotation entry' % name)
    orphans = sorted(k for k in ann if k not in models)
    for name in orphans:
        entry = ann.get(name) or {}
        need(isinstance(entry, dict) and entry.get(ORPHAN_FIELD) not in (None, ''),
             'orphan annotation %r carries no non-empty `%s:` reason'
             % (name, ORPHAN_FIELD))
    if args.expect_retained is not None:
        need(len(orphans) == args.expect_retained,
             'expected %d retained orphans, found %d: %s'
             % (args.expect_retained, len(orphans), orphans))

    for name in args.absent:
        need(name not in models, 'model key %r should have been removed' % name)
        need(name not in ann, 'annotation key %r should have been removed' % name)

    if args.require_text:
        with open(args.annotations, 'r', encoding='utf-8') as fh:
            blob = fh.read()
        for t in args.require_text:
            need(t in blob, 'required text %r is absent from the annotations' % t)

    if bad:
        for m in bad:
            sys.stderr.write('FAIL: %s\n' % m)
        return 1
    print('ok: %d models, %d groups, %d annotations, %d retained orphan(s)'
          % (len(models), len(groups), len(ann), len(orphans)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
