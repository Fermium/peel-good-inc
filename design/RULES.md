# Rules

## Mental model

A rule is one sentence: **"When a file *[conditions]*, print it on *[printer]* at *[size]*."**
Rules are checked from the top down and the **first match wins**, like Mail rules. Below them sits
**Everything else**, which always applies last, can't be moved or deleted, and has no conditions.
Out of the box it uses the printer and roll picked in the menu bar, so having no rules changes nothing.

Any setting a rule leaves as **Default** comes from the printer's remembered settings (the menu bar
choices). A rule only states what is different.

Rules decide *where* and *how* a file prints. They never decide *what* prints: **every page of every
file always prints.** No condition or action skips, filters or reorders pages. Copies repeat the whole
file.

## Layout (Settings → Rules, 680 pt)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Rules pick the printer and label size for each file. Labelize uses   │
│ the first rule that matches, from the top.                           │
│ ┌──────────────────────────────────────────────────────────────────┐ │
│ │ ☑ Royal Mail / Click & Drop                                      │ │
│ │   If it comes from royalmail.com or has 4 × 6 in label pages     │ │
│ │   → Label Printer · 4 × 6 in · Crisp                             │ │
│ │ ☑ Amazon returns                                     ✓ Matches   │ │
│ │   If it is an image and includes a QR code → Label Printer · 4×4 │ │
│ │ ☐ Shipping labels from Letter pages            (dimmed: off)     │ │
│ │ ☑ Photos to Canon TS9500 series                                  │ │
│ │   (drag rows to reorder)                                         │ │
│ ├──────────────────────────────────────────────────────────────────┤ │
│ │ ↳ Everything else                                                │ │
│ │   Default printer and its settings                               │ │
│ ├──────────────────────────────────────────────────────────────────┤ │
│ │ [+▾] [−]                    Double-click to edit. Drag to reorder. │
│ └──────────────────────────────────────────────────────────────────┘ │
│ Test a File                                                          │
│ ┌╌╌╌╌╌╌╌╌┐  return.png                                                │
│ ╎  icon  ╎  Matches **Amazon returns**.                              │
│ ╎Choose…╎  Label Printer · 4 × 4 in · Fit · Crisp · Print after…    │
│ └╌╌╌╌╌╌╌╌┘  No source website · Image · 1 page · 1179 × 2556 px · QR │
│             Pretend it was [dropped on the menu bar icon ▾]          │
└──────────────────────────────────────────────────────────────────────┘
```

Editor sheet (600 × 700, grouped Form):

```
 Name            [Amazon returns                     ]
 If [all ▾] of these are true:
   [File type ▾]          [is ▾]       [Image ▾]               (−)(+)
   [Codes on the page ▾]  [include ▾]  [a QR code ▾]           (−)(+)
   [Source website ▾]     [is ▾]       (amazon.com)(amazon.co.uk)  (−)(+)
 Then print it
   Printer               [Default printer (Label Printer) ▾]
   Label size            [Default (4 × 6 in) ▾]
   Scaling               [Default (Fit) ▾]
   Ink                   [Default (Auto) ▾]
   When a file matches   [Default ▾]
                         Follows Before printing in General. Files in watched folders follow New files.
   Copies                1 [⌃⌄]
 After printing
   Add Finder tag        [on]   [Printed] [● Green ▾]
 ⚠ Fill in or remove the marked conditions.          [Cancel] [OK]
