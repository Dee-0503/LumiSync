#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath

FORBIDDEN_STRINGS = (".build", "/Users/", "/private/tmp/")
CODE_ROOT_DIRECTORIES = ("Contents/MacOS", "Contents/Helpers", "Contents/Frameworks", "Contents/PlugIns", "Contents/XPCServices")
BUNDLE_SUFFIXES = (".app", ".appex", ".xpc", ".framework", ".bundle")
REQUIRED_EXECUTABLES = {
    "app": ("Contents/MacOS/LumiSync", "LumiSyncApp"),
    "controller": ("Contents/Helpers/lumisync-backlight-controller", "lumisync-backlight-controller"),
    "supervisor": ("Contents/Helpers/lumisync-backlight-supervisor", "lumisync-backlight-supervisor"),
    "writer": ("Contents/Helpers/lumisync-backlight-writer", "lumisync-backlight-writer"),
}
ALLOWED_EXECUTABLE_ROLES = {*REQUIRED_EXECUTABLES, "framework", "appex", "xpc", "bundle"}
MOCK_ARCH_PREFIX = "MOCK_MACHO_ARCH="
MOCK_DEPENDENCY_PREFIX = "MOCK_DEPENDENCY="
MOCK_RPATH_PREFIX = "MOCK_RPATH="


class ManifestError(ValueError):
    pass


def load_manifest(path: Path) -> list[dict[str, str]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read manifest: {error}") from error

    if not isinstance(document, dict) or set(document) != {"version", "executables"}:
        raise ManifestError("manifest must contain only version and executables")
    if document["version"] != 1:
        raise ManifestError("manifest version must be 1")
    entries = document["executables"]
    if not isinstance(entries, list) or not entries:
        raise ManifestError("manifest executables must be a nonempty array")

    paths: set[str] = set()
    roles: set[str] = set()
    parsed: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "product", "role"}:
            raise ManifestError("each executable must contain only path, product, and role")
        if not all(isinstance(entry[key], str) and entry[key] for key in entry):
            raise ManifestError("executable path, product, and role must be nonempty strings")
        if any(any(ord(character) < 0x20 or ord(character) == 0x7F for character in entry[key]) for key in entry):
            raise ManifestError("manifest fields must not contain control characters")

        path_value = entry["path"]
        manifest_path = PurePosixPath(path_value)
        if manifest_path.is_absolute():
            raise ManifestError(f"executable path must be relative: {path_value}")
        if ".." in manifest_path.parts:
            raise ManifestError(f"executable path must not contain traversal: {path_value}")
        if "\\" in path_value or manifest_path.as_posix() != path_value:
            raise ManifestError(f"executable path must use canonical relative syntax: {path_value}")
        if path_value in paths:
            raise ManifestError(f"duplicate executable path: {path_value}")
        if entry["role"] not in ALLOWED_EXECUTABLE_ROLES:
            raise ManifestError(f"unknown executable role: {entry['role']}")
        if entry["role"] in roles:
            raise ManifestError(f"duplicate executable role: {entry['role']}")
        if len(manifest_path.parts) < 3 or manifest_path.parts[0] != "Contents":
            raise ManifestError(f"executable path must be under Contents: {path_value}")

        paths.add(path_value)
        roles.add(entry["role"])
        parsed.append(entry)

    entries_by_role = {entry["role"]: entry for entry in parsed}
    missing_roles = [role for role in REQUIRED_EXECUTABLES if role not in entries_by_role]
    if missing_roles:
        raise ManifestError(
            "missing required executable roles: " + ", ".join(missing_roles)
        )
    for role, (required_path, required_product) in REQUIRED_EXECUTABLES.items():
        entry = entries_by_role[role]
        if entry["path"] != required_path:
            raise ManifestError(f"required executable role {role} must use path {required_path}")
        if entry["product"] != required_product:
            raise ManifestError(f"required executable role {role} must use product {required_product}")
    return parsed


def command_output(arguments: list[str]) -> tuple[int, str]:
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    except OSError as error:
        return 127, str(error)
    output = f"{result.stdout}\n{result.stderr}".strip()
    return result.returncode, output


def command_output_required(arguments: list[str], label: str) -> str:
    status, output = command_output(arguments)
    if status != 0:
        raise ValueError(f"{label} failed (exit {status}): {output}")
    return output


def mock_metadata(path: Path) -> tuple[str | None, list[str]] | None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    if not any(line.startswith(MOCK_ARCH_PREFIX) for line in lines):
        return None

    architecture = next(
        (line.removeprefix(MOCK_ARCH_PREFIX) for line in lines if line.startswith(MOCK_ARCH_PREFIX)),
        None,
    )
    dependencies = [
        line.removeprefix(prefix)
        for line in lines
        for prefix in (MOCK_DEPENDENCY_PREFIX, MOCK_RPATH_PREFIX)
        if line.startswith(prefix)
    ]
    return architecture, dependencies


