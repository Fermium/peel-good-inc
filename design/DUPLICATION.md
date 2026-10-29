# Duplication and drift audit (2026-10-29)


## 1. Flows (function chains)
- **Drop on icon**: `performDragOperation` → `Intake.files(from:pb)` → `printOnDefault(.drop)` → `JobFlow.decide` (`RuleContext.inspect`, `RuleEngine.decide`, `Store.options`) → `JobFlow.makeJob` → `present` → `PrintJob.compose` (`DocumentLoader`, `LabelComposer`) → countdown → `send` (`historyName`, `LabelWriter`, `LabelPrint.send`) → `onSent` (lastPrint, `Sounds`, `AfterPrint.apply`, `FinderTag.apply`, `History.prune`). Hold → `DropZonesView` → `printOnDefault(forcedPrinter:)`.
- **Clipboard** `.clipboard`; **Print File…** `openFile` (trigger defaults to **.drop**); **Open With/Share** `application(open:)` `.openWith` (Share has its own `ShareViewController.copy`); **Services** `printAsLabel` `.openWith`.
- **Watched folder**: `FolderWatcher.settle` → `printOnDefault(.watchedFolder)` → `Notifier.ask` → `onAction` → `printOnDefault(override:)` (decides twice).
- **MCP**: `MCPTools.call` → `fileInput` (`APIRoutes.resolvePath/save`) → `AppLabelService.print` → `plan` (`findPrinter`, `JobFlow.decide(.api)`, `override`) → `run` (`makeJob`, `present`, wait). Preview: `plan` → `compose` → `pngData`. Config: `AppConfigurator.*`. **HTTP**: `APIRoutes.handle` → `parseSync` → same service.
- **CLI labels**: `Parser.parse` → `Context` → `LabelRun.run` → `choosePrinter` → `AppDefaults.options` → `Layout.apply` → (`TestPattern` + `writeSource`) → `process`. No rules, History, tagging or lastPrint. **printers/sizes/history/doctor**: `listPrinters`, `listSizes`, `historyRows`, `Doctor.run` (`server.json`, token, `/v1/health`).
- **Settings/Ink Modes**: panes → `Store` setters; `InkSample.page`; `InkCompareView.render` (hard-coded 4 inks). **Test label**: Printers button → `startTestLabel` → hand-written PDF → `start`. **Reprint**: menu `reprintLast` and `AppLabelService.reprintLast` (separate). **Pruning**: launch, every print, GeneralPane picker, `AppConfigurator`.

## 2. Findings, by impact

Effort: S = under half a day, M = 1 to 2 days, L = 3+ days.

**1. Option, printer and size resolution exists in 5+ copies. Owner: new `LabelizeCore` (M, medium risk)**
- **Base options**: `Store.options(for:)` (Store.swift:120-162) and `AppDefaults.options` (Layout.swift:35-44) read the same keys as strings, one through UserDefaults and one through CFPreferences.
- **Overlays**: `RuleEngine.decide` (RuleEngine.swift:163-169), `AppLabelService.override` (240-261), `AppConfigurator.setPrinterSettings` (170-209) and `Layout.apply` (49-84).
- **Printer lookup** is implemented five ways:
  - CLI: exact name, then case-insensitive, then substring on name or model (Context.swift:48-68).
  - API: exact name, then case-insensitive name or display name (AppLabelService:226-237).
  - Configurator: exact name or display name, against eligible printers for one setting and all printers for another (97, 173).
  - Rules: exact name only (RuleEngine:157).
  - Reprint: exact name only.
- **Behaviour already differs**:
  - The app skips hidden printers and falls back to any printer that takes 4x6. The CLI ignores `hiddenPrinters` and errors when there's no label printer.
  - When the saved size can't be used, the app silently uses 4x6 (Store:121-122) while the CLI errors (Labels.swift:67-70).
- **Fix**: in `LabelizeCore`:
  - a `SettingsReader` protocol with UserDefaults and CFPreferences backends and one `SettingsKey` enum;
  - one `PrinterResolver` (find by name, and the default-printer choice);
  - one `OptionOverrides` type that both `APIPrintRequest` and `Invocation` parse into;
  - `resolve(on:) -> (LabelOptions, notes)`.

