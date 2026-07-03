# Translator

Translator adds a launcher provider that translates text through Google
Translate and copies the selected result to the clipboard.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/translator` |
| Entry | Launcher provider: `translate` |
| Launcher Prefix | `/tr` |

## Usage

Open the Noctalia launcher and type `/tr`, followed by an optional target
language and the text to translate.

```text
/tr es hello world
/tr french good morning
/tr hello world
```

When the first word is a known language name, alias, or two- to three-letter
language code, it is used as the target language. Otherwise the plugin uses the
configured `target_lang`. Press Enter on a translation result to copy it to the
clipboard.

## Requirements

The provider uses Google Translate's public `translate_a/single` endpoint, so it
requires network access to `translate.google.com`.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `target_lang` | `string` | `en` | Default target language code when the query does not include one. |

## Notes

Results are cached in memory for the current plugin session, and duplicate
in-flight requests are coalesced while typing.
