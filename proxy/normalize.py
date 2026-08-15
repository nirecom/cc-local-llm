"""Request-body normalization rules for the ds4 reverse proxy.

Four pure normalization rules plus apply_all() that composes them in
deterministic A->B->C->D order:

  A. move_dynamic_sections   - lift volatile system-prompt lines into the
                               first user message so the cached system prompt
                               stays stable across requests.
  B. normalize_date          - collapse a timestamped "Today's date" line to
                               a bare YYYY-MM-DD.
  C. strip_system_reminders  - drop <system-reminder>...</system-reminder>.
  D. sort_tools              - sort the tools array by name for determinism.

Every rule takes a mandatory keyword-only `shape` ("anthropic" | "openai")
selecting which body layout to traverse: LiteLLM converts the opus route to
the OpenAI shape upstream of this proxy, so both arrive here. There is no
default on purpose — a default would let a forgotten argument normalize the
wrong field set with no runtime symptom.

The rules themselves (patterns and text helpers) are shape-independent; only
*where* they scan differs.

All functions take a request body dict and return a new dict; the input is
never mutated.
"""

import copy
import re
from collections.abc import Callable, Iterator

OPENAI = "openai"

# Patterns that identify dynamic/volatile sections in the system prompt.
# Each match is removed from the system prompt and appended to the first
# user message. Order here is not significant; every match is moved.
DYNAMIC_PATTERNS = [
    re.compile(r'^Working directory:.*$', re.MULTILINE),
    re.compile(r'^Is directory a git repo:.*$', re.MULTILINE),
    re.compile(r'^Platform:.*$', re.MULTILINE),
    re.compile(r'^OS Version:.*$', re.MULTILINE),
    re.compile(r'^Shell:.*$', re.MULTILINE),
    # gitStatus is a multi-line block: from the "gitStatus:" line up to (but
    # not including) the first blank line, or the end of the string. DOTALL
    # lets ".*?" span the trailing status lines, and the lazy quantifier plus
    # the (blank-line | end) boundary stops the block from greedily eating
    # stable text that follows a blank line after the status listing.
    re.compile(r'^gitStatus:.*?(?=\n[ \t]*\n|\Z)', re.MULTILINE | re.DOTALL),
    # Claude Code auto-memory injection: the line that names the project-specific
    # memory directory. The path is machine-specific and breaks the KV cache
    # prefix across different client machines or project renames.
    re.compile(r'^You have a persistent, file-based memory system at .*$', re.MULTILINE),
]

_DATE_LINE = re.compile(
    r"(Today's date is )(\d{4}-\d{2}-\d{2})(?:[T ][0-9:.\-+Z]*)?",
)

_SYSTEM_REMINDER = re.compile(
    r'<system-reminder>.*?</system-reminder>',
    re.DOTALL,
)
# Orphan close tags left behind when the open tag was already consumed as part
# of a nested reminder (e.g. <system-reminder>a<system-reminder>b</system-reminder>
# strips the inner pair, leaving </system-reminder> without a partner).
_ORPHAN_CLOSE = re.compile(r'</system-reminder>')

_TextFn = Callable[[str], str]


# --- shape adapters ---------------------------------------------------------
# Each adapter locates the text a rule may rewrite; the rules themselves never
# touch the body layout directly.

def _map_text_in_place(container: dict, fn: _TextFn, key: str = 'content') -> None:
    """Rewrite container[key], whether it is a string or a list of text parts."""
    value = container.get(key)
    if isinstance(value, str):
        container[key] = fn(value)
    elif isinstance(value, list):
        for part in value:
            if isinstance(part, dict) and isinstance(part.get('text'), str):
                part['text'] = fn(part['text'])


def _iter_messages(body: dict) -> Iterator[dict]:
    """Yield the dict-shaped entries of body["messages"], if any."""
    messages = body.get('messages')
    if not isinstance(messages, list):
        return
    for msg in messages:
        if isinstance(msg, dict):
            yield msg


def _map_system_text(body: dict, shape: str, fn: _TextFn) -> None:
    """Rewrite every system-prompt text of the given shape, in place.

    Anthropic keeps the system prompt in body["system"] (a string or a list of
    content blocks); OpenAI carries it as one or more role="system" messages.
    """
    if shape == OPENAI:
        for msg in _iter_messages(body):
            if msg.get('role') == 'system':
                _map_text_in_place(msg, fn)
        return

    system = body.get('system')
    if isinstance(system, str):
        body['system'] = fn(system)
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and isinstance(block.get('text'), str):
                block['text'] = fn(block['text'])


def _first_user_message(body: dict, shape: str) -> dict | None:
    """The message the extracted dynamic sections get appended to."""
    if shape == OPENAI:
        for msg in _iter_messages(body):
            if msg.get('role') == 'user':
                return msg
        return None

    messages = body.get('messages')
    if not messages:
        return None
    # Anthropic shape keeps its long-standing strictness: a non-dict entry
    # surfaces as an AttributeError instead of being silently skipped.
    for msg in messages:
        if msg.get('role') == 'user':
            return msg
    return None


