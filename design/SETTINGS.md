# Settings

Status: implemented 2026-10-29, with these decisions over the proposal below:

- Tabs are **General, Printers, Rules, API, About**. Files is folded into General (After Printing, History).
- Watched folders stay in **Rules**, at the top, with **New files: Ask / Print / Show preview** (`newFilesAction`, default Ask).
- MCP and HTTP stay in **API**. MCP comes first; *Let MCP change settings* is a pop-up **Off / For 45 Minutes / Always**
  (`apiMCPSettingsGrant`, migrated once from `apiMCPSettings` + `apiMCPSettingsAutoOff`). Snippets open from **Set Up…**,
  the endpoint browser from **API Reference…**. Port, token and status sit under **Advanced**.
- Printers: offsets under **Advanced**.
- Everything else is fixed ("Default printer and its settings"); its saved outcome is ignored and MCP can't change it.
- Per-rule *Play a sound* is gone; old files still load. Rule tags are unchanged (no Default / None / Custom yet).
- Menu *Open…* is now *Print File…*.

## 1. Principles

- **One place per setting.** The menu picks and acts. Settings holds defaults. Rules hold exceptions.
- **Rules state only what differs.** Every rule field starts at *Default* and shows what it inherits: `Default (4 × 6 in)`.
- **One word per idea.** "Default printer", never "Current printer". "Preview", never "Ask first" or "review".
- **Attended vs unattended.** Files you hand over count down. Files that arrive alone (folders, apps, MCP) ask. One app-wide default each.
- **Every page always prints.** No setting, rule or permission skips pages.
- **Advanced is collapsed.** Calibration, port and token.
- Sentence case labels, title case buttons, footnotes only to prevent mistakes.

## 2. Structure

### Menu (unchanged in shape, 9 items)

```
 ✓ MUNBYN ITPP941AP          4 × 6 in
   Canon TS9500 series       4 × 6 in
   Label Size              ▸
 ─────────────────────────────
   Print Clipboard
   Print File…            ⌘O
   Reprint Last Label     ⌘R
 ─────────────────────────────
   Settings…              ⌘,   (⌥: Logs…)
   Quit Peel Good Inc.    ⌘Q
```

Rename *Open…* to *Print File…*. Delete the unused `chooseFit` / `chooseInk` actions. Drop gestures are unchanged.

### Tabs: General · Printers · Rules · Automation

**General**

| Row | Control | Default | Footnote |
|---|---|---|---|
| Default printer | Pop-up, "Name · size" | System label printer | |
| Before printing | Pop-up: Print right away / Count down 1.5 s / 3 s / Show preview | 1.5 s | Hold a file over the icon to pick a printer. Hold ⌥ to preview. |
| Play sounds | Switch | On | |
| Open at login | Switch | Off | |
| *After Printing* | | | |
| Tag the file | Switch + name + color dots | On, "Printed", green | |
| Then | Pop-up: Leave it / Add suffix / Move to folder / Move to Trash, plus field when needed | Leave it | |
| *History* | | | |
| Keep printed labels | Pop-up: 1 week / 1 month / 1 year / Forever | 1 month | Used by Reprint Last Label. |
| Saved | Count, size, Show in Finder, Delete All… | | |

**Printers** (sidebar list, + / −, "Show Hidden")

| Row | Control | Default |
|---|---|---|
| Label size | Pop-up of supported sizes | 4 × 6 in |
| Scaling | Segmented: Fit / Fill | Fit |
| Ink (thermal only) | Segmented: Auto / Crisp / Photo, (?) opens Ink Modes | Auto |
| Threshold | Slider, hidden for Photo | 50% |
| *Advanced ▸* Horizontal / Vertical offset | Steppers, mm | 0.0 |
| Print Test Label | Button | |

**Rules**

- *Everything else* becomes a fixed last row with no *Edit…*: "Default printer and its settings."
- Editor: Printer, Label size, Scaling, Ink, Copies, all *Default (…)*. *When a file matches*: Default / Print / Show preview / Ask; Default follows *Before printing* or *Unattended files*. **Tag**: Default / None / Custom.

**Automation**

| Row | Control | Default | Footnote |
|---|---|---|---|
| *Watched Folders* | List + / − | Empty | New files in these folders go through your rules. |
| Unattended files | Pop-up: Ask with a notification / Print / Show preview | Ask | Applies to watched folders and other apps. |
| *MCP* | | | |
| MCP server | Switch | Off | |
| Let MCP print files from this Mac | Switch | Off | Off: MCP can print only files it sends. |
| Let MCP change settings | Switch | Off | |
| Set up | Copyable snippets | | |
| *HTTP API* | | | |
| HTTP API | Switch | Off | Prints uploaded files only. Web pages are refused. |
| API Docs… | Button (replaces the inline browser) | | |
| *Advanced ▸* Port, Token (Show, Copy, Regenerate…), Status | | 47311 | Only apps on this Mac can connect. |

