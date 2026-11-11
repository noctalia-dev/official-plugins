from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VALIDATOR_PATH = Path(__file__).with_name("validate-plugins.py")
SPEC = importlib.util.spec_from_file_location("validate_plugins", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
validate_plugins = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validate_plugins)


class ProfileTestCase(unittest.TestCase):
    """Shared behavior is exercised once for each repository policy."""

    profile = "community"

    def __str__(self) -> str:
        return f"{super().__str__()} [{self.profile}]"


class LauncherPrefixTests(ProfileTestCase):
    def validate_prefix(self, prefix: str) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_launcher_fields(
            Path("/repo/example/plugin.toml"),
            "launcher_provider[0]",
            {"prefix": prefix},
        )
        return validator.errors

    def test_accepts_lowercase_ascii_letters(self) -> None:
        self.assertEqual(self.validate_prefix("bla"), [])

    def test_rejects_leading_symbol(self) -> None:
        self.assertNotEqual(self.validate_prefix("/bla"), [])

    def test_rejects_uppercase_letters(self) -> None:
        self.assertNotEqual(self.validate_prefix("Bla"), [])

    def test_rejects_digits(self) -> None:
        self.assertNotEqual(self.validate_prefix("bla2"), [])

    def test_rejects_other_symbols(self) -> None:
        self.assertNotEqual(self.validate_prefix("bla-bla"), [])


