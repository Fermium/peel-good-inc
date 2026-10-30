import AppKit
import LabelKit
import PeelGoodCore

/// Reads and changes the app's configuration for MCP: settings in `Store`, per-printer settings,
/// rules and watched folders, and the HTTP API switch and port. Every change is logged with old and new values.
/// It can't touch the MCP switch, the MCP permissions or the token; those stay in Settings.
@MainActor
final class AppConfigurator {
    struct Folders {
        var get: @MainActor () -> [URL]
        var set: @MainActor ([URL]) -> Void

        static let live = Folders(get: { FolderWatcher.shared.folders }, set: { FolderWatcher.shared.folders = $0 })

        static func inMemory(_ initial: [URL] = []) -> Folders {
            final class Box { var urls: [URL] = [] }
            let box = Box()
            box.urls = initial
            return Folders(get: { box.urls }, set: { box.urls = $0 })
        }
    }

    let store: Store
    let rules: RuleEngine
    let folders: Folders
    /// Settings MCP may never change, with the reason given back.
    static let protectedKeys: Set<String> = ["mcpEnabled", "mcpCanUseLocalFiles", "mcpCanChangeSettings", "token"]

    init(store: Store, rules: RuleEngine, folders: Folders) {
        self.store = store
        self.rules = rules
        self.folders = folders
    }

    // MARK: Reading

    func settings() -> [String: Any] {
        store.refresh()
        let api = APIController.shared
        return [
            "general": [
                "defaultPrinter": store.printer?.name ?? NSNull(),
                "countdownSeconds": store.countdown,
                "alwaysPreview": store.alwaysReview,
                "newFilesAction": store.newFilesAction.rawValue,
                "playSounds": store.playSounds,
                "hiddenPrinters": store.hiddenPrinters,
            ] as [String: Any],
            "files": [
                "tagAfterPrint": store.tagAfterPrint,
                "tagName": store.tagName,
                "tagColor": Self.colorName(store.tagColor),
                "afterPrint": store.afterPrintAction.rawValue,
                "renameSuffix": store.renameSuffix,
                "moveFolder": store.moveFolder?.path ?? NSNull(),
                "keepHistoryDays": store.historyDays,
            ] as [String: Any],
            "printers": store.printers.map { p -> [String: Any] in
                let n = store.nudge(for: p)
                return ["name": p.name, "displayName": p.displayName, "isLabelPrinter": p.isLabelPrinter,
                        "hidden": store.hiddenPrinters.contains(p.name), "size": store.size(for: p).description,
                        "fit": store.fit(for: p).rawValue, "ink": store.ink(for: p).rawValue,
                        "cutoff": store.cutoff(for: p), "toneGamma": store.toneGamma(for: p), "nudgeXmm": Double(n.x), "nudgeYmm": Double(n.y)]
            },
            "watchedFolders": folders.get().map(\.path),
            "api": [
                "httpEnabled": api.httpEnabled, "mcpEnabled": api.mcpEnabled, "port": api.port,
                "mcpCanUseLocalFiles": api.mcpCanUseLocalFiles, "mcpCanChangeSettings": api.mcpCanChangeSettings,
            ] as [String: Any],
        ]
    }

    func listRules() throws -> [String: Any] {
        var fallback = try Self.object(rules.fallback)
        fallback["outcome"] = nil
        fallback["description"] = "Default printer and its settings."
        return ["rules": try rules.rules.map(Self.object), "everythingElse": fallback]
    }

    func rule(_ id: String) throws -> [String: Any] {
        try Self.object(try find(id))
    }

    // MARK: Settings