### Moved, merged, removed

| Today | Proposed |
|---|---|
| Files tab | General |
| Watch row (Rules), API tab | Automation |
| "Ask first" | Show preview |
| Everything else editor | Removed |
| Rule tag (replaces global) | Default / None / Custom |
| Rule *Play a sound*, global `fit` / `ink` | Removed |

## 3. Precedence

What you do now (printer tile, ⌥) beats the matching rule, which beats the printer's settings, which beat General.

## 4. Mockups

```
General                                    Printers
┌──────────────────────────────────────┐   ┌────────────┬─────────────────────────┐
│ Default printer   MUNBYN · 4 × 6 in ⌃│   │ ▣ MUNBYN   │ Label size     4 × 6 in⌃│
│ Before printing   Count down 1.5 s  ⌃│   │   Default  │ Scaling      [Fit|Fill] │
│ Hold a file over the icon to pick a  │   │ ▣ Canon    │ Ink [Auto|Crisp|Photo](?)│
│ printer. Hold ⌥ to preview.          │   │            │ Threshold  ───●──── 50% │
│ Play sounds                      [●] │   │            │       [label preview]   │
│ Open at login                    [ ] │   │            │ ▸ Advanced              │
│ AFTER PRINTING                       │   │ + −        │      [Print Test Label] │
│ Tag the file [●] Printed ○ ● ● ● ● ● │   └────────────┴─────────────────────────┘
│ Then                     Leave it   ⌃│
│ HISTORY                              │   Rules
│ Keep printed labels      1 month    ⌃│   ┌──────────────────────────────────────┐
│ 12 labels, 3 MB [Show in Finder]     │   │ ☑ Royal Mail / Click & Drop          │
│                 [Delete All…]        │   │   If it comes from royalmail.com →   │
└──────────────────────────────────────┘   │   MUNBYN · Crisp                     │
                                           │ ☑ Amazon returns                     │
Automation                                 │ ↳ Everything else                    │
┌──────────────────────────────────────┐   │   Default printer and its settings   │
│ WATCHED FOLDERS                      │   │ + −          Drag to reorder. [Edit…]│
│ ~/Downloads/Labels             + −   │   │ Test a File [Choose…]                │
│ Unattended files          Ask       ⌃│   └──────────────────────────────────────┘
│ MCP                                  │
│ MCP server                       [ ] │
│ Let MCP print files from this Mac[ ] │
│ Let MCP change settings          [ ] │
│ HTTP API                         [ ] │
│ Prints uploaded files only.          │
│                        [API Docs…]   │
│ ▸ Advanced                           │
└──────────────────────────────────────┘
```

## 5. Migration

Run once, keyed by `settingsVersion = 2`.

- Keys not listed here are unchanged (`printer`, `countdown`, `tag*`, `afterPrintAction`, `watchedFolders`, `size.*`, `cutoff.*`, `nudge*.*`, `last.*`, …).
- `alwaysReview = true` becomes *Show preview*. **Bug today:** it is ignored for rule-routed files, because `printOnDefault` always passes an explicit `review`. Resolve the attended Default action from it.
- Legacy `fit` / `ink`: copy into `fit.<name>` / `ink.<name>` where missing, then delete.
- New: `unattendedAction` (default `ask`, today's hard-coded behaviour), `mcpCanReadFiles`, `mcpCanChangeSettings` (off).
- `rules.json` tags: equal to the General tag → `default`; `nil` → `none`; else custom. **Bug today:** the fallback's default tag silently overrides General, so turning *Add tag* off still tags files. `playSound == false`: dropped, logged.
- Fallback outcome: `printer` → `printer` if unset; `size` / `fit` / `ink` → that printer if unset; `action` → Before printing / Unattended files; `tag` → General; `copies > 1` dropped, logged.

## 6. Open questions

1. Four tabs with Files folded into General, or keep a fifth *Files* tab so General stays four rows?
2. Is *Automation* the right name, or *Connections*? Watched folders sit with MCP and HTTP because all three are unattended.
3. Remove per-rule sounds outright, or keep *Sound: Default / Off* for quiet watched-folder rules?
4. Should *Then* (rename, move, trash) also become a per-rule *Default / custom* field, like Tag?
5. Should HTTP get the same "print files from this Mac" switch as MCP, or stay upload-only?
6. Fallback with `copies > 1`: drop it, or turn it into a migrated rule?
