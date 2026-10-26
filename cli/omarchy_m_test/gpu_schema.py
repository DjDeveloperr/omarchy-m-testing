"""A stdlib-only validator for the versioned GPU document schema.

It refuses schemas that use keywords it doesn't implement, so a schema change
can't silently weaken the Seam A check. CI also validates the golden reports
with a full draft 2020-12 validator (check-jsonschema), and the site uses
json_schemer, so all three must agree.
"""

from __future__ import annotations

import re
from typing import Any

ANNOTATIONS = {"$schema", "$id", "title", "description"}
KEYWORDS = ANNOTATIONS | {
    "type", "properties", "required", "additionalProperties", "const", "enum",
    "pattern", "minLength", "maxLength", "minimum", "maximum", "items", "minItems", "maxItems",
}


def _is_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# Draft 2020-12 semantics: 1.0 is an integer, and numbers compare by value.
_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: _is_number(v) and float(v).is_integer(),
    "number": _is_number,
    "boolean": lambda v: isinstance(v, bool),
}


class UnsupportedSchema(Exception):
    pass


def _same(a: Any, b: Any) -> bool:
    if _is_number(a) and _is_number(b):
        return a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def errors(schema: dict, value: Any, path: str = "$") -> list[str]:
    unknown = set(schema) - KEYWORDS
    if unknown:
        raise UnsupportedSchema(f"{path}: keywords not supported: {sorted(unknown)}")
    if "type" in schema and schema["type"] not in _TYPES:
        raise UnsupportedSchema(f"{path}: type {schema['type']!r} not supported")
    found: list[str] = []

    if "type" in schema and not _TYPES[schema["type"]](value):
        return [f"{path}: expected {schema['type']}"]
    if "const" in schema and not _same(value, schema["const"]):
        found.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and not any(_same(value, option) for option in schema["enum"]):
        found.append(f"{path}: must be one of {schema['enum']!r}")

    if isinstance(value, str):
        if "pattern" in schema and not re.search(schema["pattern"], value):
            found.append(f"{path}: doesn't match {schema['pattern']}")
        if "minLength" in schema and len(value) < schema["minLength"]:
            found.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            found.append(f"{path}: longer than {schema['maxLength']}")
    if _is_number(value):
        if "minimum" in schema and value < schema["minimum"]:
            found.append(f"{path}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            found.append(f"{path}: above {schema['maximum']}")

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                found.append(f"{path}: missing {name}")
        extra = schema.get("additionalProperties", True)
        if extra not in (True, False):
            raise UnsupportedSchema(f"{path}: additionalProperties must be true or false")
        for name, item in value.items():
            if name in properties:
                found += errors(properties[name], item, f"{path}.{name}")
            elif extra is False:
                found.append(f"{path}: unexpected property {name}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            found.append(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            found.append(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for index, item in enumerate(value):
                found += errors(schema["items"], item, f"{path}[{index}]")

    return found
