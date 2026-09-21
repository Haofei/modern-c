"""The structured cause of an `E_BACKEND_UNSUPPORTED` refusal.

`docs/backend-expected-failures.json` records, per known-failing fixture, the
reason code it must still fail with. A reason code alone is a weak assertion:
`E_BACKEND_UNSUPPORTED` is the backend's one refusal code, so a fixture can
drift from "the builder left this body incomplete" to "the renderer has no case
for this expression" -- a different gap in a different file -- without any gate
noticing.

The diagnostic already carries the granularity a fix needs. `CEmitter`'s
`reportFunctionDecline` renders a `FunctionDecline` as

    E_BACKEND_UNSUPPORTED: C backend does not yet support <category> `<construct>` in `<function>` (declined by <phase>)

which names the refusing phase (`mir-build`, `capability`, `signature`,
`ownership-cleanup`), the category and construct it refused, and the function it
refused them in. This module is the one place that knows that shape, so the
sweep (which compares a measured failure against the manifest) and the manifest
validator (which proves every such entry records one) cannot drift apart.

Consumers put tools/toolchain/ on sys.path[0] by being invoked as
`python3 tools/toolchain/<name>.py` from the repo root:
  - spec-emit-sweep.py                 compares a measured cause to the entry
  - backend-expected-failures-test.py  proves each entry records a well-formed one
  - check-generated-c.sh               greps for the rendered message
"""
import re

#: The reason code whose refusals carry a structured cause.
STRUCTURED_REASON = "E_BACKEND_UNSUPPORTED"

#: The fields a `cause` object records, in the order the diagnostic spells them.
CAUSE_FIELDS = ("category", "construct", "function", "phase")

_CAUSE_RE = re.compile(
    re.escape(STRUCTURED_REASON)
    + r": C backend does not yet support "
    + r"(?P<category>.+?) `(?P<construct>[^`]*)` in `(?P<function>[^`]*)` "
    + r"\(declined by (?P<phase>[^)]*)\)"
)


def render_cause(cause):
    """The diagnostic text a `cause` object stands for."""
    return (
        f"{STRUCTURED_REASON}: C backend does not yet support "
        f"{cause['category']} `{cause['construct']}` in `{cause['function']}` "
        f"(declined by {cause['phase']})"
    )


def parse_cause(message):
    """The structured cause carried by one diagnostic line, or None.

    None means the line is not a function-decline refusal at all -- either a
    different diagnostic, or `reportUnsupported`'s unstructured form. A caller
    comparing against a recorded cause must treat that as a mismatch, not as a
    match by absence: the fixture has stopped failing the way it was recorded.
    """
    match = _CAUSE_RE.search(message)
    if match is None:
        return None
    return {field: match.group(field) for field in CAUSE_FIELDS}


def cause_problem(cause):
    """Why `cause` is not a well-formed cause object, or None if it is."""
    if not isinstance(cause, dict):
        return "cause must be an object"
    missing = [field for field in CAUSE_FIELDS if field not in cause]
    if missing:
        return "cause is missing " + ", ".join(missing)
    extra = [field for field in cause if field not in CAUSE_FIELDS]
    if extra:
        return "cause has unknown field(s) " + ", ".join(sorted(extra))
    for field in CAUSE_FIELDS:
        value = cause[field]
        if not isinstance(value, str) or not value.strip():
            return f"cause.{field} must be a non-empty string"
        if "`" in value:
            return f"cause.{field} must not contain a backtick; it is a field, not rendered text"
    # A cause must round-trip: what it renders must parse back to itself, so a
    # field holding rendered punctuation cannot masquerade as a cause.
    if parse_cause(render_cause(cause)) != dict(cause):
        return "cause does not round-trip through the diagnostic text it stands for"
    return None