**2. The CLI ignores rules, History and after-print. Owner: `LabelizeCore` (L, medium risk)**
- `peelgood print` gives different results from dropping the same file whenever a rule matches (printer, ink, copies).
- Its prints never reach `peelgood history` or Reprint Last.
- `RuleModel`, `RuleEngine` and `RuleContext` don't import AppKit, so they can move to `LabelizeCore`. The CLI could then read `rules.json` read-only, behind a flag at first (`--rules`, with a new `.cli` trigger).

**3. The API ignores the rule's computed action, and triggers are mis-mapped. Owner: `JobFlow` (S, low risk)**
- `AppLabelService.plan` uses `d.rule.outcome.action ?? .print` (AppLabelService.swift:140) instead of `d.action`. As a result:
  - "Everything else" uses its saved outcome, which `decide` deliberately ignores.
  - `newFilesAction` is skipped.
  - Settings > Rules "Test a file" can predict a different action than the API takes.
- Trigger mapping:
  - MCP `print_clipboard` uses `.api`, not `.clipboard`.
  - "Print File…" uses `.drop` (AppDelegate:364).
  - Share and Services both use `.openWith`.
- **Fix**: add one `JobFlow.plan(files, trigger, overrides)` used by both `AppDelegate.printOnDefault` and `AppLabelService`.

**4. Tagging rules are inconsistent. Owner: `AfterPrint` (S, low risk)**
- `JobFlow.swift:45-48`:
  - A rule with "Add Finder tag" turned off still gets the General tag.
  - A rule's tag is applied even when General tagging is off.
  - A new rule's tag is hard-coded to "Printed" (RuleModel `RuleOutcome.tag`), whatever tag name is set in General.
- `AfterPrint.addTag` (FileHandling.swift:56-60) is a second, colourless tag writer and is unused.
- **Fix**: add one `AfterPrint.tag(for: decision, store:)` and delete `addTag`.

**5. Two `LabelSize.display` definitions, one with a bug. Owner: LabelKit (S, low risk)**
- The app's version is in Store.swift:216-223, the CLI's in Context.swift:86-89.
- For metric rolls the CLI prints "100×150mm in". The test-label title has the same problem (Labels.swift:92).
- `PrinterInfo.displayName` (Store:225-230) and `.model` (Context:91-96) are the same code.
- **Fix**: put `display(.short/.long)` and `displayName` in LabelKit.

**6. Test-label generation is duplicated, with divergent options. Owner: LabelKit `TestLabel` (S, low risk)**
- The "write a SourcePage to a PDF" code exists three times: AppDelegate:396-411, Labels.swift:251-258, Screenshots:324-341.
- Options differ: the app keeps rotation on auto, the CLI forces none. Titles differ too.
- The app has no step wedge, although `InkSample` (InkCompare:112-127) is close to one.
- "Print Test Label" in the Printers pane changes the default printer as a side effect (Settings.swift:367-368).
- **Fix**:
  - `TestLabel.make(kind:size:title:) -> (SourcePage, (inout LabelOptions) -> Void)`
  - `SourcePage.writePDF(to:)`
  - `startTestLabel(printer:)`

**7. History is implemented twice. Owner: `LabelizeCore.History` (S, low risk)**
- File-name stamping and parsing: PrintJob:180-192 and Info.swift:114-131.
- The History folder path is built in three places: `Store.historyFolder`, `Context.historyFolder`, `AppPaths`.
- Choosing raster vs vector PDF: PrintJob:157-161 and Labels.swift:219-224.
- **Fix**:
  - `History { folder, fileName, parse, list, prune }`
  - `LabelWriter.write(_:size:for printer)`

**8. Paths and identifiers are hard-coded. Owner: new dependency-free `PeelGoodShared` (S, low risk)**
- "Peel Good" appears in Context:37-43, peel-good-mcp/main.swift:6-7, OpenAPI:434, APIServer:140, APIPane:120 and DocsPage:26.
- The bundle ID is hard-coded five times: Layout:7, Doctor:17, Share:26, Log:28, APIServer:203.
- `Doctor` and the MCP shim read `server.json` keys as untyped strings.
- The CLI doesn't use `AppPaths` scratch runs or the legacy-folder migration.
- **Fix**: `Paths`, `BundleID` and a `ServerInfo` Codable in the shared target, used by the app, CLI and shim. The Share extension includes the file directly.

