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
