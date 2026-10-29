import Foundation

/// The page at `GET /`: the OpenAPI description as plain HTML. Self-contained, no scripts from elsewhere.
enum DocsPage {
    static func html(port: Int) -> String {
        let sections = OpenAPI.tags.map { tag in
            "<h2>\(esc(tag))</h2>\n" + OpenAPI.endpoints.filter { $0.tag == tag }.map { endpoint($0, port: port) }.joined(separator: "\n")
        }.joined(separator: "\n")
        let schemas = OpenAPI.components.map { name, schema in
            "<details class=\"schema\" id=\"schema-\(esc(name))\"><summary>\(esc(name))</summary>\(fields(schema))</details>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Peel Good Inc. API</title>
        <style>\(css)</style>
        </head>
        <body>
        <header>
        <h1>Peel Good Inc. API</h1>
        <p>Version \(esc(OpenAPI.appVersion)). Listens on <code>\(OpenAPI.baseURL(port: port))</code> only.</p>
        <p>Every request except this page and <a href="/openapi.json">openapi.json</a> needs the token in
        <code>~/Library/Application Support/Labelize/token</code>:</p>
        <pre>curl -s \(esc(OpenAPI.authHeader)) \(OpenAPI.baseURL(port: port))/v1/health</pre>
        <p>Only files sent with a request print: up to \(APILimits.maxFiles) files of \(APILimits.maxFileBytes / 1_048_576) MB,
        \(APILimits.maxLabels) pages in all, and \(APILimits.printsPerMinute) prints or previews a minute.
        Files on this Mac, the clipboard and reprinting aren't available over HTTP.</p>
        <p>Requests with an <code>Origin</code> header are refused, so web pages can't call the API.
        MCP clients connect to <code>\(OpenAPI.baseURL(port: port))/mcp</code> with the same token.</p>
        </header>
        <main>
        \(sections)
        <h2>Schemas</h2>
        \(schemas)
        </main>
        </body>
        </html>
        """
    }

    private static func endpoint(_ e: OpenAPI.Endpoint, port: Int) -> String {
        var out = "<section class=\"op\" id=\"\(esc(e.operationID))\">"
        out += "<div class=\"line\"><span class=\"verb \(e.verb.rawValue.lowercased())\">\(e.verb.rawValue)</span>"
        out += "<code class=\"path\">\(esc(e.path))</code><span class=\"summary\">\(esc(e.summary))</span></div>"
        out += "<p>\(esc(e.detail))\(e.authenticated ? "" : " <em>No token needed.</em>")</p>"
        if !e.parameters.isEmpty {
            out += "<h4>Parameters</h4><table>"
            for p in e.parameters {
                out += "<tr><td><code>\(esc(p.name))</code></td><td>\(p.location.rawValue)\(p.required ? ", required" : "")</td>"
                out += "<td>\(esc(p.schema.typeName))</td><td>\(esc(p.schema.summary ?? ""))</td></tr>"
            }
            out += "</table>"
        }
        if !e.body.isEmpty {
            out += "<h4>Request body</h4>"
            for c in e.body { out += "<p><code>\(esc(c.mediaType))</code> \(link(c.schema))</p>" }
        }
        out += "<h4>Responses</h4><table>"
        for r in e.responses {
            let types = r.content.map { "<code>\(esc($0.mediaType))</code> \(link($0.schema))" }.joined(separator: "<br>")
            out += "<tr><td>\(r.status)</td><td>\(esc(r.description))</td><td>\(types)</td></tr>"
        }
        out += "</table>"
        for (title, command) in OpenAPI.curl(e, port: port) {
            out += "<h4>\(title.isEmpty ? "Example" : "Example: " + esc(title))</h4><pre>\(esc(command))</pre>"
        }
        if let ex = OpenAPI.responseExample(e) {
            out += "<details><summary>Response example</summary><pre>\(esc(ex))</pre></details>"
        }
        return out + "</section>"
    }

    private static func link(_ s: OpenAPI.Schema) -> String {
        switch s {
        case .ref(let name): "<a href=\"#schema-\(esc(name))\">\(esc(name))</a>"
        case .array(.ref(let name), _): "array of <a href=\"#schema-\(esc(name))\">\(esc(name))</a>"
        default: esc(s.typeName)
        }
    }

    private static func fields(_ s: OpenAPI.Schema) -> String {
        let rows = s.fields.map { f in
            "<tr><td><code>\(esc(f.name))</code>\(f.required ? "" : " <span class=\"opt\">optional</span>")</td><td>\(link(f.schema))</td><td>\(esc(f.schema.summary ?? ""))</td></tr>"
        }
        return "<p>\(esc(s.summary ?? ""))</p><table>\(rows.joined())</table>"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --code: #f5f5f7; }
    @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --line: #424245; --code: #1c1c1e; } }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--fg); max-width: 900px; margin: 0 auto; padding: 24px; }
    h1 { font-size: 28px; margin: 0 0 8px; } h2 { margin-top: 36px; border-bottom: 1px solid var(--line); padding-bottom: 4px; }
    h4 { margin: 14px 0 4px; font-size: 12px; text-transform: uppercase; color: var(--muted); letter-spacing: .04em; }
    code, pre { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
    pre { background: var(--code); padding: 10px 12px; border-radius: 8px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
    .op { border: 1px solid var(--line); border-radius: 10px; padding: 12px 16px; margin: 14px 0; }
    .line { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
    .verb { font: 600 11px ui-monospace, monospace; color: #fff; border-radius: 5px; padding: 2px 7px; }
    .get { background: #28a745; } .post { background: #0a84ff; } .put { background: #ff9f0a; } .delete { background: #ff3b30; }
    .path { font-size: 14px; font-weight: 600; } .summary { color: var(--muted); }
    table { border-collapse: collapse; width: 100%; } td { border-top: 1px solid var(--line); padding: 4px 8px 4px 0; vertical-align: top; }
    .opt { color: var(--muted); font-size: 11px; } details.schema { margin: 8px 0; } summary { cursor: pointer; font-weight: 600; }
    a { color: #0a84ff; text-decoration: none; }
    """
}
