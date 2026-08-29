"""Minimal strict YAML reader for the llama-swap config/annotation pair.

Vendored because this host has no PyYAML and no yq (probed at authoring time),
and because grep/awk cannot answer the structural questions C5 asks: how many
model keys exist, which group holds which member, whether an annotation entry
really carries `retained:` as its own field rather than as a substring of a
neighbour's notes.

Deliberately strict, and deliberately NOT a general YAML implementation. It
covers exactly the subset both files use -- block mappings, block sequences of
scalars, quoted/plain scalars and folded/literal block scalars -- and raises on
anything else (tabs, duplicate keys, ragged indentation, flow collections)
rather than guessing. A parser that guesses would turn a malformed config into
a green test, which is the failure mode this file exists to prevent.
"""


class YamlError(Exception):
    """Raised for any input this reader refuses to interpret."""


_BLOCK_INDICATORS = ('|', '>', '|-', '>-', '|+', '>+')


def _indent_of(raw):
    n = 0
    for ch in raw:
        if ch == ' ':
            n += 1
        elif ch == '\t':
            raise YamlError('tab in indentation')
        else:
            break
    return n


def _is_skippable(raw):
    s = raw.strip()
    return s == '' or s.startswith('#')


def _strip_comment(s):
    """Drop a trailing `#` comment that starts outside a quoted scalar."""
    out = []
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote is not None:
            out.append(c)
            if c == '\\' and quote == '"' and i + 1 < len(s):
                i += 1
                out.append(s[i])
            elif c == quote:
                quote = None
        elif c in '"\'':
            quote = c
            out.append(c)
        elif c == '#' and (not out or out[-1] in ' \t'):
            break
        else:
            out.append(c)
        i += 1
    return ''.join(out).rstrip()


def _scalar(text):
    s = text.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in '"\'':
        return s[1:-1]
    # `used_by: []` is the one flow form both real files use; any other flow
    # collection is refused rather than silently read as a string.
    if s == '[]':
        return []
    if s == '{}':
        return {}
    if s.startswith('[') or s.startswith('{'):
        raise YamlError('non-empty flow collections are not supported: %s' % s)
    if s in ('true', 'True'):
        return True
    if s in ('false', 'False'):
        return False
    if s in ('null', '~', ''):
        return None
    try:
        return int(s)
    except ValueError:
        return s


class _Reader(object):
    def __init__(self, text):
        self.lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
        self.i = 0

    def _next_significant(self):
        j = self.i
        while j < len(self.lines) and _is_skippable(self.lines[j]):
            j += 1
        return j

    def _block_scalar(self, key_indent):
        """Consume the body of a `>-`/`|` scalar: every deeper-indented line."""
        parts = []
        while self.i < len(self.lines):
            raw = self.lines[self.i]
            if raw.strip() == '':
                parts.append('')
                self.i += 1
                continue
            if _indent_of(raw) <= key_indent:
                break
            parts.append(raw.strip())
            self.i += 1
        return ' '.join(p for p in parts if p != '')

    def parse_node(self, indent):
        j = self._next_significant()
        if j >= len(self.lines):
            return None
        self.i = j
        if _strip_comment(self.lines[j]).strip().startswith('- '):
            return self.parse_sequence(indent)
        return self.parse_mapping(indent)

    def parse_sequence(self, indent):
        items = []
        while True:
            j = self._next_significant()
            if j >= len(self.lines):
                break
            raw = self.lines[j]
            cur = _indent_of(raw)
            if cur < indent:
                break
            if cur > indent:
                raise YamlError('line %d: unexpected indent inside sequence' % (j + 1))
            body = _strip_comment(raw).strip()
            if not body.startswith('- '):
                if body == '-':
                    raise YamlError('line %d: empty sequence entry' % (j + 1))
                break
            self.i = j + 1
            item = body[2:]
            # A nested mapping under a sequence entry would be read as the plain
            # string "key: value"; refuse instead of returning a wrong shape.
            k = self._next_significant()
            if k < len(self.lines) and _indent_of(self.lines[k]) > cur:
                raise YamlError('line %d: nested block under a sequence entry '
                                'is not supported' % (j + 1))
            items.append(_scalar(item))
        return items

    def parse_mapping(self, indent):
        out = {}
        while True:
            j = self._next_significant()
            if j >= len(self.lines):
                break
            raw = self.lines[j]
            cur = _indent_of(raw)
            if cur < indent:
                break
            if cur > indent:
                raise YamlError('line %d: unexpected indent inside mapping' % (j + 1))
            body = _strip_comment(raw).strip()
            if body.startswith('- '):
                break
            if ':' not in body:
                raise YamlError('line %d: not a mapping entry: %r' % (j + 1, body))
            key, _, rest = body.partition(':')
            key = key.strip().strip('"\'')
            rest = rest.strip()
            if key in out:
                raise YamlError('line %d: duplicate key %r' % (j + 1, key))
            self.i = j + 1
            if rest in _BLOCK_INDICATORS:
                out[key] = self._block_scalar(cur)
            elif rest == '':
                k = self._next_significant()
                if k < len(self.lines):
                    child_indent = _indent_of(self.lines[k])
                    child_body = _strip_comment(self.lines[k]).strip()
                    if child_indent > cur:
                        out[key] = self.parse_node(child_indent)
                        continue
                    if child_indent == cur and child_body.startswith('- '):
                        out[key] = self.parse_sequence(cur)
                        continue
                out[key] = None
            else:
                out[key] = _scalar(rest)
        return out


def loads(text):
    r = _Reader(text)
    value = r.parse_node(0)
    j = r._next_significant()
    if j < len(r.lines):
        raise YamlError('line %d: trailing content the reader could not attach' % (j + 1))
    return {} if value is None else value


def load_file(path):
    with open(path, 'r', encoding='utf-8') as fh:
        return loads(fh.read())