def _tool_sort_key(tool, shape: str):
    """Sort key for one tools[] entry.

    OpenAI nests the name under "function" and tolerates malformed entries
    (LiteLLM-generated bodies vary more); Anthropic keeps the original strict
    lookup, where a non-dict entry or a null name raises.
    """
    if shape != OPENAI:
        return tool.get('name', '')
    if not isinstance(tool, dict):
        return ''
    function = tool.get('function')
    name = function.get('name') if isinstance(function, dict) else None
    return name if isinstance(name, str) else ''


# --- rules ------------------------------------------------------------------

def _extract_from_text(text: str) -> tuple[str, list[str]]:
    """Return (cleaned_text, [extracted_section, ...]) for one text blob."""
    extracted: list[str] = []
    cleaned = text
    for pat in DYNAMIC_PATTERNS:
        matches = pat.findall(cleaned)
        if not matches:
            continue
        for m in matches:
            extracted.append(m.strip())
        cleaned = pat.sub('', cleaned)
    # Collapse the blank lines left behind by removed sections.
    cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)
    return cleaned, extracted


def move_dynamic_sections(body: dict, *, shape: str) -> dict:
    """Remove dynamic sections from the system prompt and append them to the
    first user message.

    Supports two system-prompt shapes per protocol:
      * a plain string
      * a list of content blocks [{"type": "text", "text": ...}, ...]
    """
    body = copy.deepcopy(body)
    extracted: list[str] = []

    def _clean(text: str) -> str:
        cleaned, found = _extract_from_text(text)
        extracted.extend(found)
        return cleaned

    _map_system_text(body, shape, _clean)

    if not extracted:
        return body

    appendix = '\n'.join(extracted)
    target = _first_user_message(body, shape)
    if target is None:
        # No user message to attach to; the system prompt is still cleaned.
        return body

    content = target.get('content')
    if isinstance(content, str):
        target['content'] = content.rstrip() + '\n' + appendix
    elif isinstance(content, list):
        content.append({'type': 'text', 'text': appendix})
    else:
        target['content'] = appendix
    return body


def _normalize_date_in_text(text: str) -> str:
    return _DATE_LINE.sub(r'\1\2', text)


def normalize_date(body: dict, *, shape: str) -> dict:
    """Normalize 'Today's date is ...' occurrences to a bare YYYY-MM-DD.

    A malformed date part (no YYYY-MM-DD prefix) does not match and the line
    is left untouched (safe side).
    """
    body = copy.deepcopy(body)
    _map_system_text(body, shape, _normalize_date_in_text)
    return body


def _strip_reminders_in_text(text: str) -> str:
    text = _SYSTEM_REMINDER.sub('', text)
    return _ORPHAN_CLOSE.sub('', text)


def strip_system_reminders(body: dict, *, shape: str) -> dict:
    """Remove every <system-reminder>...</system-reminder> block (DOTALL)."""
    body = copy.deepcopy(body)
    _map_system_text(body, shape, _strip_reminders_in_text)

    for msg in _iter_messages(body):
        if shape == OPENAI:
            # The system prompt is a message here and was handled above; every
            # other role carries its payload in the same "content" field.
            if msg.get('role') != 'system':
                _map_text_in_place(msg, _strip_reminders_in_text)
            continue

        content = msg.get('content')
        if isinstance(content, str):
            msg['content'] = _strip_reminders_in_text(content)
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if 'text' in block:
                    if isinstance(block['text'], str):
                        block['text'] = _strip_reminders_in_text(block['text'])
                elif isinstance(block.get('content'), str):
                    # tool_result blocks carry their payload in "content",
                    # not "text" — strip reminders there too.
                    block['content'] = _strip_reminders_in_text(block['content'])
                elif isinstance(block.get('content'), list):
                    # tool_result with list-shaped content (nested blocks).
                    for sub in block['content']:
                        if isinstance(sub, dict) and isinstance(sub.get('text'), str):
                            sub['text'] = _strip_reminders_in_text(sub['text'])
    return body


def sort_tools(body: dict, *, shape: str) -> dict:
    """Sort the tools list by name for deterministic prompt-cache keys.

    No-op when there is no 'tools' key. Idempotent.
    """
    body = copy.deepcopy(body)
    tools = body.get('tools')
    if isinstance(tools, list):
        body['tools'] = sorted(tools, key=lambda t: _tool_sort_key(t, shape))
    return body


def apply_all(body: dict, *, shape: str) -> dict:
    """Apply all normalization rules in order A->B->C->D."""
    body = move_dynamic_sections(body, shape=shape)
    body = normalize_date(body, shape=shape)
    body = strip_system_reminders(body, shape=shape)
    body = sort_tools(body, shape=shape)
    return body