**9. Validation lists and limits disagree. Owner: LabelKit + `LabelizeCore.Limits` (S, low risk)**
- The ink list is hard-coded in many places:
  - OpenAPI:165-166, 182-183, 217, 228, 306-307
  - MCPBridge:184, 224
  - error strings in AppLabelService:257 and AppConfigurator:189
  - the pickers in Views:91-94 and Settings:328-331, and InkCompare:280
- The CLI is the only part that uses `allCases`.
- Ranges: copies 1–20 (RuleEditorView:253), 1–100 (API/MCP), 1–999 (CLI, Layout:89); cutoff 0.2–0.8 (UI/MCP) vs 0–100% (CLI); MCP accepts countdown 0–10 and history 0–3650, but the UI pickers offer fixed values, so they show blank.
- The API lowercases values and the configurator doesn't.
- **Fix**:
  - `InkMode.title/help` in LabelKit, absorbing the CLI's `Manual.inkHelp`;
  - one `Limits` type;
  - schemas generated from `allCases` and `Limits`.

**10. OpenAPI and MCP option schemas are written twice. Owner: API (M, low risk)**
- The two schemas are hand-written separately. `OpenAPI.selfCheck` covers only OpenAPI.
- **Fix**: one `PrintOptionsSchema` that emits both formats, with `selfCheck` covering the MCP tools too.

**11. Job plumbing is duplicated. Owner: `JobFlow` and LabelKit (S, low risk)**
- Reprint: AppDelegate:368-376 and AppLabelService:95-107.
- The `Sender` typealias and its default: PrintJob:16, 39-41 and AppLabelService:12, 28-30.
- The code and warnings summary is computed three ways:
  - `PrintJob.warnings` filters out caution messages (72-75);
  - `AppLabelService.summary` doesn't (288-293);
  - the CLI prints everything.
- **Fix**: `JobFlow.reprint(store:copies:)` and a `LabelReport` type in LabelKit.

**12. Intake and supported types are duplicated. Owner: LabelKit `DocumentLoader.supportedTypes` (S, low risk)**
- `ShareViewController.copy` copies `Intake.files(from providers:)` (Intake:85-111).
- The supported-type list is defined separately in Intake:8, Share:35, APIRoutes:245-253, `MCPTools.sniff`, and the CLI hint text (Labels:171).

**13. Settings validation differs between UI and MCP (S, low risk)**
- The UI allows an empty `tagName` and "/" in `renameSuffix`; `AppConfigurator` refuses both.
- Settings keys are untyped strings in `Store`, `AppDefaults` and `FolderWatcher`.
- **Fix**: shared validators that the `Store` setters call. This also covers finding 1's keys.

**14. The screenshot harness copies the Settings tabs (S, low risk)**
- The tab list and `tab()` helper appear in Settings.swift:23-28, 47 and again in Screenshots.swift:44-51, 165-172. A new tab added to one won't show up in the other.
- **Fix**: `SettingsTabs.items(store:overrides:)`.

**15. Logging is split (S, low risk)**
- The app uses `Log` (os_log plus a file), Hummingbird uses swift-log under its own label, and the CLI and shim write only to stderr.
- **Fix**: an optional swift-log handler that forwards to `Log`.

## 3. Dead or misleading code

- `AfterPrint.addTag` (FileHandling:56-60).
- `AppDelegate`: `radioMenu`, `chooseFit`, `chooseInk`, `showHistory` and `printTestLabel` (315-346, 378-394) aren't in any menu.
- `RulesPreviewHarness` (RulesPreview.swift:28-70) is marked "Temporary" and is never called.
- `SizeCatalog.munbyn` is a leftover alias. Replace it with `.standard` in RuleEditorView:192 and RulesPreview:10.
- `AppLabelService.record` says "if wanted", but only `run` calls it.
- The `LabelService` doc (LabelService.swift:11) says only `localFile` jobs get tagged. Tagging is actually decided by the file's path (`AfterPrint.isUserFile`).

