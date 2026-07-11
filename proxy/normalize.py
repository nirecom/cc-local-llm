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

All functions take a request body dict and return a new dict; the input is
never mutated.
"""

import copy
import re

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


def move_dynamic_sections(body: dict) -> dict:
    """Remove dynamic sections from the system prompt and append them to the
    first user message.

    Supports two system-prompt shapes:
      * a plain string
      * a list of content blocks [{"type": "text", "text": ...}, ...]
    """
    body = copy.deepcopy(body)
    system = body.get('system')
    if system is None:
        return body

    extracted: list[str] = []

    if isinstance(system, str):
        cleaned, found = _extract_from_text(system)
        extracted.extend(found)
        body['system'] = cleaned
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and 'text' in block:
                cleaned, found = _extract_from_text(block['text'])
                extracted.extend(found)
                block['text'] = cleaned
        body['system'] = system
    else:
        return body

    if not extracted:
        return body

    appendix = '\n'.join(extracted)
    messages = body.get('messages')
    if not messages:
        # No user message to attach to; the system prompt is still cleaned.
        return body

    # Find the first user message and append the extracted sections.
    for msg in messages:
        if msg.get('role') != 'user':
            continue
        content = msg.get('content')
        if isinstance(content, str):
            msg['content'] = content.rstrip() + '\n' + appendix
        elif isinstance(content, list):
            content.append({'type': 'text', 'text': appendix})
        else:
            msg['content'] = appendix
        break
    return body


def _normalize_date_in_text(text: str) -> str:
    return _DATE_LINE.sub(r'\1\2', text)


def normalize_date(body: dict) -> dict:
    """Normalize 'Today's date is ...' occurrences to a bare YYYY-MM-DD.

    A malformed date part (no YYYY-MM-DD prefix) does not match and the line
    is left untouched (safe side).
    """
    body = copy.deepcopy(body)
    system = body.get('system')
    if isinstance(system, str):
        body['system'] = _normalize_date_in_text(system)
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and 'text' in block:
                block['text'] = _normalize_date_in_text(block['text'])
    return body


def _strip_reminders_in_text(text: str) -> str:
    text = _SYSTEM_REMINDER.sub('', text)
    return _ORPHAN_CLOSE.sub('', text)


def strip_system_reminders(body: dict) -> dict:
    """Remove every <system-reminder>...</system-reminder> block (DOTALL)."""
    body = copy.deepcopy(body)
    system = body.get('system')
    if isinstance(system, str):
        body['system'] = _strip_reminders_in_text(system)
    elif isinstance(system, list):
        for block in system:
            if isinstance(block, dict) and 'text' in block:
                block['text'] = _strip_reminders_in_text(block['text'])

    messages = body.get('messages')
    if isinstance(messages, list):
        for msg in messages:
            content = msg.get('content')
            if isinstance(content, str):
                msg['content'] = _strip_reminders_in_text(content)
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if 'text' in block:
                        block['text'] = _strip_reminders_in_text(block['text'])
                    elif isinstance(block.get('content'), str):
                        # tool_result blocks carry their payload in "content",
                        # not "text" — strip reminders there too.
                        block['content'] = _strip_reminders_in_text(block['content'])
                    elif isinstance(block.get('content'), list):
                        # tool_result with list-shaped content (nested blocks).
                        for sub in block['content']:
                            if isinstance(sub, dict) and 'text' in sub:
                                sub['text'] = _strip_reminders_in_text(sub['text'])
    return body


def sort_tools(body: dict) -> dict:
    """Sort the tools list by name for deterministic prompt-cache keys.

    No-op when there is no 'tools' key. Idempotent.
    """
    body = copy.deepcopy(body)
    tools = body.get('tools')
    if isinstance(tools, list):
        body['tools'] = sorted(tools, key=lambda t: t.get('name', ''))
    return body


def apply_all(body: dict) -> dict:
    """Apply all normalization rules in order A->B->C->D."""
    body = move_dynamic_sections(body)
    body = normalize_date(body)
    body = strip_system_reminders(body)
    body = sort_tools(body)
    return body
