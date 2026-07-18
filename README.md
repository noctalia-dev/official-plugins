# Official Plugins

<p align="center">
  <img src="https://assets.noctalia.dev/noctalia-logo.svg?v=2" alt="Noctalia Logo" style="width: 192px" />
</p>

---

This repo is **ONLY** for Official Noctalia plugins maintained by the core Noctalia Team.  

We do not accept PRs for new third-party plugins in the official repo, those should go in https://github.com/noctalia-dev/community-plugins

## Editor setup

`noctalia.d.luau` declares the whole plugin API (`noctalia.*`, `barWidget.*`,
`shortcut.*`, `launcher.*`, `desktopWidget.*`, `panel.*`, `ui.*`, and the entry
callbacks) so you get autocomplete and typo diagnostics. Type annotations are a
runtime no-op — the Luau VM compiles them away — so this only affects your editor.

1. Install [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) (VS Code
   extension or standalone language server).
2. Point it at the definitions. This repo ships a `.vscode/settings.json` that
   already does so; for another editor add `noctalia.d.luau` to luau-lsp's
   `types.definitionFiles`.
3. `.luaurc` sets `languageMode` to `nonstrict`, matching the `--!nonstrict`
   directive every plugin file starts with — the right fit for these
   dynamically-typed scripts (full autocomplete and real type/typo diagnostics,
   without strict-mode noise about always-present optional values).

## Translations

Plugin source strings live in each plugin's `translations/en.json`. Contributors should edit only that English file;
other locales are maintained through [Noctalia Translate](https://i18n.noctalia.dev).

To test the latest translated locales in a working checkout, run:

```sh
./.tools/i18n-pull.sh
```

The command asks for confirmation and overwrites the locale files returned by the translation service. It does not
delete local locale files that are absent from the export. Review the resulting diff before committing anything.