def macho_metadata(path: Path, allow_mock: bool, display_path: str) -> tuple[str | None, list[str]]:
    if allow_mock:
        mocked = mock_metadata(path)
        if mocked is not None:
            return mocked

    file_description = command_output_required(["/usr/bin/file", str(path)], f"file failed for {display_path}")
    if "Mach-O" not in file_description:
        return None, []
    architecture_matches = re.findall(r"\b(arm64e|arm64|x86_64)\b", file_description)
    architectures = ",".join(dict.fromkeys(architecture_matches))
    if not architectures:
        architectures = file_description
    dependencies = [
        command_output_required(["/usr/bin/otool", "-L", str(path)], f"otool failed for {display_path}"),
        command_output_required(["/usr/bin/otool", "-l", str(path)], f"otool failed for {display_path}"),
    ]
    return architectures, dependencies


def first_symlink_component(app: Path, relative: str) -> str | None:
    current = app
    parts = PurePosixPath(relative).parts
    for index, part in enumerate(parts):
        current /= part
        try:
            if stat.S_ISLNK(current.lstat().st_mode):
                return "/".join(parts[: index + 1])
        except FileNotFoundError:
            return None
    return None


def code_roots(app: Path) -> list[Path]:
    roots = [app / directory for directory in CODE_ROOT_DIRECTORIES]
    for path in app.rglob("*"):
        try:
            mode = path.lstat().st_mode
        except OSError:
            continue
        if stat.S_ISDIR(mode) and path.suffix in BUNDLE_SUFFIXES:
            roots.append(path)
    return roots


def find_code_path_errors(app: Path, expected: set[str]) -> list[str]:
    errors: list[str] = []
    seen: set[Path] = set()
    strict_roots = {app / "Contents/MacOS", app / "Contents/Helpers"}
    for root in code_roots(app):
        if root in seen:
            continue
        seen.add(root)
        relative_root = root.relative_to(app).as_posix()
        try:
            root_mode = root.lstat().st_mode
        except FileNotFoundError:
            continue
        except OSError as error:
            errors.append(f"cannot inspect code path {relative_root}: {error}")
            continue
        if root_mode & 0o022:
            errors.append(f"group/world-writable code path: {relative_root}")
        if stat.S_ISLNK(root_mode):
            errors.append(f"unexpected symlink in code path: {relative_root}")
            continue
        if not stat.S_ISDIR(root_mode):
            continue
        for child in root.rglob("*"):
            relative = child.relative_to(app).as_posix()
            try:
                mode = child.lstat().st_mode
            except OSError as error:
                errors.append(f"cannot inspect code path {relative}: {error}")
                continue
            if mode & 0o022:
                errors.append(f"group/world-writable code path: {relative}")
            if stat.S_ISLNK(mode):
                errors.append(f"unexpected symlink in code path: {relative}")
            elif root in strict_roots and stat.S_ISREG(mode) and relative not in expected:
                errors.append(f"unexpected executable: {relative}")
    return errors


def discover_macho_objects(app: Path, allow_mock: bool) -> tuple[list[tuple[str, Path]], list[str]]:
    objects: list[tuple[str, Path]] = []
    errors: list[str] = []
    for candidate in app.rglob("*"):
        relative = candidate.relative_to(app).as_posix()
        try:
            mode = candidate.lstat().st_mode
        except OSError as error:
            errors.append(f"cannot inspect code path {relative}: {error}")
            continue
        if not stat.S_ISREG(mode):
            continue
        try:
            architecture, _ = macho_metadata(candidate, allow_mock, relative)
        except ValueError as error:
            errors.append(f"{error} ({relative})")
            continue
        if architecture is not None:
            objects.append((relative, candidate))
    return objects, errors