```

## Interaction

- **Add (+)** is a menu: *New Rule…* and *Start from a template*: Amazon returns, Royal Mail / Click &
  Drop, Shipping labels from Letter pages, Photos to *&lt;color printer&gt;*. Both open the editor so the
  user sees exactly what they're adding. Cancel adds nothing. New rules go to the bottom of the list,
  just above Everything else.
- **Edit**: double-click a row, press Return, use the context menu, or click *Edit…*. Everything else has
  its own *Edit…* button, and its editor shows only the *Then* sections.
- **Enable**: the row checkbox. Disabled rules are dimmed and skipped.
- **Reorder**: drag rows. The context menu also has *Move to Top* and *Duplicate*.
- **Delete**: the − button, the Delete key or the context menu. Everything else can't be deleted.
- **Test a File**: drop a file on the dashed area or click *Choose…*. Labelize reads the file (including
  codes) and shows the matching rule, the settings it would print with, any fallback notes, and the facts
  it read. The matching row gets a green **Matches** badge. *Pretend it was* changes the trigger. The
  result updates as you edit rules. Testing never prints.
- Changes save on their own about 300 ms after each edit. There is no Apply button, as in System Settings.

## Conditions (field → comparisons → value)

| Field | Comparisons | Value |
|---|---|---|
| Source website | is / is not / is unknown | domain tokens. Pasted URLs become their host without "www."; subdomains match too |
| File name | contains / doesn't contain / begins with / ends with / is | text tokens, case-insensitive. Any token can match |
| File type | is / is not | PDF, Image, SVG, Screenshot. Screenshots also count as images |
| Folder | is inside / is not inside | Choose… (subfolders included) |
| How it arrives | is / is not | Dropped on the menu bar icon, Printed from the clipboard, Opened from Finder, Found in a watched folder, Sent by another app |
| Page size | is / is not | 4 × 6 in label, US Letter, A4. Checks the first page in either orientation, within 3 mm |
| Number of pages | is more than / is fewer than / is | number |
| Codes on the page | include / don't include | any code, QR, Data Matrix, PDF417, Aztec, barcode (1D) |
| Code text | contains / doesn't contain | text tokens, matched against decoded payloads |

Rule rows describe themselves in plain English, for example "If it comes from royalmail.com or has 4 × 6 in
label pages → Label Printer · 4 × 6 in · Crisp".

## Outcome

Printer (*Default printer* or a named one) · Label size (*Default (W × H in)* or one the printer supports) ·
Scaling (Default / Fit / Fill) · Ink (Default / Auto / Crisp / Photo; turned off for non-thermal
printers) · When a file matches (Default / *Print* / *Show preview* / *Ask*) · Copies 1–20 ·
Finder tag with color (after a successful print). Sounds follow General; older rules' *Play a sound* is ignored.

The Default action follows General > Before printing for files you hand over (drop, clipboard, Finder) and
Rules > New files (Ask, Print or Show preview; Ask by default) for watched folders. *Ask* sends a notification
and applies only to unattended triggers. For a file you dropped yourself it becomes *Show preview*, because
you're already looking at the screen.

*Everything else* is fixed: the default printer and its settings. It can't be edited in Settings or over MCP,
and anything older versions saved in it is ignored.

## Edge cases

- **The rule's printer isn't connected**: the file uses the default printer, and the decision carries a
  note ("The rule's printer isn't connected, so this uses …") for the job view. The editor keeps the
  missing printer selectable as "Name (not connected)" so the setting isn't lost.
- **The size isn't supported by the target printer** (`resolve` returns nil): the file uses the printer's
  label size and gets a note. The editor shows the size as "(not supported by this printer)".
- **A condition is blank** (no tokens, no folder): it never matches. The editor marks it ⚠ and disables
  OK, and the row shows ⚠. A rule with no conditions never matches, so it can't swallow every file.
- **No source website**: common for screenshots, AirDrop files and files from Mail. *is unknown* matches
  these. That's why the Amazon template matches the QR code rather than amazon.com: return codes are
  usually screenshots.
- **Raster images have no physical size**: *Page size* never matches screenshots or photos.
- **Code detection costs ~50–150 ms**: `RuleContext.inspect` runs it only when asked. Pass
  `engine.needsCodes`, which is true only if an enabled rule looks at codes.
- **The user explicitly picks a printer** (drop zone tile): pass it as `forcedPrinter`. The tile beats the
  rule's printer, and the rule's size still applies if that printer supports it. **⌥ while dropping**
  still forces review.
- **A multi-file drop**: evaluate each file. Group consecutive files that get the same decision into one
  job, so a Royal Mail PDF plus a photo goes to two printers.
- **A corrupt rules.json** is renamed to `rules.json.broken` and the list starts empty. It is never
  silently overwritten.
- **Shadowed rules** (a broad rule above a narrow one): not detected. Test a File shows which rule wins.
- **No "don't print" action**: deliberate, per the no-dropped-pages rule. For watched folders, an
  *Ask* fallback covers "maybe not this one".