## 4. Order of work
1. Quick fixes (about a day): findings 3, 4, 5, 14 and the dead code.
2. Create `PeelGoodShared` and `LabelizeCore`; move History, Limits, TestLabel, paths and IDs (6–9, 11, 12).
3. `SettingsReader` + `PrinterResolver` for app, API and CLI (1).
4. Rules into `LabelizeCore`, opt-in for the CLI (2). 5. Generated schemas (10).

Add app/API/CLI parity tests at each step.

## 5. Done (branch consolidate)

New targets: `PeelGoodShared` (Foundation only: `AppIdentity`, `AppPaths`, `ServerInfo`) and `LabelizeCore` (Foundation, CoreGraphics, LabelKit, PeelGoodShared; no AppKit or SwiftUI). The app, the API, `LabelizeCLI`/`peelgood` and the MCP relay use them. Tests: `Tests/LabelizeCoreTests/CoreTests.swift`, `Tests/LabelizeAppTests/CoreParityTests.swift`, new cases in `JobFlowTests` and `RunTests`.

1. **Settings (finding 1, 13 keys).** Done. `AppSettings` with `SettingsKey`/`PrinterSettingsKey`: one typed reader/writer with UserDefaults (app), CFPreferences (CLI, read only) and in-memory backends. Per printer: size, fit, ink, cutoff, nudge and tone gamma (new: saved per printer, settable over MCP as `toneGamma`). `Store`, `FolderWatcher`, `AppPaths.migrate` and the CLI use it; `AppDefaults` is gone. The CLI writes one thing only: Reprint Last Label (item 3).
2. **Printers and options (finding 1).** Done. `PrinterResolver`: eligible printers (take 4x6, not hidden), the default (chosen in the app, else the label printer, else the first eligible; never hidden) and `match`: exact queue, queue or display name ignoring case, then the one printer whose queue, display name or model contains the text. Used by drops, `JobFlow`, `AppLabelService`, `AppConfigurator`, rules and the CLI. `OptionOverrides` checks size, fit, ink, cutoff, tone gamma, nudge, crop, rotation and padding for the API, MCP and the CLI (text ignores case everywhere). **Size fallback, one behaviour:** a *saved* size the printer can't take falls back to 4x6 (if it takes that) with a note, in the app and the CLI (the CLI used to fail); a size *asked for* (`--size`, API `size`) is an error; a rule's size falls back with a note, as before.
3. **Rules in the CLI (finding 2).** Done. `RuleBook` (model, matching, `decide`, rules.json) and `RuleContext` live in LabelizeCore (file inspection is `LabelKit.FileFacts`); the app's `RuleEngine` wraps it. New trigger `cli` ("From the command line"). **Decision:** `peelgood print` applies the rules whenever rules.json exists; `--no-rules` turns them off, `--rules` warns when there are none. The file is read only (a broken one isn't moved). Options passed on the command line win over the rule; `--printer` wins like a printer tile. A rule's Show preview or Ask can't preview in a terminal: it prints and says so. Sent prints are saved to History and become Reprint Last Label (the `last.*` keys, the only ones the CLI writes), unless `--no-history`; dry runs never are. Preview, test-label and step-wedge don't use rules.
4. **Actions and triggers (finding 3).** Done. `JobFlow.plan` is the one plan for drops, the menu, watched folders, HTTP and MCP; the API takes the decided action, so Everything else's saved action is ignored everywhere. Only watched folders are unattended (follow New files, may Ask); for every other trigger, the API included, Ask shows the preview. Print Clipboard over MCP is `clipboard`; Print File… is `openWith`. `JobFlow.reprintPlan` replaces the two reprint copies (finding 11).
5. **Tags (finding 4).** Done. `FinderTag.apply` is the only writer; `AfterPrint.addTag` is deleted. **Precedence:** General > Add Finder tag switches tagging on or off for every print. When on, the rule's Finder tag decides: Default (new rules, and always Everything else) uses General's tag, None adds none, Custom adds the rule's tag instead. `RuleTag` in JSON is `"default"`, `"none"` or `{name, color}`; old files keep their meaning (no tag = none, a tag object = custom). The rule editor has a Default/None/Custom picker.
6. **Size display (finding 5).** Done. `LabelSize.display/primary/secondary` and `PrinterInfo.displayName` are in LabelKit; the app's and the CLI's copies are gone. The CLI header and test-label titles say "100 × 150 mm".
7. **Test labels (finding 6).** Done. `TestLabel` (pattern, step wedge, ink sample) with `SourcePage.writePDF` and one `adjust` (no crop, no rotation; crisp for the pattern; photo and no tone correction for the wedge unless given), used by Settings > Printers, the CLI, Ink Modes (now pages through the ink sample and the step wedge) and screenshots. Print Test Label prints on the printer shown and no longer changes the default printer. `LabelWriter.write(_:size:forLabelPrinter:to:)` picks raster or vector once (finding 7).
8. **Paths and IDs (findings 7, 8).** Done. `AppPaths` (support, logs, history, rules.json, token, server.json, log file; `LABELIZE_SUPPORT_DIR`; scratch runs) and `AppIdentity` (bundle ID, names) in `PeelGoodShared`; `ServerInfo` is the one Codable for server.json, written by the app and read by Doctor and the MCP relay. `History` (names, parsing, list, save, prune, summary) is in LabelizeCore for the app and the CLI. The Share extension compiles `Sources/PeelGoodShared/AppIdentity.swift` with its own file (scripts/make-app.sh, scripts/release-build.sh).
9. **Lists and limits (finding 9).** Done. `Limits`: copies 1 to 100 everywhere (the rule editor allowed 20, the CLI 999), countdown 0 to 10 s, history 0 to 3650 days, cutoff 20 to 80 % (the CLI allowed 0 to 100), nudge ±10 mm, tone gamma 0.1 to 2, tag name 64 characters. Pickers list `InkMode`/`FitMode.allCases` (`title`, and `InkMode.help` replaces `Manual.inkHelp`); MCP and OpenAPI schemas and the error strings are generated from them. The Before printing and Keep printed labels pickers add the saved value when MCP set one outside their list, so they never show blank.
10. **Dead code (section 3).** Done. Removed `AppDelegate.radioMenu/chooseFit/chooseInk/showHistory/printTestLabel`, `RulesPreviewHarness`, `AfterPrint.addTag`, `SizeCatalog.munbyn`; fixed the `AppLabelService.record` and `LabelService` tagging comments.