def validate_bundle(
    app: Path,
    manifest: Path,
    version: str,
    build_number: str,
    allow_mock_macho: bool,
) -> list[str]:
    errors: list[str] = []
    try:
        entries = load_manifest(manifest)
    except ManifestError as error:
        return [str(error)]

    if not app.is_dir():
        return [f"app bundle is missing: {app}"]

    expected = {entry["path"] for entry in entries}
    errors.extend(find_code_path_errors(app, expected))

    existing_executables: list[tuple[str, Path]] = []
    for entry in entries:
        relative = entry["path"]
        executable = app / relative
        symlink_component = first_symlink_component(app, relative)
        if symlink_component == relative:
            errors.append(f"expected executable must not be a symlink: {relative}")
            continue
        if symlink_component is not None:
            errors.append(f"expected executable path must not contain a symlink: {relative}")
            continue
        try:
            mode = executable.lstat().st_mode
        except FileNotFoundError:
            errors.append(f"missing expected executable: {relative}")
            continue
        except OSError as error:
            errors.append(f"cannot inspect expected executable {relative}: {error}")
            continue

        if stat.S_ISLNK(mode):
            errors.append(f"expected executable must not be a symlink: {relative}")
            continue
        if not stat.S_ISREG(mode):
            errors.append(f"expected executable must be a regular file: {relative}")
            continue
        if mode & 0o111 == 0:
            errors.append(f"expected executable is not executable: {relative}")
        if mode & 0o022:
            errors.append(f"group/world-writable executable: {relative}")
        existing_executables.append((relative, executable))

    discovered_macho, discovery_errors = discover_macho_objects(app, allow_mock_macho)
    errors.extend(discovery_errors)
    discovered_paths = {relative for relative, _ in discovered_macho}
    for relative in sorted(discovered_paths - expected):
        errors.append(f"undeclared Mach-O object: {relative}")
    for relative in sorted(expected - discovered_paths):
        if not any(error.startswith(f"missing expected executable: {relative}") for error in errors):
            errors.append(f"expected manifest executable is not a Mach-O object: {relative}")

    plist_path = app / "Contents/Info.plist"
    try:
        with plist_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        errors.append(f"cannot read Info.plist: {error}")
        info = {}

    found_version = info.get("CFBundleShortVersionString")
    if found_version != version:
        errors.append(f"CFBundleShortVersionString must be {version}, found {found_version}")
    found_build = info.get("CFBundleVersion")
    if str(found_build) != build_number:
        errors.append(f"CFBundleVersion must be {build_number}, found {found_build}")

    bundle_executable = info.get("CFBundleExecutable")
    if not isinstance(bundle_executable, str) or not bundle_executable:
        errors.append("CFBundleExecutable must name the app executable")
    else:
        required_app_path = f"Contents/MacOS/{bundle_executable}"
        app_entry = next(entry for entry in entries if entry["role"] == "app")
        if app_entry["path"] != required_app_path:
            errors.append(f"app executable must match CFBundleExecutable: {required_app_path}")

    icon_name = info.get("CFBundleIconFile")
    if not isinstance(icon_name, str) or not icon_name:
        errors.append("CFBundleIconFile must name an icon resource")
    else:
        icon_path = PurePosixPath(icon_name)
        if icon_path.is_absolute() or ".." in icon_path.parts or "\\" in icon_name or icon_path.as_posix() != icon_name:
            errors.append("CFBundleIconFile must be a relative resource name")
        else:
            icon_file = icon_name if icon_path.suffix else f"{icon_name}.icns"
            icon_relative = f"Contents/Resources/{icon_file}"
            icon_resource = app / icon_relative
            try:
                icon_mode = icon_resource.lstat().st_mode
            except OSError:
                errors.append(f"missing icon resource: {icon_relative}")
            else:
                if not stat.S_ISREG(icon_mode) or stat.S_ISLNK(icon_mode) or first_symlink_component(app, icon_relative) is not None:
                    errors.append(f"icon resource must be a regular non-symlink file: {icon_relative}")

    resources = app / "Contents/Resources"
    localization_bundles = list(resources.glob("*.bundle")) if resources.is_dir() else []
    if not any(any(bundle.rglob("*.lproj")) or bundle.name == "LumiSync_LumiSyncAppSupport.bundle" for bundle in localization_bundles):
        errors.append("missing localization resource bundle")

    repository_path = str(Path(__file__).resolve().parent.parent)
    forbidden = (*FORBIDDEN_STRINGS, repository_path)
    for relative, executable in existing_executables:
        try:
            architecture, dependencies = macho_metadata(executable, allow_mock_macho, relative)
        except ValueError as error:
            errors.append(f"{error} ({relative})")
            continue
        if architecture is None:
            errors.append(f"expected Mach-O executable: {relative}")
            continue
        if architecture != "arm64":
            errors.append(f"Mach-O architecture must be arm64: {relative} ({architecture})")
        is_mock_macho = allow_mock_macho and mock_metadata(executable) is not None
        for dependency in dependencies:
            load_command_contents = dependency if is_mock_macho else "\n".join(dependency.splitlines()[1:])
            for fragment in forbidden:
                if fragment and fragment in load_command_contents:
                    errors.append(f"forbidden dependency or rpath string '{fragment}' in {relative}")

    return errors


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify an unsigned LumiSync release bundle.")
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument(
        "--allow-mock-macho",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    errors = validate_bundle(
        arguments.app,
        arguments.manifest,
        arguments.version,
        arguments.build_number,
        arguments.allow_mock_macho,
    )
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Verified unsigned release bundle: {arguments.app}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