    /// Validates every key first, then applies them all. Returns one line per change.
    func updateSettings(_ args: [String: Any]) throws -> [String] {
        var steps: [() -> String?] = []
        for (key, value) in args.sorted(by: { $0.key < $1.key }) {
            if Self.protectedKeys.contains(key) {
                throw APIError(status: 403, code: "protected_setting", message: "MCP can't change \(key). Change it in Peel Good Inc. Settings > API.")
            }
            switch key {
            case "defaultPrinter":
                let name = try Self.string(value, key)
                store.refresh()
                guard let p = store.resolver.find(name, in: .eligible) else {
                    throw APIError.notFound("Printer \(name) not found.", code: "printer_not_found")
                }
                steps.append { self.change(key, self.store.printer?.name, p.name) { self.store.printer = p } }
            case "countdownSeconds":
                let v = try Self.number(value, key, Limits.countdownSeconds)
                steps.append { self.change(key, self.store.countdown, v) { self.store.countdown = v } }
            case "alwaysPreview":
                let v = try Self.bool(value, key)
                steps.append { self.change(key, self.store.alwaysReview, v) { self.store.alwaysReview = v } }
            case "newFilesAction":
                let text = try Self.string(value, key)
                guard let v = RuleAction(rawValue: text) else {
                    throw APIError.badRequest("newFilesAction must be \(RuleAction.allCases.map(\.rawValue).joined(separator: ", ")).", code: "invalid_newFilesAction")
                }
                steps.append { self.change(key, self.store.newFilesAction.rawValue, v.rawValue) { self.store.newFilesAction = v } }
            case "playSounds":
                let v = try Self.bool(value, key)
                steps.append { self.change(key, self.store.playSounds, v) { self.store.playSounds = v } }
            case "hiddenPrinters":
                let v = try Self.strings(value, key)
                steps.append { self.change(key, self.store.hiddenPrinters, v) { self.store.hiddenPrinters = v } }
            case "tagAfterPrint":
                let v = try Self.bool(value, key)
                steps.append { self.change(key, self.store.tagAfterPrint, v) { self.store.tagAfterPrint = v } }
            case "tagName":
                let text = try Self.string(value, key)
                let v = try Self.option { try Limits.tagName(text) }
                steps.append { self.change(key, self.store.tagName, v) { self.store.tagName = v } }
            case "tagColor":
                let v = try Self.color(value, key)
                steps.append { self.change(key, Self.colorName(self.store.tagColor), Self.colorName(v)) { self.store.tagColor = v } }
            case "afterPrint":
                let text = try Self.string(value, key)
                guard let v = AfterPrintAction(rawValue: text) else {
                    throw APIError.badRequest("afterPrint must be \(AfterPrintAction.allCases.map(\.rawValue).joined(separator: ", ")).", code: "invalid_afterPrint")
                }
                steps.append { self.change(key, self.store.afterPrintAction.rawValue, v.rawValue) { self.store.afterPrintAction = v } }
            case "renameSuffix":
                let text = try Self.string(value, key)
                let v = try Self.option { try Limits.renameSuffix(text) }
                steps.append { self.change(key, self.store.renameSuffix, v) { self.store.renameSuffix = v } }
            case "moveFolder":
                let v = value is NSNull ? nil : try Self.folder(value, key)
                steps.append { self.change(key, self.store.moveFolder?.path, v?.path) { self.store.moveFolder = v } }
            case "keepHistoryDays":
                let v = try Self.int(value, key, Limits.historyDays)
                steps.append {
                    self.change(key, self.store.historyDays, v) {
                        self.store.historyDays = v
                        History.prune(keepingDays: v)
                    }
                }
            case "httpEnabled":
                let v = try Self.bool(value, key)
                steps.append { self.change(key, APIController.shared.httpEnabled, v) { APIController.shared.httpEnabled = v } }
            case "port":
                let v = try Self.int(value, key, APIController.validPorts)
                steps.append {
                    // Applied a moment later so this reply still reaches the client; it has to reconnect on the new port.
                    self.change(key, APIController.shared.port, v) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { APIController.shared.port = v } }
                    }.map { $0 + " (reconnect on the new port)" }
                }
            default:
                throw APIError.badRequest("Unknown setting \(key).", code: "unknown_setting")
            }
        }
        guard !steps.isEmpty else { throw APIError.badRequest("Nothing to change.", code: "empty") }
        let changes = steps.compactMap { $0() }
        return changes.isEmpty ? ["Nothing changed."] : changes
    }

    func setPrinterSettings(_ args: [String: Any]) throws -> [String] {
        store.refresh()
        let name = try Self.string(args["printer"] ?? NSNull(), "printer")
        guard let p = store.resolver.find(name) else {
            throw APIError.notFound("Printer \(name) not found.", code: "printer_not_found")
        }
        var steps: [() -> String?] = []
        for (key, value) in args.sorted(by: { $0.key < $1.key }) where key != "printer" {
            let label = "\(p.name) \(key)"
            switch key {
            case "size":
                let size = try Self.option { try OptionOverrides.size(try Self.string(value, key), on: p) }
                steps.append { self.change(label, self.store.size(for: p).description, size.description) { self.store.setSize(size, for: p) } }
            case "fit":
                let v = try Self.option { try OptionOverrides.fit(try Self.string(value, key)) }
                steps.append { self.change(label, self.store.fit(for: p).rawValue, v.rawValue) { self.store.setFit(v, for: p) } }
            case "ink":
                let v = try Self.option { try OptionOverrides.ink(try Self.string(value, key)) }
                steps.append { self.change(label, self.store.ink(for: p).rawValue, v.rawValue) { self.store.setInk(v, for: p) } }
            case "cutoff":
                let v = try Self.number(value, key, Limits.cutoff)
                steps.append { self.change(label, self.store.cutoff(for: p), v) { self.store.setCutoff(v, for: p) } }
            case "toneGamma":
                let v = try Self.number(value, key, Limits.toneGamma)
                steps.append { self.change(label, self.store.toneGamma(for: p), v) { self.store.setToneGamma(v, for: p) } }
            case "nudgeXmm", "nudgeYmm":
                let v = try Self.number(value, key, Limits.nudgeMM)
                steps.append {
                    var n = self.store.nudge(for: p)
                    let old = Double(key == "nudgeXmm" ? n.x : n.y)
                    if key == "nudgeXmm" { n.x = v } else { n.y = v }
                    return self.change(label, old, v) { self.store.setNudge(n, for: p) }
                }
            default:
                throw APIError.badRequest("Unknown printer setting \(key).", code: "unknown_setting")
            }
        }
        guard !steps.isEmpty else { throw APIError.badRequest("Nothing to change.", code: "empty") }
        let changes = steps.compactMap { $0() }
        return changes.isEmpty ? ["Nothing changed."] : changes
    }

    func setWatchedFolders(_ value: Any) throws -> [String] {
        let urls = try Self.strings(value, "folders").map { try Self.folder($0, "folders") }
        let old = folders.get().map(\.path), new = urls.map(\.path)
        guard old != new else { return ["Nothing changed."] }
        folders.set(urls)
        return [logChange("watchedFolders", old, new)]
    }

    // MARK: Rules

    func addRule(_ input: [String: Any]) throws -> [String: Any] {
        var base = try Self.object(Rule(name: "", conditions: []))
        base["id"] = UUID().uuidString
        let rule = try decodeRule(Self.mergeRule(base, input, existing: []), keeping: nil)
        rules.add(rule)
        Log.notice(.api, "MCP added rule \(rule.displayName) (\(rule.id)) at position \(rules.rules.count)")
        return try Self.object(rule)
    }

    func updateRule(_ id: String, _ input: [String: Any]) throws -> [String: Any] {
        let old = try find(id)
        guard old.id != rules.fallback.id else { return try updateEverythingElse(input) }
        var merged = Self.mergeRule(try Self.object(old), input, existing: old.conditions)
        merged["id"] = old.id.uuidString
        let rule = try decodeRule(merged, keeping: old.outcome.printer)
        rules.update(rule)
        Log.notice(.api, "MCP changed rule \(rule.displayName) (\(rule.id)): \(Self.dump(old)) → \(Self.dump(rule))")
        return try Self.object(rule)
    }

    /// "Everything else" is fixed: the default printer and its settings.
    func updateEverythingElse(_ input: [String: Any]) throws -> [String: Any] {
        throw APIError.badRequest("Everything else always uses the default printer and its settings. Change those with update_settings and set_printer_settings, or add a rule.",
                                  code: "protected_rule")
    }

    func deleteRule(_ id: String) throws -> String {
        let rule = try find(id)
        guard rule.id != rules.fallback.id else { throw APIError.badRequest("Everything else can't be deleted.", code: "protected_rule") }
        rules.remove([rule.id])
        Log.notice(.api, "MCP deleted rule \(rule.displayName) (\(rule.id)): \(Self.dump(rule))")
        return "Deleted \(rule.displayName)."
    }

    func reorderRules(_ ids: [String]) throws -> [String] {
        let current = rules.rules
        let wanted = try ids.map { id -> Rule in
            guard let r = current.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw APIError.notFound("No rule with id \(id).", code: "rule_not_found")
            }
            return r
        }
        guard Set(wanted.map(\.id)).count == current.count, wanted.count == current.count else {
            throw APIError.badRequest("List every rule id once, in the new order (Everything else stays last).", code: "invalid_order")
        }
        rules.rules = wanted
        let line = logChange("rule order", current.map(\.displayName), wanted.map(\.displayName))
        return [line]
    }

    private func find(_ id: String) throws -> Rule {
        if rules.fallback.id.uuidString.caseInsensitiveCompare(id) == .orderedSame || id.lowercased() == "everything else" { return rules.fallback }
        guard let r = rules.rules.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw APIError.notFound("No rule with id \(id).", code: "rule_not_found")
        }
        return r
    }

    /// Checks fit, ink and printer as the print tools and set_printer_settings do, then decodes.
    /// `keeping`: the rule's current printer, which may stay even if it isn't connected now.
    private func decodeRule(_ object: [String: Any], keeping: String?) throws -> Rule {
        let object = try normalizeOutcome(object, keeping: keeping)
        let rule: Rule
        do {
            rule = try JSONDecoder().decode(Rule.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw APIError.badRequest("That isn't a valid rule: \(Self.describe(error)). See list_rules for the format.", code: "invalid_rule")
        }
        for c in rule.conditions {
            guard c.field.ops.contains(c.op) else {
                throw APIError.badRequest("\(c.field.rawValue) can't use \(c.op.rawValue). Use \(c.field.ops.map(\.rawValue).joined(separator: ", ")).", code: "invalid_rule")
            }
            let choices = c.field.choices.map(\.0)
            if !choices.isEmpty, let bad = c.values.first(where: { !choices.contains($0) }) {
                throw APIError.badRequest("\(bad) isn't a \(c.field.rawValue). Use \(choices.joined(separator: ", ")).", code: "invalid_rule")
            }
        }
        if let size = rule.outcome.size, LabelSize(parsing: size) == nil {
            throw APIError.badRequest("Size \(size) isn't valid. Use a size like 4x6.", code: "invalid_rule")
        }
        guard Limits.copies.contains(rule.outcome.copies) else {
            throw APIError.badRequest("copies must be \(Limits.describe(Limits.copies)).", code: "invalid_rule")
        }
        return rule
    }

    /// Fit and ink in any letter case, checked by `OptionOverrides`. The printer by queue or display name
    /// (`PrinterResolver.match`), stored as its queue name; an empty one means the default printer.
    private func normalizeOutcome(_ object: [String: Any], keeping: String?) throws -> [String: Any] {
        guard var o = object["outcome"] as? [String: Any] else { return object }
        if let v = o["fit"], !(v is NSNull) {
            let text = try Self.string(v, "fit")
            o["fit"] = try Self.option { try OptionOverrides.fit(text) }.rawValue
        }
        if let v = o["ink"], !(v is NSNull) {
            let text = try Self.string(v, "ink")
            o["ink"] = try Self.option { try OptionOverrides.ink(text) }.rawValue
        }
        if let v = o["printer"], !(v is NSNull) {
            let name = try Self.string(v, "printer").trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                o["printer"] = NSNull()
            } else if let p = store.resolver.find(name, in: .eligible) {
                o["printer"] = p.name
            } else if name != keeping {
                throw APIError.notFound("Printer \(name) not found. list_printers shows the printers.", code: "printer_not_found")
            }
        }
        var out = object
        out["outcome"] = o
        return out
    }

    /// Fields given replace the base's; each condition starts from its field's defaults (or the matching existing condition).
    private static func mergeRule(_ base: [String: Any], _ input: [String: Any], existing: [RuleCondition]) -> [String: Any] {
        var out = base
        for (key, value) in input where key != "id" {
            switch key {
            case "conditions":
                guard let list = value as? [[String: Any]] else { out[key] = value; continue }
                out[key] = list.map { c -> [String: Any] in
                    let match = (c["id"] as? String).flatMap { id in existing.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame } }
                    let field = (c["field"] as? String).flatMap(RuleCondition.Field.init(rawValue:))
                    var start = match ?? field?.starter ?? RuleCondition(field: .name, op: .contains)
                    if match == nil { start.id = UUID() }
                    if let field, field != start.field { start = field.starter }
                    var merged = merge((try? object(start)) ?? [:], c)
                    if match == nil { merged["id"] = start.id.uuidString }
                    return merged
                }
            case "outcome":
                if let o = value as? [String: Any] { out[key] = merge(base["outcome"] as? [String: Any] ?? [:], normalizeOutcome(o)) } else { out[key] = value }
            default:
                out[key] = value
            }
        }
        return out
    }

    /// Accepts tag colors by name ("green") as well as Finder's numbers.
    private static func normalizeOutcome(_ o: [String: Any]) -> [String: Any] {
        var o = o
        if var tag = o["tag"] as? [String: Any], let name = tag["color"] as? String,
           let color = FinderTag.Color.allCases.first(where: { colorName($0) == name.lowercased() }) {
            tag["color"] = color.rawValue
            o["tag"] = tag
        }
        return o
    }

    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        a.merging(b) { _, new in new }
    }

    // MARK: Values

    @discardableResult
    private func change<T: Equatable>(_ key: String, _ old: T, _ new: T, apply: () -> Void) -> String? {
        guard old != new else { return nil }
        apply()
        return logChange(key, old, new)
    }

    private func logChange<T>(_ key: String, _ old: T, _ new: T) -> String {
        let line = "\(key): \(Self.show(old)) → \(Self.show(new))"
        Log.notice(.api, "MCP changed \(line)")
        return line
    }

    private static func show(_ value: Any) -> String {
        let m = Mirror(reflecting: value)
        if m.displayStyle == .optional { return m.children.first.map { show($0.value) } ?? "none" }
        if let s = value as? String { return "\"\(s)\"" }
        if let list = value as? [String] { return "[\(list.map { "\"\($0)\"" }.joined(separator: ", "))]" }
        return "\(value)"
    }

    nonisolated static func colorName(_ c: FinderTag.Color) -> String { c.name }

    /// Runs a PeelGoodCore check, as an API error.
    static func option<T>(_ check: () throws -> T) throws -> T {
        do { return try check() } catch let e as OptionError { throw APIError(e) }
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Compact JSON of a value, for the log.
    static func dump<T: Encodable>(_ value: T) -> String {
        (try? object(value)).map(json) ?? "\(value)"
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "missing \(key.stringValue)"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c): "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let c): "\(c.debugDescription) at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default: "\(error)"
        }
    }

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

    static func bool(_ v: Any, _ key: String) throws -> Bool {
        guard isBool(v), let b = v as? Bool else { throw APIError.badRequest("\(key) must be true or false.", code: "invalid_\(key)") }
        return b
    }

    static func number(_ v: Any, _ key: String, _ range: ClosedRange<Double>) throws -> Double {
        guard !isBool(v), let n = (v as? NSNumber)?.doubleValue, range.contains(n) else {
            throw APIError.badRequest("\(key) must be a number from \(range.lowerBound) to \(range.upperBound).", code: "invalid_\(key)")
        }
        return n
    }

    static func int(_ v: Any, _ key: String, _ range: ClosedRange<Int>) throws -> Int {
        guard !isBool(v), let d = (v as? NSNumber)?.doubleValue, d == d.rounded(), range.contains(Int(d)) else {
            throw APIError.badRequest("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).", code: "invalid_\(key)")
        }
        return Int(d)
    }

    static func string(_ v: Any, _ key: String, maxLength: Int = 1024) throws -> String {
        guard let s = v as? String, s.count <= maxLength else { throw APIError.badRequest("\(key) must be text.", code: "invalid_\(key)") }
        return s
    }

    static func strings(_ v: Any, _ key: String) throws -> [String] {
        guard let list = v as? [String] else { throw APIError.badRequest("\(key) must be a list of text.", code: "invalid_\(key)") }
        return list
    }

    static func color(_ v: Any, _ key: String) throws -> FinderTag.Color {
        if let s = v as? String, let c = FinderTag.Color.allCases.first(where: { colorName($0) == s.lowercased() }) { return c }
        if !isBool(v), let n = v as? Int, let c = FinderTag.Color(rawValue: n) { return c }
        throw APIError.badRequest("\(key) must be \(FinderTag.Color.allCases.map(colorName).joined(separator: ", ")).", code: "invalid_\(key)")
    }

    /// An existing folder, from an absolute path or one starting with ~.
    static func folder(_ v: Any, _ key: String) throws -> URL {
        let path = (try string(v, key) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw APIError.notFound("No folder at \(path).", code: "folder_not_found")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
