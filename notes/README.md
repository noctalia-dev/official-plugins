# Notes

Quick notes in a full-height side panel, stored as plain text files in a
directory you control - yours to sync, edit externally, and grep.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/notes` |
| Entries | Panel: `panel`; bar widget: `notes`; launcher provider: `launcher` |
| Launcher Prefix | `/nt` |

## Usage

1. Enable the plugin in Settings → Plugins.
2. Add the `notes` bar widget and click it, or run:

   ```sh
   noctalia msg panel-toggle noctalia/notes:panel
   ```

3. **+** creates a note named after the current time; rename it from the editor
   header (press Enter to apply). The editor autosaves a couple of seconds
   after you stop typing, when you navigate away, and when the panel closes;
   Ctrl+Enter saves immediately.
4. The pin button on a row keeps that note at the top of the list and ranks it
   higher in launcher results. Deleting asks for an inline confirmation.

A pinned **Scratchpad** note always sits at the top of the list - the place to
dump text instantly without naming anything.

The panel close button respects `shell.show_close_buttons`; if the setting is
missing, the button stays visible. Requires plugin API 26.

The `/nt` launcher command writes down a thought without opening the panel:
type it, press Enter, done.

- `/nt buy milk` → **Add to scratchpad** appends the line to the scratchpad
  file; **New note** creates a note from it and opens the panel on it.
- The text also fuzzy-matches existing note names; activating a match opens it
  in the panel.
- Bare `/nt` lists the scratchpad, your notes, and **New note from clipboard**.
- **Add to scratchpad** is safe even if the scratchpad was left open in the
  editor: the appended line shows up there instead of being lost.

## IPC

```sh
noctalia msg panel-toggle noctalia/notes:panel   # toggle the panel, keeping its last view
noctalia msg panel-open noctalia/notes:panel     # open it, keeping its last view
noctalia msg panel-close                         # close the open panel
```

`panel-open` and `panel-toggle` accept an optional context:

| Context | Result |
| --- | --- |
| `scratchpad` | Opens the scratchpad note. |
| `home` / `list` | Shows the note list. |
| `note:<name>` | Opens the note called `<name>` (with or without the file extension), an unknown name starts an empty note that is created on the first edit. |
| `<name>` | Opens the note called `<name>`, or shows the list when no note matches. |

```sh
noctalia msg panel-toggle noctalia/notes:panel scratchpad
noctalia msg panel-toggle noctalia/notes:panel home
noctalia msg panel-toggle noctalia/notes:panel "note:buy milk"
```

Toggling with the same context on an already open panel closes it, a different
context switches the open panel in place.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notes_dir` | `folder` | `$XDG_DOCUMENTS_DIR/Notes` | Where the note files live. `$XDG_DOCUMENTS_DIR` expands to your localized Documents folder, or `~/Documents` if none is set. If that folder has no `Notes` yet but `~/Documents/Notes` (the pre-1.1.0 default) exists, the old folder keeps being used. Created on first open if missing. |
| `extension` | `string` | `md` | Extension for note files (without the dot). Only files with this extension are listed. |
| `glyph` | `glyph` | `notes` | Bar widget icon. |

## Notes

- Pins are stored in a hidden `.pinned.json` sidecar inside the notes
  directory, so they sync with the notes.
- The panel remembers which note was open across close/reopen.
- Files are only written by autosave and the `/nt` actions; nothing else in
  the notes directory is touched.
