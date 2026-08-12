#!/usr/bin/env python3
"""Enforce a small, fail-closed GitHub workflow action policy.

This checker intentionally does not import a YAML implementation.  Workflow files are
security inputs, and a permissive parser (or regexes that merely find text resembling
``uses``) makes it too easy for YAML aliases, duplicate keys, block scalars, or alternate
node spellings to create a different document than the policy reviewed.  Instead, the
checker accepts only the canonical YAML subset used by this repository, builds its
structure, and then inspects executable action locations.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_ROOT = REPOSITORY_ROOT / ".github" / "workflows"
MAX_WORKFLOW_BYTES = 1024 * 1024
MAX_WORKFLOW_FILES = 128
MAX_NESTING = 64

EXTERNAL_ACTION_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+"
    r"(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}$"
)
KEY_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
PROPERTY_RE = re.compile(r"(?:^|\s)[&*][A-Za-z0-9_.-]+(?:\s|$)|(?:^|\s)![^\s]+")

FORBIDDEN_SETUP_ACTIONS = {
    "actions/setup-node",
    "actions/setup-python",
    "astral-sh/setup-uv",
}
RUST_TOOLCHAIN_VERSION = "1.97.1"
REVIEWED_UV_ENVIRONMENT = {
    "UV_PYTHON_PREFERENCE": "only-managed",
    "UV_PYTHON_CPYTHON_BUILD": "20260718",
}


class PolicyError(Exception):
    """A source file is outside the accepted canonical workflow subset."""

    def __init__(self, message: str, line: int | None = None):
        super().__init__(message)
        self.message = message
        self.line = line


class _Line:
    __slots__ = ("indent", "number", "text")

    def __init__(self, indent: int, number: int, text: str):
        self.indent = indent
        self.number = number
        self.text = text


class _Node:
    __slots__ = ("kind", "line", "style", "value")

    def __init__(
        self,
        kind: str,
        value: object,
        line: int,
        style: str | None = None,
    ):
        self.kind = kind
        self.value = value
        self.line = line
        self.style = style


def _strip_comment(text: str, line: int) -> str:
    """Strip a YAML comment while validating scalar quote balance."""

    quote: str | None = None
    index = 0
    while index < len(text):
        character = text[index]
        if quote == "'":
            if character == "'":
                if index + 1 < len(text) and text[index + 1] == "'":
                    index += 2
                    continue
                quote = None
        elif quote == '"':
            if character == "\\":
                index += 2
                continue
            if character == '"':
                quote = None
        elif character in "'\"" and (
            index == 0 or text[index - 1].isspace() or text[index - 1] in "[:,"
        ):
            quote = character
        elif character == "#" and (index == 0 or text[index - 1].isspace()):
            return text[:index].rstrip()
        index += 1
    if quote is not None:
        raise PolicyError("unterminated quoted scalar", line)
    return text.rstrip()


def _mapping_parts(text: str, line: int) -> tuple[str, str]:
    if text.startswith(("?", "'", '"')) or text.startswith("<<"):
        raise PolicyError(
            "quoted, explicit, and merge mapping keys are forbidden", line
        )
    match = re.fullmatch(r"([^:]+):(?:\s+(.*))?", text)
    if match is None:
        raise PolicyError("expected a canonical block mapping entry", line)
    key = match.group(1)
    if KEY_RE.fullmatch(key) is None:
        raise PolicyError(f"non-canonical mapping key: {key}", line)
    return key, match.group(2) or ""


def _decode_quoted_scalar(value: str, line: int) -> str:
    if value.startswith("'"):
        if len(value) < 2 or not value.endswith("'"):
            raise PolicyError("unterminated single-quoted scalar", line)
        inner = value[1:-1]
        index = 0
        while index < len(inner):
            if inner[index] == "'":
                if index + 1 >= len(inner) or inner[index + 1] != "'":
                    raise PolicyError("invalid single-quoted scalar", line)
                index += 2
            else:
                index += 1
        decoded = inner.replace("''", "'")
        if any(
            unicodedata.category(character) in {"Cc", "Cf", "Cs"}
            for character in decoded
        ):
            raise PolicyError("decoded scalar contains a control character", line)
        return decoded
    try:
        decoded = json.loads(value)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PolicyError(
            "double-quoted scalars must use JSON-compatible escapes", line
        ) from error
    if not isinstance(decoded, str):
        raise PolicyError("expected a quoted string scalar", line)
    if any(
        unicodedata.category(character) in {"Cc", "Cf", "Cs"} for character in decoded
    ):
        raise PolicyError("decoded scalar contains a control character", line)
    return decoded


def _plain_scalar(value: str, line: int) -> _Node:
    if value.startswith(("- ", "? ", ": ", "#", "]", "}", ",", "%", "@", "`")):
        raise PolicyError("plain scalar starts with a reserved YAML indicator", line)
    if re.search(r":(?:\s|$)", value):
        raise PolicyError("plain scalar contains a colon followed by whitespace", line)
    if value[0] in "&*!":
        raise PolicyError("YAML anchors, aliases, and tags are forbidden", line)
    if PROPERTY_RE.search(value):
        raise PolicyError("YAML anchors, aliases, and tags are forbidden", line)
    if value.startswith(("|", ">")):
        raise PolicyError("folded and unexpected block scalars are forbidden", line)
    if value.startswith("{") or value.endswith("}") and value.startswith("{"):
        raise PolicyError("flow mappings are forbidden", line)
    return _Node("scalar", value, line, "plain")


def _quoted_scalar(value: str, line: int) -> _Node:
    quote = value[0]
    index = 1
    while index < len(value):
        if quote == "'" and value[index] == "'":
            if index + 1 < len(value) and value[index + 1] == "'":
                index += 2
                continue
            break
        if quote == '"' and value[index] == "\\":
            index += 2
            continue
        if value[index] == quote:
            break
        index += 1
    if index >= len(value) or value[index + 1 :].strip():
        raise PolicyError("quoted scalar must occupy the complete value", line)
    return _Node("scalar", _decode_quoted_scalar(value, line), line, "quoted")


def _flow_items(value: str, line: int) -> list[str]:
    if not value.endswith("]"):
        raise PolicyError("unterminated flow sequence", line)
    body = value[1:-1]
    items: list[str] = []
    start = 0
    quote: str | None = None
    index = 0
    while index < len(body):
        character = body[index]
        if quote == "'":
            if character == "'":
                if index + 1 < len(body) and body[index + 1] == "'":
                    index += 2
                    continue
                quote = None
        elif quote == '"':
            if character == "\\":
                index += 2
                continue
            if character == '"':
                quote = None
        elif character in "'\"":
            quote = character
        elif character == ",":
            items.append(body[start:index].strip())
            start = index + 1
        elif character in "[]{}":
            raise PolicyError(
                "nested flow collections and flow mappings are forbidden", line
            )
        index += 1
    if quote is not None:
        raise PolicyError("unterminated quoted flow-sequence item", line)
    tail = body[start:].strip()
    if tail:
        items.append(tail)
    elif body.strip():
        raise PolicyError("trailing flow-sequence commas are forbidden", line)
    if any(not item for item in items):
        raise PolicyError("empty flow-sequence items are forbidden", line)
    return items


def _inline_node(value: str, key: str | None, line: int) -> _Node:
    if value == "|":
        if key not in {"run", "path"}:
            raise PolicyError("block scalars are allowed only for run and path", line)
        return _Node("block", None, line, "literal")
    if value.startswith(("|", ">")):
        raise PolicyError(
            "only exact run: | and path: | literal blocks are allowed", line
        )
    if value.startswith("{"):
        raise PolicyError("flow mappings are forbidden", line)
    if value.startswith("["):
        nodes = [_inline_node(item, None, line) for item in _flow_items(value, line)]
        if any(node.kind != "scalar" for node in nodes):
            raise PolicyError("flow sequences may contain only scalars", line)
        return _Node("list", nodes, line, "flow")
    if value.startswith(("'", '"')):
        return _quoted_scalar(value, line)
    return _plain_scalar(value, line)


def _logical_lines(source: str) -> list[_Line]:
    physical = source.split("\n")[:-1]
    logical: list[_Line] = []
    index = 0
    while index < len(physical):
        raw = physical[index]
        number = index + 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            index += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if indent % 2:
            raise PolicyError("indentation must use two-space increments", number)
        text = _strip_comment(raw[indent:], number)
        if not text:
            index += 1
            continue
        if text.startswith("%") or text in {"---", "..."}:
            raise PolicyError(
                "YAML directives and document markers are forbidden", number
            )
        logical.append(_Line(indent, number, text))

        block_match = re.fullmatch(r"([^:]+):\s*(\|[^\s]*)", text)
        if block_match is not None and block_match.group(2) == "|":
            block_key = block_match.group(1)
            if block_key in {"run", "path"}:
                index += 1
                while index < len(physical):
                    body_line = physical[index]
                    if not body_line.strip():
                        index += 1
                        continue
                    body_indent = len(body_line) - len(body_line.lstrip(" "))
                    if body_indent <= indent:
                        break
                    index += 1
                continue
        index += 1
    return logical


class _Parser:
    def __init__(self, lines: list[_Line]):
        self.lines = lines

    def parse(self) -> _Node:
        if not self.lines:
            raise PolicyError("workflow document is empty")
        if self.lines[0].indent != 0:
            raise PolicyError(
                "root mapping must start at column one", self.lines[0].number
            )
        node, index = self._block(0, 0, 0)
        if index != len(self.lines):
            raise PolicyError("unexpected trailing YAML node", self.lines[index].number)
        if node.kind != "map":
            raise PolicyError("workflow root must be a mapping", node.line)
        return node

    def _block(self, index: int, indent: int, depth: int) -> tuple[_Node, int]:
        if depth > MAX_NESTING:
            raise PolicyError(
                f"workflow nesting exceeds {MAX_NESTING} levels",
                self.lines[index].number,
            )
        if self.lines[index].indent != indent:
            raise PolicyError(
                "nested blocks must increase indentation by two spaces",
                self.lines[index].number,
            )
        if self.lines[index].text == "-" or self.lines[index].text.startswith("- "):
            return self._sequence(index, indent, depth)
        return self._mapping(index, indent, depth)

    def _entry(
        self, text: str, line: int, indent: int, next_index: int, depth: int
    ) -> tuple[str, _Node, int]:
        key, raw_value = _mapping_parts(text, line)
        if raw_value:
            node = _inline_node(raw_value, key, line)
            if next_index < len(self.lines) and self.lines[next_index].indent > indent:
                raise PolicyError(
                    "a scalar mapping value cannot also own a nested block",
                    self.lines[next_index].number,
                )
            return key, node, next_index
        if next_index < len(self.lines) and self.lines[next_index].indent > indent:
            if self.lines[next_index].indent != indent + 2:
                raise PolicyError(
                    "nested blocks must increase indentation by two spaces",
                    self.lines[next_index].number,
                )
            node, next_index = self._block(next_index, indent + 2, depth + 1)
            return key, node, next_index
        return key, _Node("null", None, line), next_index

    def _mapping(self, index: int, indent: int, depth: int) -> tuple[_Node, int]:
        entries: dict[str, _Node] = {}
        start_line = self.lines[index].number
        while index < len(self.lines) and self.lines[index].indent == indent:
            current = self.lines[index]
            if current.text == "-" or current.text.startswith("- "):
                raise PolicyError(
                    "cannot mix block mappings and sequences", current.number
                )
            key, node, index = self._entry(
                current.text, current.number, indent, index + 1, depth
            )
            if key in entries:
                raise PolicyError(f"duplicate mapping key: {key}", current.number)
            entries[key] = node
        return _Node("map", entries, start_line), index

    def _sequence(self, index: int, indent: int, depth: int) -> tuple[_Node, int]:
        items: list[_Node] = []
        start_line = self.lines[index].number
        while index < len(self.lines) and self.lines[index].indent == indent:
            current = self.lines[index]
            if current.text != "-" and not current.text.startswith("- "):
                raise PolicyError(
                    "cannot mix block sequences and mappings", current.number
                )
            item_text = current.text[1:].lstrip()
            index += 1
            if not item_text:
                if index >= len(self.lines) or self.lines[index].indent != indent + 2:
                    raise PolicyError(
                        "empty sequence item must own a nested block", current.number
                    )
                item, index = self._block(index, indent + 2, depth + 1)
                items.append(item)
                continue

            try:
                _mapping_parts(item_text, current.number)
            except PolicyError:
                item = _inline_node(item_text, None, current.number)
                if index < len(self.lines) and self.lines[index].indent > indent:
                    raise PolicyError(
                        "a scalar sequence item cannot own a nested block",
                        self.lines[index].number,
                    )
                items.append(item)
                continue

            mapping_indent = indent + 2
            entries: dict[str, _Node] = {}
            key, node, index = self._entry(
                item_text, current.number, mapping_indent, index, depth + 1
            )
            entries[key] = node
            while index < len(self.lines) and self.lines[index].indent > indent:
                following = self.lines[index]
                if following.indent != mapping_indent:
                    raise PolicyError(
                        "sequence mappings use one two-space indentation level",
                        following.number,
                    )
                key, node, index = self._entry(
                    following.text,
                    following.number,
                    mapping_indent,
                    index + 1,
                    depth + 1,
                )
                if key in entries:
                    raise PolicyError(f"duplicate mapping key: {key}", following.number)
                entries[key] = node
            items.append(_Node("map", entries, current.number))
        return _Node("list", items, start_line), index


def _read_workflow(path: Path) -> str:
    expected = os.lstat(path)
    if not stat.S_ISREG(expected.st_mode):
        raise PolicyError("workflow path is not a regular file")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise PolicyError("workflow path is not a regular file")
        if (expected.st_dev, expected.st_ino) != (before.st_dev, before.st_ino):
            raise PolicyError("workflow identity changed while opening it")
        if before.st_size > MAX_WORKFLOW_BYTES:
            raise PolicyError(f"workflow exceeds {MAX_WORKFLOW_BYTES} bytes")
        chunks: list[bytes] = []
        total = 0
        while total <= MAX_WORKFLOW_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_WORKFLOW_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
        after = os.fstat(descriptor)
        identity_before = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        )
        identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        if identity_before != identity_after or len(data) != before.st_size:
            raise PolicyError("workflow changed during the bounded read")
        if len(data) > MAX_WORKFLOW_BYTES:
            raise PolicyError(f"workflow exceeds {MAX_WORKFLOW_BYTES} bytes")
    finally:
        os.close(descriptor)

    if data.startswith(b"\xef\xbb\xbf"):
        raise PolicyError("UTF-8 BOM is forbidden")
    try:
        source = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise PolicyError("workflow is not strict UTF-8") from error
    if not source.endswith("\n"):
        raise PolicyError("workflow must end with an LF")
    for index, character in enumerate(source):
        if character == "\n":
            continue
        if character in {"\r", "\t", "\x00"} or unicodedata.category(character) in {
            "Cc",
            "Cf",
            "Cs",
        }:
            line = source.count("\n", 0, index) + 1
            raise PolicyError(
                "BOM, NUL, CR, tabs, and control characters are forbidden", line
            )
    return source


def _map(node: _Node, description: str) -> dict[str, _Node]:
    if node.kind != "map":
        raise PolicyError(f"{description} must be a block mapping", node.line)
    return node.value  # type: ignore[return-value]


def _scalar(node: _Node, description: str, *, plain: bool = False) -> str:
    if node.kind != "scalar" or plain and node.style != "plain":
        suffix = " plain scalar" if plain else " scalar"
        raise PolicyError(f"{description} must be a{suffix}", node.line)
    return node.value  # type: ignore[return-value]


def _check_uv_environment(node: _Node, location: str, violations: list[str]) -> None:
    try:
        environment = _map(node, f"{location} env")
    except PolicyError as error:
        violations.append(f"{location}:{error.line}: {error.message}")
        return
    for key, value_node in environment.items():
        if not key.casefold().startswith("uv_"):
            continue
        expected = REVIEWED_UV_ENVIRONMENT.get(key)
        if expected is None:
            violations.append(
                f"{location}:{value_node.line}: unreviewed uv environment key: {key}"
            )
            continue
        try:
            actual = _scalar(value_node, f"env.{key}")
        except PolicyError as error:
            violations.append(f"{location}:{error.line}: {error.message}")
            continue
        if actual != expected:
            violations.append(
                f"{location}:{value_node.line}: env.{key} must equal {expected}"
            )


def _check_rust_toolchain(
    owner: dict[str, _Node],
    location: str,
    uses_line: int,
    violations: list[str],
) -> None:
    with_node = owner.get("with")
    if with_node is None:
        violations.append(
            f"{location}:{uses_line}: dtolnay/rust-toolchain requires an exact with mapping"
        )
        return
    try:
        inputs = _map(with_node, "dtolnay/rust-toolchain with")
    except PolicyError as error:
        violations.append(f"{location}:{error.line}: {error.message}")
        return
    if set(inputs) != {"toolchain"}:
        violations.append(
            f"{location}:{with_node.line}: dtolnay/rust-toolchain must have only "
            "the reviewed toolchain input"
        )
    toolchain = inputs.get("toolchain")
    if toolchain is not None:
        try:
            actual = _scalar(toolchain, "dtolnay/rust-toolchain input toolchain")
        except PolicyError as error:
            violations.append(f"{location}:{error.line}: {error.message}")
        else:
            if actual != RUST_TOOLCHAIN_VERSION:
                violations.append(
                    f"{location}:{toolchain.line}: dtolnay/rust-toolchain input "
                    f"toolchain must equal {RUST_TOOLCHAIN_VERSION}"
                )


def _check_uses(
    node: _Node,
    owner: dict[str, _Node],
    location: str,
    violations: list[str],
) -> int:
    try:
        action = _scalar(node, "uses", plain=True)
    except PolicyError as error:
        violations.append(f"{location}:{error.line}: {error.message}")
        return 0
    if action.startswith("./"):
        violations.append(
            f"{location}:{node.line}: local action wrappers are forbidden: {action}"
        )
        return 0
    if action.startswith("docker://"):
        violations.append(
            f"{location}:{node.line}: docker action wrappers are forbidden: {action}"
        )
        return 0

    count = 1
    action_path = action.rsplit("@", 1)[0]
    if EXTERNAL_ACTION_RE.fullmatch(action) is None or any(
        segment in {".", ".."} for segment in action_path.split("/")
    ):
        violations.append(
            f"{location}:{node.line}: external action is not pinned to a full "
            f"lowercase commit SHA: {action}"
        )
        return count

    action_name = action.split("@", 1)[0].casefold()
    if any(
        action_name == forbidden or action_name.startswith(f"{forbidden}/")
        for forbidden in FORBIDDEN_SETUP_ACTIONS
    ):
        violations.append(
            f"{location}:{node.line}: {action_name} is forbidden; use the "
            "repository-owned hash-verified tool installer"
        )
    elif action_name == "dtolnay/rust-toolchain":
        _check_rust_toolchain(owner, location, node.line, violations)
    elif action_name == "actions/checkout":
        with_node = owner.get("with")
        try:
            inputs = _map(with_node, "actions/checkout with") if with_node else {}
            persisted = inputs.get("persist-credentials")
            if (
                persisted is None
                or _scalar(persisted, "persist-credentials", plain=True) != "false"
            ):
                raise PolicyError(
                    "actions/checkout must set persist-credentials: false", node.line
                )
        except PolicyError as error:
            violations.append(f"{location}:{error.line}: {error.message}")
    return count


def _inspect_workflow(root: _Node, relative: Path) -> tuple[int, list[str]]:
    violations: list[str] = []
    count = 0
    root_map = _map(root, "workflow root")
    if "env" in root_map:
        _check_uv_environment(root_map["env"], str(relative), violations)
    jobs_node = root_map.get("jobs")
    if jobs_node is None:
        return 0, [f"{relative}: workflow must contain a jobs mapping"]
    jobs = _map(jobs_node, "jobs")
    for job_name, job_node in jobs.items():
        location = f"{relative}:jobs.{job_name}"
        try:
            job = _map(job_node, location)
        except PolicyError as error:
            violations.append(f"{relative}:{error.line}: {error.message}")
            continue
        if "env" in job:
            _check_uv_environment(job["env"], location, violations)
        has_job_uses = "uses" in job
        has_steps = "steps" in job
        if has_job_uses == has_steps:
            violations.append(
                f"{location}:{job_node.line}: job must define exactly one of uses or steps"
            )
            continue
        if has_job_uses:
            count += _check_uses(job["uses"], job, location, violations)
            continue
        steps_node = job["steps"]
        if steps_node.kind != "list" or steps_node.style == "flow":
            violations.append(
                f"{location}:{steps_node.line}: steps must be a block sequence of mappings"
            )
            continue
        for step_index, step_node in enumerate(steps_node.value, 1):
            step_location = f"{location}.steps[{step_index}]"
            if step_node.kind != "map":
                violations.append(
                    f"{step_location}:{step_node.line}: each step must be a block mapping"
                )
                continue
            step = step_node.value
            if "env" in step:
                _check_uv_environment(step["env"], step_location, violations)
            if "uses" in step:
                count += _check_uses(step["uses"], step, step_location, violations)
    return count, violations


def main() -> int:
    violations: list[str] = []
    external_count = 0
    try:
        entries = list(WORKFLOW_ROOT.iterdir())
    except OSError as error:
        print(
            f"GitHub Actions pin policy failed: cannot enumerate workflows: {error}",
            file=sys.stderr,
        )
        return 1
    workflow_paths = sorted(
        path for path in entries if path.suffix in {".yml", ".yaml"}
    )
    if len(workflow_paths) > MAX_WORKFLOW_FILES:
        violations.append(f"workflow directory exceeds {MAX_WORKFLOW_FILES} YAML files")
        workflow_paths = workflow_paths[:MAX_WORKFLOW_FILES]
    for path in workflow_paths:
        relative = path.relative_to(REPOSITORY_ROOT)
        try:
            source = _read_workflow(path)
            root = _Parser(_logical_lines(source)).parse()
            count, path_violations = _inspect_workflow(root, relative)
            external_count += count
            violations.extend(path_violations)
        except (OSError, PolicyError) as error:
            if isinstance(error, PolicyError):
                line = f":{error.line}" if error.line is not None else ""
                message = error.message
            else:
                line = ""
                message = str(error)
            violations.append(f"{relative}{line}: {message}")
    if external_count == 0:
        violations.append(
            "no external workflow actions were found in executable job locations"
        )
    if violations:
        print("GitHub Actions pin policy failed:", file=sys.stderr)
        print("\n".join(f"  {violation}" for violation in violations), file=sys.stderr)
        return 1
    print(f"GitHub Actions pin policy passed: {external_count} external uses entries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