class AllowedTagsTests(ProfileTestCase):
    def validate_tags(self, tags: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_tags(Path("/repo/example/plugin.toml"), tags)
        return validator.errors

    def test_accepts_every_allowed_tag(self) -> None:
        self.assertEqual(self.validate_tags(sorted(validate_plugins.ALLOWED_TAGS)), [])

    def test_rejects_unknown_tag(self) -> None:
        self.assertEqual(
            self.validate_tags(["utility", "unknown"]),
            [
                "example/plugin.toml: root: "
                "tags[1] 'unknown' is not an allowed tag"
            ],
        )

    def test_rejects_wrong_case(self) -> None:
        self.assertNotEqual(self.validate_tags(["Utility"]), [])

    def test_retains_string_list_validation(self) -> None:
        errors = self.validate_tags(["utility", "utility", ""])
        self.assertTrue(any("duplicate 'utility'" in error for error in errors))
        self.assertTrue(any("tags[2] must be a non-empty string" in error for error in errors))


class DescriptionTests(ProfileTestCase):
    def validate_description(self, description: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_description(Path("/repo/example/plugin.toml"), description)
        return validator.errors

    def test_accepts_description_at_limit(self) -> None:
        self.assertEqual(
            self.validate_description("Monitor battery status from the desktop.".ljust(validate_plugins.DESCRIPTION_MAX_CHARS)),
            [],
        )

    def test_rejects_description_over_limit(self) -> None:
        errors = self.validate_description(
            "Monitor battery status from the desktop.".ljust(validate_plugins.DESCRIPTION_MAX_CHARS + 1)
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("is 121 characters", errors[0])
        self.assertIn("at or below 120", errors[0])


class EnglishProseTests(unittest.TestCase):
    def test_rejects_non_english_descriptions_including_ascii(self) -> None:
        for description in (
            "Управление шумоподавлением и батареей для наушников серии HONOR CHOICE",
            "Akıl Kuran'ın public Günün Ayeti API'sinden günlük ayeti masaüstünde gösteren eklenti.",
            "Ce plugin permet de surveiller les mises a jour et de configurer les notifications.",
            "Este plugin permite controlar los auriculares y consultar el nivel de bateria.",
        ):
            with self.subTest(description=description):
                validator = validate_plugins.Validator(Path("/repo"))
                validator.validate_description(Path("/repo/example/plugin.toml"), description)
                self.assertTrue(any("must be English" in error for error in validator.errors))

    def validate_language(self, files: dict[str, str]) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            for name, contents in files.items():
                path = plugin_dir / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")
            validator = validate_plugins.Validator(root)
            validator.validate_readme_language(plugin_dir)
            return validator.errors

    def test_rejects_translated_section_with_original_line_number(self) -> None:
        errors = self.validate_language({
            "README.md": "# Example\n\nEnglish documentation.\n\n## Notes\n\n"
            "状态栏胶囊里是进度条和数字：每输入一百个字符数字加一，进度条显示距离下一格还有多远。\n"
        })
        self.assertTrue(any("README.md: line 7:" in error and "must be English" in error for error in errors))

    def test_rejects_ascii_foreign_paragraph_across_wrapped_lines(self) -> None:
        errors = self.validate_language({
            "tools/README.md": "# Tools\n\nCe plugin permet de surveiller les mises a jour\n"
            "et de configurer les notifications pour tous les utilisateurs.\n"
            "Vous pouvez choisir les options dans le panneau de configuration.\n"
        })
        self.assertTrue(any("tools/README.md: line 3:" in error and "must be English" in error for error in errors))

    def test_rejects_foreign_prose_when_portuguese_and_spanish_are_ambiguous(self) -> None:
        errors = self.validate_language({
            "README.md": "Este plugin permite controlar os dispositivos e consultar o estado da bateria. "
            "Pode configurar todas as notificacoes no painel de configuracao do sistema."
        })
        self.assertTrue(any("README prose must be English" in error for error in errors))

    def test_rejects_localized_readme_copies(self) -> None:
        for name in ("README.ru.md", "README-ja.md", "docs/readme.zh-Hans.md", "README_pt-BR.txt"):
            with self.subTest(name=name):
                errors = self.validate_language({name: "# Example\n"})
                self.assertTrue(any("localized README copies" in error for error in errors))

    def test_preserves_names_code_examples_urls_and_translations(self) -> None:
        errors = self.validate_language({
            "README.md": "# Rosé Pine\n\n"
            "Ayet Köşesi displays the daily verse from Akıl Kuran's public API on the desktop.\n\n"
            "This keyboard example converts `привет` without changing the surrounding documentation.\n\n"
            "https://example.com/这是一个用于说明网址路径的中文字符串\n\n"
            "```text\n这是示例数据，不是插件文档。这些内容应该保持不变，并且不能作为非英语说明文字拒绝。\n```\n\n"
            "~~~text\nЭто пример данных, который не является документацией плагина и не должен проверяться.\n~~~\n\n"
            "    Это пример данных, который не является документацией плагина и не должен проверяться.\n",
            "translations/zh-Hans.json": '{"description": "这是中文翻译"}',
        })
        self.assertEqual(errors, [])


class PluginConfigAccessorTests(unittest.TestCase):
    def test_accepts_universal_accessor(self) -> None:
        self.assertEqual(
            validate_plugins.obsolete_config_accessors('local value = noctalia.getConfig("key")'),
            [],
        )

    def test_rejects_every_entry_specific_alias(self) -> None:
        source = "\n".join(
            [
                'barWidget.getConfig("one")',
                'desktopWidget.getConfig("two")',
                'panel . getConfig("three")',
                'launcher.getConfig("four")',
            ]
        )
        self.assertEqual(
            validate_plugins.obsolete_config_accessors(source),
            [
                ("barWidget.getConfig", 1),
                ("desktopWidget.getConfig", 2),
                ("panel.getConfig", 3),
                ("launcher.getConfig", 4),
            ],
        )

    def test_ignores_comments_and_strings(self) -> None:
        source = "\n".join(
            [
                '-- barWidget.getConfig("comment")',
                '--[[ panel.getConfig("block comment") ]]',
                'local text = "launcher.getConfig(\\\"string\\\")"',
                'local block = [[desktopWidget.getConfig("long string")]]',
            ]
        )
        self.assertEqual(validate_plugins.obsolete_config_accessors(source), [])


class ColorRoleTests(unittest.TestCase):
    def problems(self, source: str, plugin_api: object = 43) -> list[str]:
        return validate_plugins.color_role_problems(source, plugin_api)

    def test_rejects_retired_roles_in_color_props(self) -> None:
        source = "\n".join(
            [
                'ui.row({ fill = "surface_variant" })',
                'ui.row({ fill = excluded and "surface_variant/0.5" or "surface" })',
                'ui.row({ border = "outline", borderWidth = 1 })',
                "ui.label({ color = if dim then 'outline' else 'on_surface' })",
            ]
        )
        self.assertEqual(
            self.problems(source),
            [
                "color role 'surface_variant' on line 1 was retired; use 'surface_container'",
                "color role 'surface_variant' on line 2 was retired; use 'surface_container'",
                "color role 'outline' on line 3 was retired; use 'outline_variant'",
                "color role 'outline' on line 4 was retired; use 'outline_variant'",
            ],
        )

    def test_rejects_surface_variant_outside_color_props(self) -> None:
        self.assertEqual(
            self.problems('local bg = "surface_variant"'),
            ["color role 'surface_variant' on line 1 was retired; use 'surface_container'"],
        )

    def test_accepts_outline_button_variant(self) -> None:
        source = "\n".join(
            [
                'ui.button({ variant = "outline", fill = "primary" })',
                'ui.button({ fill = "primary", variant = active and "primary" or "outline" })',
                'ui.button({ variant = pick(fill == x, "outline") })',
            ]
        )
        self.assertEqual(self.problems(source), [])

    def test_accepts_current_roles_and_ignores_comments(self) -> None:
        source = "\n".join(
            [
                'ui.label({ color = "on_surface_variant" })',
                '-- fill = "surface_variant"',
                '--[[ border = "outline" ]]',
                'local doc = [[fill = "surface_variant"]]',
            ]
        )
        self.assertEqual(self.problems(source), [])

    def test_container_roles_require_api_43(self) -> None:
        source = 'ui.row({ fill = "surface_container", border = "outline_variant/0.4" })'
        self.assertEqual(self.problems(source, 43), [])
        self.assertEqual(
            self.problems(source, 42),
            [
                "color role 'surface_container' on line 1 requires plugin_api >= 43",
                "color role 'outline_variant' on line 1 requires plugin_api >= 43",
            ],
        )


class TranslationKeyTests(ProfileTestCase):
    def test_accepts_valid_keys(self) -> None:
        for key in (
            "settings.translation_language.label",
            "settings.translation_language.options.zh-hans",
            "settings.translation_language.options.en",
            "a.b-c.d_e.f0",
        ):
            with self.subTest(key=key):
                self.assertTrue(validate_plugins.is_valid_translation_key(key))

    def test_rejects_invalid_keys(self) -> None:
        for key in (
            "settings.options.zh-Hans",  # uppercase segment
            "settings.options.zh-Hant",
            "settings.Label",
            "settings._leading",  # leading underscore in a segment
            "settings..options",  # empty segment
            "",
        ):
            with self.subTest(key=key):
                self.assertFalse(validate_plugins.is_valid_translation_key(key))

    def test_rejects_dotted_json_object_keys(self) -> None:
        # A flat dotted key is what the i18n platform expands into nested objects; the JSON
        # source must nest instead, so an object key with a dot is invalid.
        self.assertFalse(validate_plugins.is_valid_key_segment("settings.label"))
        self.assertTrue(validate_plugins.is_valid_key_segment("eyecare-active-duration"))
        translations = {"settings.eyecare-active-duration.label": "Active Duration"}
        self.assertEqual(
            validate_plugins.invalid_translation_keys(translations),
            ["settings.eyecare-active-duration.label"],
        )

    def test_walks_nested_keys_and_reports_full_paths(self) -> None:
        translations = {
            "settings": {
                "translation_language": {
                    "options": {"zh-Hans": "Simplified", "zh-Hant": "Traditional", "en": "English"}
                }
            }
        }
        self.assertEqual(
            validate_plugins.invalid_translation_keys(translations),
            [
                "settings.translation_language.options.zh-Hans",
                "settings.translation_language.options.zh-Hant",
            ],
        )

    def validate_keys(self, translations: object) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            plugin_dir = Path(directory) / "example"
            plugin_dir.mkdir()
            validator = validate_plugins.Validator(Path(directory), profile=self.profile)
            validator.validate_translation_keys(plugin_dir, translations)
            return validator.errors

    def test_reports_bad_json_keys_without_a_reference(self) -> None:
        errors = self.validate_keys({"settings": {"options": {"zh-Hans": "Simplified"}}})
        self.assertEqual(len(errors), 1)
        self.assertIn("settings.options.zh-Hans", errors[0])
        self.assertIn("invalid translation key format", errors[0])

    def test_accepts_valid_json_keys(self) -> None:
        self.assertEqual(self.validate_keys({"settings": {"options": {"zh-hans": "Simplified"}}}), [])

    def validate_reference(self, label_key: object) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_translation_key(
            Path("/repo/example/plugin.toml"),
            {label_key: "x"} if isinstance(label_key, str) else {},
            "setting[0]",
            "label_key",
            label_key,
        )
        return validator.errors

    def test_rejects_badly_formatted_reference(self) -> None:
        errors = self.validate_reference("settings.options.zh-Hans")
        self.assertEqual(len(errors), 1)
        self.assertIn("is not a valid translation key", errors[0])

    def test_accepts_well_formatted_existing_reference(self) -> None:
        self.assertEqual(self.validate_reference("settings.options.zh-hans"), [])


class ReadmeTests(ProfileTestCase):
    MANIFEST = {
        "id": "me/example",
        "dependencies": ["example-cli"],
        "setting": [{"key": "interval"}],
        "widget": [{"id": "widget", "entry": "widget.luau"}],
        "panel": [{"id": "panel", "entry": "panel.luau"}],
        "launcher_provider": [
            {"id": "search", "entry": "launcher.luau", "prefix": "ex"}
        ],
    }

    VALID_README = """# Example

Example provides a useful widget, panel, and launcher for demonstration purposes.

## Plugin

| Field | Value |
| --- | --- |
| ID | `me/example` |
| Entries | Widget: `widget`; panel: `panel`; launcher: `search` |
| Launcher Prefix | `/ex` |

## Requirements

Install `example-cli` on `PATH`.

## Usage

Add the widget, type `/ex`, or open the panel:

```sh
noctalia msg panel-toggle me/example:panel
```

## Settings

Configure the update interval in plugin settings.
"""

    def validate_readme(self, contents: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            (plugin_dir / "README.md").write_text(contents, encoding="utf-8")
            validator = validate_plugins.Validator(root, profile=self.profile)
            validator.validate_readme(plugin_dir, self.MANIFEST)
            return validator.errors

    def test_accepts_official_plugin_readme_structure(self) -> None:
        self.assertEqual(self.validate_readme(self.VALID_README), [])

    def test_requires_core_sections_and_intro(self) -> None:
        errors = self.validate_readme("# Example\n\nToo short.\n")
        self.assertTrue(any("short introduction" in error for error in errors))
        self.assertTrue(any("## Plugin" in error for error in errors))
        self.assertTrue(any("## Usage" in error for error in errors))

    def test_headings_inside_code_fences_do_not_satisfy_sections(self) -> None:
        errors = self.validate_readme(
            "# Example\n\nA sufficiently descriptive introduction for this example plugin.\n\n"
            "```md\n## Plugin\n## Usage\n```\n"
        )
        self.assertTrue(any("## Plugin" in error for error in errors))
        self.assertTrue(any("## Usage" in error for error in errors))

    def test_derives_documented_values_from_manifest(self) -> None:
        readme = self.VALID_README
        replacements = {
            "`me/example`": "`me/wrong`",
            "`widget`": "`other-widget`",
            "noctalia msg panel-toggle me/example:panel": "noctalia msg panel-toggle me/example:wrong",
            "`/ex`": "`/wrong`",
            "`example-cli`": "`other-cli`",
        }
        for old, new in replacements.items():
            with self.subTest(missing=old):
                errors = self.validate_readme(readme.replace(old, new))
                self.assertTrue(errors)

    def test_requires_conditional_sections(self) -> None:
        without_requirements = self.VALID_README.replace(
            "## Requirements\n\nInstall `example-cli` on `PATH`.\n\n", ""
        )
        without_settings = self.VALID_README.replace(
            "## Settings\n\nConfigure the update interval in plugin settings.\n", ""
        )
        self.assertTrue(
            any("## Requirements" in error for error in self.validate_readme(without_requirements))
        )
        self.assertTrue(any("## Settings" in error for error in self.validate_readme(without_settings)))


class SettingTypeTests(ProfileTestCase):
    TRANSLATIONS = {"settings": {"value": {"label": "Value"}}}

    def validate_setting(self, setting: dict, plugin_api: object = 6) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_settings(
            Path("/repo/example/plugin.toml"),
            self.TRANSLATIONS,
            [{"key": "value", "label_key": "settings.value.label", **setting}],
            "setting",
            plugin_api,
        )
        return validator.errors

    def test_accepts_each_supported_setting_type(self) -> None:
        for setting_type, default in {
            "string": "",
            "string_list": ["one", "two"],
            "string_map": {"output": "monitor"},
            "bool": False,
            "int": 1,
            "double": 0.5,
            "file": "",
            "folder": "",
            "glyph": "widgets",
            "color": "#ffffff",
            "select": "one",
        }.items():
            with self.subTest(setting_type=setting_type):
                setting = {"type": setting_type, "default": default}
                if setting_type == "select":
                    setting["options"] = [{"value": "one", "label_key": "settings.value.label"}]
                self.assertEqual(self.validate_setting(setting), [])

    def test_rejects_unsupported_setting_type(self) -> None:
        errors = self.validate_setting({"type": "number", "default": 1})
        self.assertTrue(any("unsupported setting type 'number'" in error for error in errors))

    def test_accepts_double_with_numeric_bounds(self) -> None:
        self.assertEqual(
            self.validate_setting(
                {"type": "double", "default": 0.5, "min": 0.0, "max": 1.0, "step": 0.05}
            ),
            [],
        )

    def test_rejects_invalid_double_default(self) -> None:
        errors = self.validate_setting({"type": "double", "default": "fast"})
        self.assertTrue(any("default must be a finite number" in error for error in errors))

    def test_rejects_invalid_double_range(self) -> None:
        errors = self.validate_setting(
            {"type": "double", "default": 0.5, "min": 1.0, "max": 0.0}
        )
        self.assertTrue(any("min must be less than or equal to max" in error for error in errors))

    def test_accepts_string_map(self) -> None:
        self.assertEqual(
            self.validate_setting(
                {"type": "string_map", "default": {"eDP-1": "laptop", "DP-1": "monitor"}}
            ),
            [],
        )

    def test_rejects_non_string_map_value(self) -> None:
        errors = self.validate_setting({"type": "string_map", "default": {"eDP-1": 1}})
        self.assertTrue(any("default.eDP-1 must be a string" in error for error in errors))

    def test_string_map_requires_plugin_api_6(self) -> None:
        errors = self.validate_setting({"type": "string_map", "default": {}}, plugin_api=5)
        self.assertTrue(any("string_map requires plugin_api >= 6" in error for error in errors))

    def test_accepts_secret_string(self) -> None:
        self.assertEqual(self.validate_setting({"type": "string", "default": "", "secret": True}, plugin_api=47), [])

    def test_secret_requires_plugin_api_47(self) -> None:
        errors = self.validate_setting({"type": "string", "secret": True}, plugin_api=46)
        self.assertTrue(any("secret requires plugin_api >= 47" in error for error in errors))

    def test_rejects_secret_on_non_string_type(self) -> None:
        errors = self.validate_setting({"type": "int", "default": 1, "secret": True}, plugin_api=47)
        self.assertTrue(any("secret is only valid for" in error for error in errors))


class WidgetActionsTests(ProfileTestCase):
    def validate_actions(self, entry: dict, plugin_api: object = 14) -> list[str]:
        validator = validate_plugins.Validator(Path("/repo"), profile=self.profile)
        validator.validate_widget_fields(
            Path("/repo/example/plugin.toml"),
            "widget[0]",
            entry,
            plugin_api,
        )
        return validator.errors

    def test_accepts_every_gesture(self) -> None:
        actions = {gesture: "volume-mute" for gesture in validate_plugins.WIDGET_GESTURES}
        self.assertEqual(self.validate_actions({"actions": actions}), [])

    def test_accepts_exec_and_none(self) -> None:
        self.assertEqual(
            self.validate_actions({"actions": {"middle": "exec playerctl pause", "right": "none"}}),
            [],
        )

    def test_entry_without_actions_is_fine(self) -> None:
        self.assertEqual(self.validate_actions({"id": "bar"}), [])

    def test_rejects_unknown_gesture(self) -> None:
        self.assertNotEqual(self.validate_actions({"actions": {"ctrl+left": "volume-mute"}}), [])

    def test_rejects_non_table(self) -> None:
        self.assertNotEqual(self.validate_actions({"actions": "volume-mute"}), [])

    def test_rejects_non_string_action(self) -> None:
        self.assertNotEqual(self.validate_actions({"actions": {"middle": 42}}), [])

    def test_rejects_empty_action(self) -> None:
        self.assertNotEqual(self.validate_actions({"actions": {"middle": ""}}), [])

    def test_rejects_bare_exec(self) -> None:
        self.assertNotEqual(self.validate_actions({"actions": {"middle": "exec"}}), [])

    def test_requires_plugin_api_14(self) -> None:
        errors = self.validate_actions({"actions": {"middle": "volume-mute"}}, plugin_api=13)
        self.assertTrue(any("plugin_api >= 14" in error for error in errors))



class PanelLayerTests(ProfileTestCase):
    def validate_layer(self, entry: dict, plugin_api: object = 30) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            (plugin_dir / "panel.luau").write_text("", encoding="utf-8")
            validator = validate_plugins.Validator(root, profile=self.profile)
            validator.validate_entries(
                plugin_dir / "plugin.toml",
                {
                    "plugin_api": plugin_api,
                    "panel": [{"id": "panel", "entry": "panel.luau", **entry}],
                },
                {},
            )
            return validator.errors

    def test_accepts_supported_layers_from_api_30(self) -> None:
        for api in (30, 31):
            for layer in ("top", "overlay"):
                with self.subTest(api=api, layer=layer):
                    self.assertEqual(self.validate_layer({"layer": layer}, api), [])

    def test_rejects_layer_below_api_30_or_invalid_api(self) -> None:
        for api in (29, None, "30", True):
            with self.subTest(api=api):
                errors = self.validate_layer({"layer": "overlay"}, api)
                self.assertTrue(any("requires plugin_api >= 30" in error for error in errors))

    def test_accepts_follow_from_api_49(self) -> None:
        self.assertEqual(self.validate_layer({"layer": "follow"}, 49), [])

    def test_rejects_follow_below_api_49(self) -> None:
        self.assertEqual(
            self.validate_layer({"layer": "follow"}, 48),
            ['example/plugin.toml: panel[0]: layer "follow" requires plugin_api >= 49'],
        )

    def test_rejects_invalid_layers_and_types(self) -> None:
        for layer in ("background", "bottom", "Overlay", "", 1, True, [], {}):
            with self.subTest(layer=layer):
                errors = self.validate_layer({"layer": layer})
                self.assertTrue(any("layer must be one of:" in error for error in errors))

    def test_layer_remains_optional_on_older_api(self) -> None:
        self.assertEqual(self.validate_layer({}, 29), [])


class PanelContentHeightTests(ProfileTestCase):
    def validate_panel(self, entry: dict, plugin_api: object = 42) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            (plugin_dir / "panel.luau").write_text("", encoding="utf-8")
            validator = validate_plugins.Validator(root, profile=self.profile)
            validator.validate_entries(
                plugin_dir / "plugin.toml",
                {"plugin_api": plugin_api, "panel": [{"id": "panel", "entry": "panel.luau", **entry}]},
                {},
            )
            return validator.errors

    def test_accepts_content_height_from_api_42(self) -> None:
        for api in (42, 43):
            for placement in ("floating", "attached"):
                with self.subTest(api=api, placement=placement):
                    self.assertEqual(self.validate_panel(
                        {"height": "content", "max_height": 560, "placement": placement}, api), [])

    def test_rejects_content_height_below_api_42(self) -> None:
        for api in (41, None, "42", True):
            with self.subTest(api=api):
                errors = self.validate_panel({"height": "content", "max_height": 560}, api)
                self.assertTrue(any("requires plugin_api >= 42" in error for error in errors))

    def test_requires_max_height_for_content(self) -> None:
        errors = self.validate_panel({"height": "content"})
        self.assertTrue(any("requires max_height" in error for error in errors))

    def test_rejects_invalid_max_height(self) -> None:
        for value in (0, -1, True, "560", [], {}, float("inf"), float("nan")):
            with self.subTest(value=value):
                errors = self.validate_panel({"height": "content", "max_height": value})
                self.assertTrue(any("max_height must be a positive number" in error for error in errors))

    def test_rejects_max_height_without_content_height(self) -> None:
        for height in (None, 300, "fill"):
            with self.subTest(height=height):
                entry = {"max_height": 560}
                if height is not None:
                    entry["height"] = height
                errors = self.validate_panel(entry)
                self.assertTrue(any('max_height requires height = "content"' in error for error in errors))

    def test_rejects_content_width(self) -> None:
        errors = self.validate_panel({"width": "content"})
        self.assertTrue(any('width must be a positive number or "fill"' in error for error in errors))

    def test_rejects_persistent_content_height(self) -> None:
        errors = self.validate_panel({"height": "content", "max_height": 560, "persistent": True})
        self.assertTrue(any('not supported with persistent = true' in error for error in errors))

    def test_preserves_numeric_and_fill_extents(self) -> None:
        for extent in (300, 300.5, "fill"):
            with self.subTest(extent=extent):
                self.assertEqual(self.validate_panel({"width": extent, "height": extent}, 13), [])
        errors = self.validate_panel({"width": "fill", "height": "content", "max_height": 560,
                                      "placement": "attached"})
        self.assertTrue(any('"fill" requires placement = "floating"' in error for error in errors))


class PluginFileCountTests(unittest.TestCase):
    def validate_file_count(self, files: dict[str, int], directories: int = 0) -> list[str]:
        """`files` maps a directory inside the plugin ("" for its root) to how many it holds."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin_dir = root / "example"
            plugin_dir.mkdir()
            for relative, count in files.items():
                target = plugin_dir / relative
                target.mkdir(parents=True, exist_ok=True)
                for index in range(count):
                    (target / f"asset-{index}.svg").write_text("<svg/>", encoding="utf-8")
            for index in range(directories):
                (plugin_dir / f"empty-{index}").mkdir()
            validator = validate_plugins.Validator(root)
            validator.validate_file_count(plugin_dir / "plugin.toml", plugin_dir)
            return validator.errors

    def test_accepts_plugin_at_file_limit(self) -> None:
        limit = validate_plugins.MAX_PLUGIN_FILES
        self.assertEqual(self.validate_file_count({"": limit // 2, "orbs": limit - limit // 2}), [])

    def test_rejects_plugin_above_file_limit(self) -> None:
        limit = validate_plugins.MAX_PLUGIN_FILES
        self.assertEqual(
            self.validate_file_count({"orbs": limit + 1}),
            [
                f"example/plugin.toml: plugin directory ships {limit + 1} files; the limit is {limit} "
                "(every clone, CI run, and install checks out every file - ship generated asset "
                "packs as one archive or generate them into the user's cache directory on first run)"
            ],
        )

    def test_does_not_count_directories(self) -> None:
        self.assertEqual(
            self.validate_file_count({}, directories=validate_plugins.MAX_PLUGIN_FILES + 5),
            [],
        )


class GitObjectTests(unittest.TestCase):
    """Plugins must be plain files committed in this repository, never submodule pointers."""

    def setUp(self) -> None:
        if shutil.which("git") is None:
            self.skipTest("git is required")

    def run_git(self, root: Path, *args: str) -> None:
        subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            capture_output=True,
            text=True,
        )

    def git_root(self) -> Path:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.run_git(root, "init", "-q")
        self.run_git(root, "config", "user.email", "tests@example.com")
        self.run_git(root, "config", "user.name", "tests")
        return root

    def validate_git_objects(self, root: Path) -> list[str]:
        validator = validate_plugins.Validator(root)
        validator.validate_git_objects()
        return validator.errors

    def test_rejects_gitlink(self) -> None:
        root = self.git_root()
        self.run_git(
            root,
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            "222326f5650aa395cfc2c7b25fb528209ff9bc7d",
            "saved-desktop-widgets",
        )
        self.assertEqual(
            self.validate_git_objects(root),
            [
                "saved-desktop-widgets: is a git submodule (mode 160000); plugins ship plain files "
                "committed in this repository, so commit the plugin's files instead of a submodule"
            ],
        )

    def test_rejects_committed_gitmodules(self) -> None:
        root = self.git_root()
        (root / ".gitmodules").write_text(
            '[submodule "saved-desktop-widgets"]\n\tpath = saved-desktop-widgets\n\turl = https://example.com/x.git\n',
            encoding="utf-8",
        )
        self.run_git(root, "add", ".gitmodules")
        self.assertEqual(
            self.validate_git_objects(root),
            [
                ".gitmodules: declares git submodules; plugins ship plain files committed in this "
                "repository"
            ],
        )

    def test_rejects_nested_gitmodules(self) -> None:
        root = self.git_root()
        plugin_dir = root / "example"
        plugin_dir.mkdir()
        (plugin_dir / ".gitmodules").write_text(
            '[submodule "helper"]\n\tpath = helper\n\turl = https://example.com/x.git\n',
            encoding="utf-8",
        )
        self.run_git(root, "add", "example/.gitmodules")
        self.assertEqual(
            self.validate_git_objects(root),
            [
                "example/.gitmodules: declares git submodules; plugins ship plain files committed "
                "in this repository"
            ],
        )

    def test_accepts_committed_plugin_files(self) -> None:
        root = self.git_root()
        plugin_dir = root / "example"
        plugin_dir.mkdir()
        (plugin_dir / "plugin.toml").write_text('id = "author/example"\n', encoding="utf-8")
        (plugin_dir / "README.md").write_text("# Example\n", encoding="utf-8")
        self.run_git(root, "add", "--all")
        self.assertEqual(self.validate_git_objects(root), [])

    def test_skips_directory_outside_a_repository(self) -> None:
        # A detached temporary directory (no work tree, no git binary reachable from it) must stay
        # silent instead of failing a manifest run.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "example").mkdir()
            self.assertEqual(self.validate_git_objects(root), [])

    def test_validate_fails_on_gitlink(self) -> None:
        root = self.git_root()
        self.run_git(
            root,
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            "222326f5650aa395cfc2c7b25fb528209ff9bc7d",
            "saved-desktop-widgets",
        )
        with contextlib.redirect_stderr(io.StringIO()):
            exit_code = validate_plugins.Validator(root).validate()
        self.assertEqual(exit_code, 1)


class LayerEntryTests(ProfileTestCase):
    def validate_layer(self, entry: dict, plugin_api: object = 36) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = root / "example"
            plugin.mkdir()
            (plugin / "layer.luau").write_text("", encoding="utf-8")
            validator = validate_plugins.Validator(root, profile=self.profile)
            validator.validate_entries(
                plugin / "plugin.toml",
                {
                    "plugin_api": plugin_api,
                    "layer": [{"id": "background", "entry": "layer.luau", **entry}],
                },
                {},
            )
            return validator.errors

    def test_accepts_defaults_and_all_layer_fields(self) -> None:
        self.assertEqual(self.validate_layer({}), [])
        for layer in ("background", "bottom", "top", "overlay"):
            for keyboard in ("none", "on_demand", "exclusive"):
                with self.subTest(layer=layer, keyboard=keyboard):
                    self.assertEqual(self.validate_layer({
                        "layer": layer,
                        "keyboard": keyboard,
                        "anchors": ["top", "right", "bottom", "left"],
                        "width": 0,
                        "height": 65536,
                        "margins": {"top": -1.5, "right": 0, "bottom": 2, "left": 3},
                        "exclusive_zone": "auto",
                        "click_through": True,
                        "output": "eDP-1",
                    }), [])

    def test_requires_api_36(self) -> None:
        for api in (35, None, "36", True):
            with self.subTest(api=api):
                errors = self.validate_layer({}, api)
                self.assertTrue(any("layer requires plugin_api >= 36" in error for error in errors))

    def test_rejects_invalid_enums_and_types(self) -> None:
        for field, values in {
            "layer": ("follow", "Overlay", "", 1, True, [], {}),
            "keyboard": ("on-demand", "", 1, True, [], {}),
            "anchors": ("top", [1], [""], ["center"], ["top", "top"]),
            "margins": (1, [], {"center": 0}, {"top": True}, {"left": float("nan")}),
            "click_through": (0, "true", [], {}),
            "output": ("", " ", 1, False, [], {}),
            "exclusive_zone": (-2, 1.5, True, "AUTO", [], {}),
        }.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    self.assertTrue(self.validate_layer({field: value}))

    def test_rejects_invalid_dimensions(self) -> None:
        for field in ("width", "height"):
            for value in (-1, 65537, True, "fill", [], {}, float("inf"), float("nan")):
                with self.subTest(field=field, value=value):
                    errors = self.validate_layer({field: value})
                    self.assertTrue(any(f"{field} must be a number from 0 to 65536" in error for error in errors))

    def test_accepts_empty_anchors_and_integer_exclusive_zones(self) -> None:
        for zone in (-1, 0, 100):
            with self.subTest(zone=zone):
                self.assertEqual(self.validate_layer({"anchors": [], "exclusive_zone": zone}), [])

    def test_rejects_unknown_fields_and_missing_entry_files(self) -> None:
        self.assertTrue(any("unknown field 'setting'" in error for error in self.validate_layer({"setting": []})))
        self.assertTrue(any("does not exist" in error for error in self.validate_layer({"entry": "missing.luau"})))


class RepositoryBehaviorTests(ProfileTestCase):
    MANIFEST = """id = "me/example"
name = "Example"
version = "1.0.0"
author = "me"
license = "MIT"
icon = "widgets"
description = "Monitor battery status from the desktop."
dependencies = []
tags = ["utility"]
plugin_api = 49

[[widget]]
id = "widget"
entry = "widget.luau"
actions = { middle = "exec playerctl pause" }
"""
    README = """# Example

Example provides a useful widget for monitoring battery status on the desktop.

## Plugin

Plugin ID: `me/example`. Widget entry: `widget`.

## Usage

Add the widget to your bar.
"""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.plugin = self.root / "example"
        self.plugin.mkdir()
        (self.plugin / "translations").mkdir()
        (self.plugin / "translations/en.json").write_text("{}", encoding="utf-8")
        (self.plugin / "plugin.toml").write_text(self.MANIFEST, encoding="utf-8")
        (self.plugin / "README.md").write_text(self.README, encoding="utf-8")
        (self.plugin / "widget.luau").write_text("", encoding="utf-8")
        # A VP8X header with the exact required dimensions; no image decoder is needed.
        width, height = validate_plugins.THUMBNAIL_SIZE
        header = b"RIFF" + (22).to_bytes(4, "little") + b"WEBPVP8X"
        header += (10).to_bytes(4, "little") + bytes(4)
        header += (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
        (self.plugin / "thumbnail.webp").write_bytes(header)

    def validate(self) -> tuple[int, list[str]]:
        validator = validate_plugins.Validator(self.root, profile=self.profile)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = validator.validate()
        return status, validator.errors

    def assert_rejected(self, message: str) -> None:
        status, errors = self.validate()
        self.assertEqual(status, 1)
        self.assertTrue(any(message in error for error in errors), errors)

    def test_accepts_complete_plugin(self) -> None:
        self.assertEqual(self.validate(), (0, []))

    def test_cli_defaults_to_callers_current_directory(self) -> None:
        result = subprocess.run(
            [sys.executable, str(VALIDATOR_PATH), "--profile", self.profile],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated 1 plugin manifest(s).", result.stdout)

    def test_common_manifest_schema_is_enforced(self) -> None:
        (self.plugin / "plugin.toml").write_text(self.MANIFEST + '\nunknown = true\n', encoding="utf-8")
        self.assert_rejected("unknown field 'unknown'")

    def test_readme_structure_is_required_for_both_profiles(self) -> None:
        (self.plugin / "README.md").write_text("# Example\n", encoding="utf-8")
        self.assert_rejected("missing required '## Usage' section")

    def test_language_checks_are_community_only(self) -> None:
        description = "Ce plugin permet de surveiller les mises a jour et de configurer les notifications."
        manifest = self.MANIFEST.replace("Monitor battery status from the desktop.", description)
        (self.plugin / "plugin.toml").write_text(manifest, encoding="utf-8")
        prose = (
            "Este plugin permite controlar os dispositivos e consultar o estado da bateria. "
            "Pode configurar todas as notificacoes no painel de configuracao do sistema."
        )
        (self.plugin / "README.md").write_text(self.README + "\n" + prose, encoding="utf-8")
        (self.plugin / "README.fr.md").write_text("# Exemple\n", encoding="utf-8")
        if self.profile == "community":
            status, errors = self.validate()
            self.assertEqual(status, 1)
            for message in ("description' must be English", "README prose must be English", "localized README copies"):
                self.assertTrue(any(message in error for error in errors), errors)
        else:
            self.assertEqual(self.validate(), (0, []))

    def test_file_limit_is_community_only(self) -> None:
        assets = self.plugin / "assets"
        assets.mkdir()
        for index in range(validate_plugins.MAX_PLUGIN_FILES):
            (assets / f"{index}.txt").write_text("", encoding="utf-8")
        if self.profile == "community":
            self.assert_rejected("the limit is 200")
        else:
            self.assertEqual(self.validate(), (0, []))

    def test_git_object_checks_are_community_only(self) -> None:
        if shutil.which("git") is None:
            self.skipTest("git is required")
        (self.plugin / ".gitmodules").write_text("", encoding="utf-8")
        for args in (
            ("init", "-q"),
            ("add", "--all"),
            ("update-index", "--add", "--cacheinfo", "160000",
             "222326f5650aa395cfc2c7b25fb528209ff9bc7d", "external"),
        ):
            subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=True)
        if self.profile == "community":
            status, errors = self.validate()
            self.assertEqual(status, 1)
            self.assertTrue(any("is a git submodule" in error for error in errors), errors)
            self.assertTrue(any("declares git submodules" in error for error in errors), errors)
        else:
            self.assertEqual(self.validate(), (0, []))

    def test_translation_rules_are_shared(self) -> None:
        (self.plugin / "translations/en.json").write_text('{"Bad": "Example"}', encoding="utf-8")
        self.assert_rejected("invalid translation key format")

    def test_luau_api_rules_are_shared(self) -> None:
        (self.plugin / "widget.luau").write_text('barWidget.getConfig("value")', encoding="utf-8")
        self.assert_rejected("was removed; use noctalia.getConfig")

    def test_symlink_rule_is_shared(self) -> None:
        (self.plugin / "linked.luau").symlink_to("widget.luau")
        self.assert_rejected("is a symlink")

    def test_thumbnail_rule_is_shared(self) -> None:
        (self.plugin / "thumbnail.webp").write_bytes(b"not WebP")
        self.assert_rejected("is not a WebP image")

    def test_layer_manifest_is_accepted_and_documented(self) -> None:
        manifest = self.MANIFEST.split("[[widget]]", 1)[0] + """
[[layer]]
id = "background"
entry = "widget.luau"
layer = "background"
anchors = ["top", "bottom", "left", "right"]
"""
        (self.plugin / "plugin.toml").write_text(manifest, encoding="utf-8")
        (self.plugin / "README.md").write_text(self.README.replace("`widget`", "`background`"), encoding="utf-8")
        self.assertEqual(self.validate(), (0, []))
        (self.plugin / "README.md").write_text(self.README, encoding="utf-8")
        self.assert_rejected("must document layer entry 'background'")



class CommandLineTests(unittest.TestCase):
    def test_requires_a_known_explicit_profile(self) -> None:
        for arguments in ([], ["--profile", "unknown"]):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    validate_plugins.parse_args(arguments)
                self.assertEqual(raised.exception.code, 2)


    def test_direct_api_rejects_unknown_profile(self) -> None:
        with self.assertRaises(ValueError):
            validate_plugins.Validator(Path("/repo"), profile="unknown")

    def test_missing_or_non_directory_root_fails_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "file").write_text("", encoding="utf-8")
            for profile in validate_plugins.PROFILES:
                for path in (root / "missing", root / "file"):
                    with self.subTest(profile=profile, root=path):
                        stderr = io.StringIO()
                        with contextlib.redirect_stderr(stderr):
                            result = validate_plugins.main(["--profile", profile, "--root", str(path)])
                        self.assertEqual(result, 1)
                        self.assertIn("repository root must be an existing directory", stderr.getvalue())



def load_tests(
    loader: unittest.TestLoader, tests: unittest.TestSuite, pattern: str | None
) -> unittest.TestSuite:
    # Discovery already supplies the community cases; reuse the same cases for official.
    for case in ProfileTestCase.__subclasses__():
        for test in loader.loadTestsFromTestCase(case):
            test.profile = "official"
            tests.addTest(test)
    return tests


if __name__ == "__main__":
    unittest.main()
