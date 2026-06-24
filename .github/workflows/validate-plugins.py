#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

ROOT_STRING_FIELDS = (
    "id",
    "name",
    "version",
    "min_noctalia",
    "author",
    "license",
    "icon",
    "description",
)
ROOT_ARRAY_FIELDS = ("dependencies", "tags")
ENTRY_TYPES = ("widget", "panel", "shortcut", "desktop_widget", "launcher_provider", "service")
SETTING_OWNER_TYPES = ("widget", "panel", "desktop_widget", "launcher_provider")
SETTING_TYPES = {"string", "string_list", "bool", "glyph", "select", "folder", "int", "color"}

ROOT_FIELDS = set(ROOT_STRING_FIELDS) | set(ROOT_ARRAY_FIELDS) | set(ENTRY_TYPES) | {
    "setting",
    "deprecated",
}
BASE_ENTRY_FIELDS = {"id", "entry"}
ENTRY_FIELDS = {
    "widget": BASE_ENTRY_FIELDS | {"setting"},
    "panel": BASE_ENTRY_FIELDS | {"setting", "width", "height"},
    "desktop_widget": BASE_ENTRY_FIELDS | {"setting"},
    "service": BASE_ENTRY_FIELDS,
    "shortcut": BASE_ENTRY_FIELDS,
    "launcher_provider": BASE_ENTRY_FIELDS
    | {"prefix", "glyph", "include_in_global_search", "debounce_ms", "setting"},
}
SETTING_FIELDS = {
    "key",
    "type",
    "label_key",
    "description_key",
    "default",
    "options",
    "min",
    "max",
    "step",
    "visible_when",
    "advanced",
}
OPTION_FIELDS = {"value", "label_key"}
VISIBLE_WHEN_FIELDS = {"key", "values"}


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return isinstance(value, int | float) and not isinstance(value, bool)