Not done here: findings 10 (one schema type for OpenAPI and MCP), 12 (supported types; the data formats are now one table, see section 6), 14 (Settings tab list) and 15 (logging). Finding 13 is done in section 6.

## 6. Second review

An independent review of branch consolidate found 14 more items. Each one is fixed below; tests are in `Tests/LabelizeAppTests/SecondReviewTests.swift`, `Tests/LabelKitTests/LabelKitTests.swift` (`reportableWarningsDropCautionsOnly`) and `Tests/LabelizeCLITests/RunTests.swift`.

1. **Warnings and code counts disagreed (drift).** `LabelKit/LabelReport.swift` adds `codeCounts` (expected, verified, missing) and `reportableWarnings` (cautions about codes that should still scan left out) on `ComposedLabel` and `[ComposedLabel]`. The popover (`PrintJob.codeSummary`, `warnings`, the compose log), the API and MCP (`AppLabelService.fill`, `preview`, per-label `detail`) and the CLI (`LabelRun.process`, per page) all use them. `AppLabelService.summary` is gone. Preview warnings now include the rule's notes, as the job's do.
2. **Rule printer checked by exact name (drift).** `RuleSummary.printerName` and the rule editor use `PrinterResolver.match`, as printing does. The editor rewrites a display name to the queue name when it opens, so the picker shows the right printer instead of a stray entry. MCP `add_rule`/`update_rule` store the matched queue name (item 12). The "not connected" text uses the new `PrinterInfo.displayName(queue:)`, which `displayName` uses too.
3. **MCP type sniffing was a short copy (drift).** `Intake.formats` is one table of (UTType, extension, first-bytes check) for PDF, PNG, JPEG, SVG, TIFF, GIF and HEIC. `MCPTools.sniff`, `APIRoutes.uploadName` (by MIME type, through `UTType`) and `Intake.dataTypes` read it. TIFF, GIF and HEIC sent as content_base64 without a file name now work; the clipboard also reads GIF and HEIC data.
4. **Typed-in settings checked only over MCP (drift).** `LabelizeCore/SettingsChecks.swift`: `Limits.renameSuffixLength` (64), `Limits.renameSuffix(_:)` and `Limits.tagName(_:)` (throwing `OptionError`), used by `AppConfigurator`, and `tidyRenameSuffix`/`tidyTagName`, used by Settings (item 13).
5. **Preview DTO repeated the label info (duplication).** `APILabelPreview` holds an `APILabelInfo` plus width, height and png, and still encodes flat. `preview()` calls `detail(_:index:)`. OpenAPI's LabelPreview schema is `labelInfoFields` plus the three image fields.
6. **General Finder tag built three times (duplication).** `AppSettings.generalTag` is now the one builder (name and color, whether or not tagging is on); `RuleTag.resolve(settings)` and the rule editor use it. The editor gets the Store's settings (`RuleEditorView(settings:)`) instead of making its own `AppSettings`.
7. **Unused declarations (dead code).** Removed `AppSettings.get<T>`, `APIRoutes.decodeJSON` and the now unused `APIJSON.decoder`, `APIController.mcpSessions`, `MCPSessions.count`, `RuleEngine.defaultFallback`, `AppLabelService.maxCopies` and `AppLabelService.copies` (`MockLabelService` uses `AppConfigurator.option { try OptionOverrides.copies(n) }`). `MockLabelService` uses `APIJob.Source.clipboard` and `.reprint`.
8. **`peelgood preview` skipped the rules (drift).** Preview applies the rules like print, behind the same `--rules`/`--no-rules` switches (now listed for preview). It still needs no printer. The header names the matching rule (not Everything else) for preview and print. This replaces "Preview ... don't use rules" in section 5, item 3.
9. **CLI wrote one job per file (drift).** `peelgood print a.pdf b.pdf` composes every file, writes one PDF with every label, sends it once with the copies and calls `record()` once, with the first file as the source, as the app does with a drop. Each file still gets its own label PDF in `files[].pdf`. `lp`, `job`, `history` and the combined `pdf` moved to the top of the JSON report. If a file can't be read, nothing is sent: the app fails the whole drop too.
10. **Empty `printer` forced the default printer (drift).** `APIPrintRequest.given` treats empty or blank text as missing. The init (used by MCP), `APIRoutes.merge` (forms and query) and `AppLabelService.plan` normalize printer, size, fit, ink and path; an empty `copies` is missing too. An empty printer now leaves the rule's printer in charge.
11. **Print Test Label ignored Show preview (drift).** `JobFlow.testLabelPlan` uses `review || store.alwaysReview`, like `reprintPlan`.
12. **add_rule/update_rule dropped bad fit and ink (drift).** `AppConfigurator.decodeRule` first runs fit and ink through `OptionOverrides.fit`/`ink` (any letter case; `invalid_fit`/`invalid_ink` on a bad value) and writes back the normalized value. The printer goes through `PrinterResolver` among eligible printers and is stored as the queue name; an unknown printer is `printer_not_found`, except that `update_rule` may keep the rule's current printer even if it isn't connected now. An empty printer means the default printer.
13. **Settings saved values MCP refuses (drift).** The nudge field clamps to `Limits.nudgeMM` (`Limits.clampNudge`). The rename suffix and tag name use `TidyTextField`: it drops / and :, cuts to the length limits, and a cleared tag name keeps the saved one (shown again when you leave the field).
14. **`peelgood sizes` marked the saved size (drift).** It marks `AppSettings.options(for:).options.size`, the size the app really prints at (4x6 when nothing is saved or the saved size isn't supported), and shows the fallback note.
