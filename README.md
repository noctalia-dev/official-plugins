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
runtime no-op - the Luau VM compiles them away - so this only affects your editor.

1. Install [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) (VS Code
   extension or standalone language server).
2. Point it at the definitions. This repo ships a `.vscode/settings.json` that
   already does so; for another editor add `noctalia.d.luau` to luau-lsp's
   `types.definitionFiles`.
3. `.luaurc` sets `languageMode` to `nonstrict`, matching the `--!nonstrict`
   directive every plugin file starts with - the right fit for these
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

## Manifest validation

The canonical validator, dependencies, and tests live in `.github/actions/validate-plugins`. Both this repository
and community-plugins use that composite action, selecting `official` and `community` profiles respectively.
The common manifest schema is shared; English description/README policy, file-count limits, and Git-object checks
are community-only. Both profiles support layer entries from plugin API 36 onward.

From this repository's root with Python 3.11 or newer installed, run:

```sh
python3 -m venv /tmp/noctalia-validator-venv
. /tmp/noctalia-validator-venv/bin/activate
python3 -m pip install -r .github/actions/validate-plugins/requirements.txt
python3 -m unittest discover -s .github/actions/validate-plugins -p 'test_validate_plugins.py'
python3 .github/actions/validate-plugins/validate-plugins.py --profile official --root "$PWD"
```

Run `deactivate` when finished. The CLI requires an explicit profile; `--root` defaults to the current working
directory, not the validator's checkout. The composite action defaults its root to the caller's GitHub workspace
and runs the shared suite covering both profiles before validation.

Official pull requests and main-branch pushes, including action changes, use the local action so validator changes
are tested before release. Land validator changes here first, then publish the tested commit before updating
community-plugins' exact action SHA. Its local setup reads the pin from that workflow. Community's weekly Dependabot
GitHub Actions updates propose pin updates for review; changes here do not silently alter community policy.
Cross-repository execution requires this repository to be accessible and the shared action/setup-python dependency
to be allowed by the caller's Actions policy.

See `example/plugin.toml` for supported entry types and manifest properties.