def rel(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def has_key_path(data: Any, dotted_key: str) -> bool:
    if isinstance(data, dict) and dotted_key in data:
        return True

    current = data
    for part in dotted_key.split("."):
        if not isinstance(current, dict) or part not in current:
            return False
        current = current[part]
    return True


class Validator:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.errors: list[str] = []

    def add_error(self, path: Path, message: str) -> None:
        self.errors.append(f"{rel(self.root, path)}: {message}")

    def add_context_error(self, path: Path, context: str, message: str) -> None:
        self.add_error(path, f"{context}: {message}")

    def load_manifest(self, path: Path) -> dict[str, Any] | None:
        try:
            with path.open("rb") as handle:
                manifest = tomllib.load(handle)
        except tomllib.TOMLDecodeError as error:
            self.add_error(path, f"invalid TOML: {error}")
            return None

        if not isinstance(manifest, dict):
            self.add_error(path, "expected a TOML table")
            return None
        return manifest

    def load_english_translations(self, plugin_dir: Path) -> Any | None:
        path = plugin_dir / "translations" / "en.json"
        if not path.exists():
            return None

        try:
            with path.open("r", encoding="utf-8") as handle:
                translations = json.load(handle)
        except json.JSONDecodeError as error:
            self.add_error(path, f"invalid JSON: {error}")
            return None

        if not isinstance(translations, dict):
            self.add_error(path, "expected a JSON object")
            return None
        return translations

    def validate_translation_key(
        self,
        manifest_path: Path,
        translations: Any | None,
        context: str,
        field: str,
        value: Any,
    ) -> None:
        if not is_non_empty_string(value):
            self.add_context_error(manifest_path, context, f"{field} must be a non-empty string")
            return

        if translations is None:
            self.add_context_error(
                manifest_path,
                context,
                f"{field} references '{value}', but translations/en.json is missing or invalid",
            )
            return

        if not has_key_path(translations, value):
            self.add_context_error(
                manifest_path,
                context,
                f"{field} references missing translations/en.json key '{value}'",
            )

    def validate_string_list(
        self,
        manifest_path: Path,
        context: str,
        field: str,
        value: Any,
        *,
        allow_empty: bool,
    ) -> None:
        if not isinstance(value, list):
            self.add_context_error(manifest_path, context, f"{field} must be a list of strings")
            return

        if not allow_empty and not value:
            self.add_context_error(manifest_path, context, f"{field} must not be empty")

        seen: set[str] = set()
        for index, item in enumerate(value):
            if not is_non_empty_string(item):
                self.add_context_error(
                    manifest_path,
                    context,
                    f"{field}[{index}] must be a non-empty string",
                )
                continue
            if item in seen:
                self.add_context_error(manifest_path, context, f"{field} contains duplicate '{item}'")
            seen.add(item)

    def validate_root_fields(self, manifest_path: Path, manifest: dict[str, Any]) -> None:
        unknown = sorted(set(manifest) - ROOT_FIELDS)
        for field in unknown:
            self.add_error(manifest_path, f"unknown root field '{field}'")

        for field in ROOT_STRING_FIELDS:
            if field not in manifest:
                self.add_error(manifest_path, f"missing required root field '{field}'")
            elif not is_non_empty_string(manifest[field]):
                self.add_error(manifest_path, f"root field '{field}' must be a non-empty string")

        for field in ROOT_ARRAY_FIELDS:
            if field not in manifest:
                self.add_error(manifest_path, f"missing required root field '{field}'")

        if "dependencies" in manifest:
            self.validate_string_list(
                manifest_path,
                "root",
                "dependencies",
                manifest["dependencies"],
                allow_empty=True,
            )

        if "tags" in manifest:
            self.validate_string_list(manifest_path, "root", "tags", manifest["tags"], allow_empty=False)

        if "deprecated" in manifest and not isinstance(manifest["deprecated"], bool):
            self.add_error(manifest_path, "root field 'deprecated' must be a bool")

        plugin_dir = manifest_path.parent.name
        expected_id = f"noctalia/{plugin_dir}"
        if is_non_empty_string(manifest.get("id")) and manifest["id"] != expected_id:
            self.add_error(manifest_path, f"id must be '{expected_id}'")

        for field in ("version", "min_noctalia"):
            value = manifest.get(field)
            if is_non_empty_string(value) and not SEMVER_RE.fullmatch(value):
                self.add_error(manifest_path, f"root field '{field}' must use MAJOR.MINOR.PATCH")

    def validate_entry_path(self, manifest_path: Path, context: str, plugin_dir: Path, value: Any) -> None:
        if not is_non_empty_string(value):
            self.add_context_error(manifest_path, context, "entry must be a non-empty string")
            return

        raw_path = Path(value)
        if raw_path.is_absolute() or ".." in raw_path.parts:
            self.add_context_error(manifest_path, context, "entry must stay inside the plugin directory")
            return

        entry_path = plugin_dir / raw_path
        try:
            entry_path.resolve().relative_to(plugin_dir.resolve())
        except ValueError:
            self.add_context_error(manifest_path, context, "entry must stay inside the plugin directory")
            return

        if not entry_path.is_file():
            self.add_context_error(
                manifest_path,
                context,
                f"entry file '{value}' does not exist",
            )

    def validate_launcher_fields(self, manifest_path: Path, context: str, entry: dict[str, Any]) -> None:
        for field in ("prefix", "glyph"):
            if field in entry and not is_non_empty_string(entry[field]):
                self.add_context_error(manifest_path, context, f"{field} must be a non-empty string")

        if "include_in_global_search" in entry and not isinstance(entry["include_in_global_search"], bool):
            self.add_context_error(
                manifest_path,
                context,
                "include_in_global_search must be a bool",
            )

        if "debounce_ms" in entry:
            debounce_ms = entry["debounce_ms"]
            if not is_int(debounce_ms) or debounce_ms < 0:
                self.add_context_error(
                    manifest_path,
                    context,
                    "debounce_ms must be a non-negative integer",
                )

    def validate_panel_fields(self, manifest_path: Path, context: str, entry: dict[str, Any]) -> None:
        for field in ("width", "height"):
            if field not in entry:
                continue

            value = entry[field]
            if not is_number(value) or value < 0:
                self.add_context_error(manifest_path, context, f"{field} must be a non-negative number")

    def validate_entries(
        self,
        manifest_path: Path,
        manifest: dict[str, Any],
        translations: Any | None,
    ) -> None:
        plugin_dir = manifest_path.parent
        entry_count = 0
        seen_ids: dict[str, str] = {}

        for entry_type in ENTRY_TYPES:
            entries = manifest.get(entry_type, [])
            if not isinstance(entries, list):
                self.add_error(manifest_path, f"'{entry_type}' must be an array of tables")
                continue

            for index, entry in enumerate(entries):
                entry_count += 1
                context = f"{entry_type}[{index}]"
                if not isinstance(entry, dict):
                    self.add_context_error(manifest_path, context, "must be a table")
                    continue

                unknown = sorted(set(entry) - ENTRY_FIELDS[entry_type])
                for field in unknown:
                    self.add_context_error(manifest_path, context, f"unknown field '{field}'")

                entry_id = entry.get("id")
                if not is_non_empty_string(entry_id):
                    self.add_context_error(manifest_path, context, "id must be a non-empty string")
                elif entry_id in seen_ids:
                    self.add_context_error(
                        manifest_path,
                        context,
                        f"id '{entry_id}' is already used by {seen_ids[entry_id]}",
                    )
                else:
                    seen_ids[entry_id] = context

                self.validate_entry_path(manifest_path, context, plugin_dir, entry.get("entry"))

                if entry_type == "launcher_provider":
                    self.validate_launcher_fields(manifest_path, context, entry)

                if entry_type == "panel":
                    self.validate_panel_fields(manifest_path, context, entry)

                if entry_type in SETTING_OWNER_TYPES and "setting" in entry:
                    self.validate_settings(
                        manifest_path,
                        translations,
                        entry["setting"],
                        f"{context}.setting",
                    )

        if entry_count == 0:
            self.add_error(
                manifest_path,
                "must define at least one entry: widget, panel, shortcut, desktop_widget, launcher_provider, or service",
            )

    def validate_default(
        self,
        manifest_path: Path,
        context: str,
        setting_type: str,
        setting: dict[str, Any],
        option_values: list[str],
    ) -> None:
        if "default" not in setting:
            if setting_type != "folder":
                self.add_context_error(manifest_path, context, "default is required")
            return

        default = setting["default"]
        if setting_type in {"string", "folder"} and not isinstance(default, str):
            self.add_context_error(manifest_path, context, "default must be a string")
        elif setting_type in {"glyph", "color"} and not is_non_empty_string(default):
            self.add_context_error(manifest_path, context, "default must be a non-empty string")
        elif setting_type == "string_list":
            self.validate_string_list(manifest_path, context, "default", default, allow_empty=True)
        elif setting_type == "bool" and not isinstance(default, bool):
            self.add_context_error(manifest_path, context, "default must be a bool")
        elif setting_type == "int" and not is_int(default):
            self.add_context_error(manifest_path, context, "default must be an integer")
        elif setting_type == "select":
            if not is_non_empty_string(default):
                self.add_context_error(manifest_path, context, "default must be a non-empty string")
            elif default not in option_values:
                self.add_context_error(manifest_path, context, "default must match one of the option values")

    def validate_options(
        self,
        manifest_path: Path,
        translations: Any | None,
        context: str,
        setting: dict[str, Any],
    ) -> list[str]:
        options = setting.get("options")
        setting_type = setting.get("type")

        if options is None:
            if setting_type == "select":
                self.add_context_error(manifest_path, context, "select settings require options")
            return []

        if setting_type != "select":
            self.add_context_error(manifest_path, context, "options is only valid for select settings")

        if not isinstance(options, list):
            self.add_context_error(manifest_path, context, "options must be a list of tables")
            return []

        if not options:
            self.add_context_error(manifest_path, context, "options must not be empty")

        values: list[str] = []
        seen: set[str] = set()
        for index, option in enumerate(options):
            option_context = f"{context}.options[{index}]"
            if not isinstance(option, dict):
                self.add_context_error(manifest_path, option_context, "must be a table")
                continue

            unknown = sorted(set(option) - OPTION_FIELDS)
            for field in unknown:
                self.add_context_error(manifest_path, option_context, f"unknown field '{field}'")

            value = option.get("value")
            if not is_non_empty_string(value):
                self.add_context_error(manifest_path, option_context, "value must be a non-empty string")
            else:
                values.append(value)
                if value in seen:
                    self.add_context_error(
                        manifest_path,
                        option_context,
                        f"duplicate option value '{value}'",
                    )
                seen.add(value)

            self.validate_translation_key(
                manifest_path,
                translations,
                option_context,
                "label_key",
                option.get("label_key"),
            )

        return values

    def validate_int_bounds(self, manifest_path: Path, context: str, setting: dict[str, Any]) -> None:
        setting_type = setting.get("type")
        bound_values: dict[str, int] = {}

        for field in ("min", "max", "step"):
            if field not in setting:
                continue
            value = setting[field]
            if setting_type != "int":
                self.add_context_error(manifest_path, context, f"{field} is only valid for int settings")
            elif not is_int(value):
                self.add_context_error(manifest_path, context, f"{field} must be an integer")
            else:
                bound_values[field] = value

        if "min" in bound_values and "max" in bound_values and bound_values["min"] > bound_values["max"]:
            self.add_context_error(manifest_path, context, "min must be less than or equal to max")

        if "step" in bound_values and bound_values["step"] <= 0:
            self.add_context_error(manifest_path, context, "step must be greater than zero")

        default = setting.get("default")
        if setting_type == "int" and is_int(default):
            if "min" in bound_values and default < bound_values["min"]:
                self.add_context_error(manifest_path, context, "default must be greater than or equal to min")
            if "max" in bound_values and default > bound_values["max"]:
                self.add_context_error(manifest_path, context, "default must be less than or equal to max")

    def validate_visible_when(self, manifest_path: Path, context: str, value: Any) -> None:
        if value is None:
            return

        if not isinstance(value, dict):
            self.add_context_error(manifest_path, context, "visible_when must be a table")
            return

        unknown = sorted(set(value) - VISIBLE_WHEN_FIELDS)
        for field in unknown:
            self.add_context_error(manifest_path, context, f"visible_when has unknown field '{field}'")

        if not is_non_empty_string(value.get("key")):
            self.add_context_error(manifest_path, context, "visible_when.key must be a non-empty string")

        values = value.get("values")
        if not isinstance(values, list) or not values:
            self.add_context_error(
                manifest_path,
                context,
                "visible_when.values must be a non-empty list of strings",
            )
            return

        for index, item in enumerate(values):
            if not is_non_empty_string(item):
                self.add_context_error(
                    manifest_path,
                    context,
                    f"visible_when.values[{index}] must be a non-empty string",
                )

    def validate_settings(
        self,
        manifest_path: Path,
        translations: Any | None,
        settings: Any,
        context_prefix: str,
    ) -> None:
        if not isinstance(settings, list):
            self.add_context_error(manifest_path, context_prefix, "must be an array of tables")
            return

        seen_keys: set[str] = set()
        for index, setting in enumerate(settings):
            context = f"{context_prefix}[{index}]"
            if not isinstance(setting, dict):
                self.add_context_error(manifest_path, context, "must be a table")
                continue

            unknown = sorted(set(setting) - SETTING_FIELDS)
            for field in unknown:
                self.add_context_error(manifest_path, context, f"unknown field '{field}'")

            key = setting.get("key")
            if not is_non_empty_string(key):
                self.add_context_error(manifest_path, context, "key must be a non-empty string")
            elif key in seen_keys:
                self.add_context_error(manifest_path, context, f"duplicate setting key '{key}'")
            else:
                seen_keys.add(key)

            setting_type = setting.get("type")
            if not is_non_empty_string(setting_type):
                self.add_context_error(manifest_path, context, "type must be a non-empty string")
                setting_type = ""
            elif setting_type not in SETTING_TYPES:
                self.add_context_error(manifest_path, context, f"unsupported setting type '{setting_type}'")

            self.validate_translation_key(
                manifest_path,
                translations,
                context,
                "label_key",
                setting.get("label_key"),
            )

            if "description_key" in setting:
                self.validate_translation_key(
                    manifest_path,
                    translations,
                    context,
                    "description_key",
                    setting.get("description_key"),
                )

            option_values = self.validate_options(manifest_path, translations, context, setting)
            if setting_type in SETTING_TYPES:
                self.validate_default(manifest_path, context, setting_type, setting, option_values)

            self.validate_int_bounds(manifest_path, context, setting)
            self.validate_visible_when(manifest_path, context, setting.get("visible_when"))

            if "advanced" in setting and not isinstance(setting["advanced"], bool):
                self.add_context_error(manifest_path, context, "advanced must be a bool")

    def validate_manifest(self, manifest_path: Path) -> None:
        manifest = self.load_manifest(manifest_path)
        if manifest is None:
            return

        plugin_dir = manifest_path.parent
        translations = self.load_english_translations(plugin_dir)

        self.validate_root_fields(manifest_path, manifest)

        if "setting" in manifest:
            self.validate_settings(manifest_path, translations, manifest["setting"], "setting")

        self.validate_entries(manifest_path, manifest, translations)

    def validate(self) -> int:
        manifests = sorted(self.root.glob("*/plugin.toml"))
        if not manifests:
            self.errors.append("no plugin manifests found")
            return 1

        for manifest_path in manifests:
            self.validate_manifest(manifest_path)

        if self.errors:
            for error in self.errors:
                print(f"error: {error}", file=sys.stderr)
            return 1

        print(f"Validated {len(manifests)} plugin manifest(s).")
        return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate official Noctalia plugin manifests.")
    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_ROOT,
        help="Repository root to validate. Defaults to the current repository.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    return Validator(args.root).validate()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
