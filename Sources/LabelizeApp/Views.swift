import AppKit
import LabelKit
import SwiftUI
import UniformTypeIdentifiers

/// The label as it will print, on a slightly raised white card.
struct LabelCard: View {
    let image: NSImage
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

struct JobView: View {
    @ObservedObject var job: PrintJob
    let sizes: [LabelSize]

    var body: some View {
        VStack(spacing: 14) {
            preview
            VStack(spacing: 4) {
                Text(job.labels.isEmpty ? "Preparing…" : job.title).font(.headline)
                HStack(spacing: 6) {
                    Text(job.printer.displayName)
                    if let codes = job.codeSummary {
                        let ok = job.labels.allSatisfy { $0.missingCodes.isEmpty }
                        Label(codes, systemImage: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ok ? .green : .orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(job.warnings, id: \.self) { w in
                    Text(w).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            footer
        }
        .padding(18)
        .frame(width: 300, height: 520, alignment: .top)
        .animation(.snappy, value: job.phase)
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            if let first = job.previews.first {
                ForEach(Array(job.previews.prefix(3).enumerated().reversed()), id: \.offset) { i, img in
                    LabelCard(image: img)
                        .rotationEffect(.degrees(Double(i) * 3))
                        .offset(x: CGFloat(i) * 6, y: CGFloat(i) * -4)
                        .opacity(i == 0 ? 1 : 0.9)
                }
                .id(first)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(height: 280)
        .overlay {
            if job.phase == .done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch job.phase {
        case .composing:
            ProgressView().controlSize(.small)
        case .review:
            VStack(spacing: 10) {
                LabeledContent("Size") {
                    SizePopUp(selection: Binding(get: { job.options.size }, set: { s in job.update { $0.size = s } }), sizes: sizes)
                }
                Picker("Fit", selection: Binding(get: { job.options.fit }, set: { f in job.update { $0.fit = f } })) {
                    Text("Fit").tag(FitMode.fit)
                    Text("Fill").tag(FitMode.fill)
                }.pickerStyle(.segmented)
                Picker("Ink", selection: Binding(get: { job.options.ink }, set: { i in job.update { $0.ink = i } })) {
                    Text("Auto").tag(InkMode.auto)
                    Text("Crisp").tag(InkMode.crisp)
                    Text("Photo").tag(InkMode.photo)
                    Text("Halftone").tag(InkMode.halftone)
                }.pickerStyle(.segmented)
                HStack {
                    Button("Cancel", role: .cancel) { job.cancel() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Print") { Task { await job.send() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        case .countdown:
            HStack(spacing: 10) {
                ProgressView(value: job.progress).progressViewStyle(.linear)
                Button("Cancel") { job.cancel() }.keyboardShortcut(.cancelAction)
            }
        case .printing:
            Label("Sending to printer…", systemImage: "printer").font(.callout).foregroundStyle(.secondary)
        case .done:
            Label("Sent", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
                Button("Close") { job.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}

/// Shown while dragging over the icon when more than one printer can take labels.
struct DropZonesView: View {
    let printers: [PrinterInfo]
    let current: String?
    let sizeFor: (PrinterInfo) -> LabelSize
    let onDrop: ([URL], PrinterInfo) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("Drop on a printer").font(.headline)
            HStack(spacing: 10) {
                ForEach(printers, id: \.name) { p in
                    DropTile(printer: p, size: sizeFor(p), isCurrent: p.name == current) { onDrop($0, p) }
                }
            }
        }
        .padding(16)
    }
}

struct DropTile: View {
    let printer: PrinterInfo
    let size: LabelSize
    let isCurrent: Bool
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: printer.isLabelPrinter ? "printer.dotmatrix.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 28))
            Text(printer.displayName).font(.caption.weight(.medium)).lineLimit(1)
            Text(printer.isLabelPrinter ? size.display : "\(size.display) · color").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 120, height: 96)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : isCurrent ? .secondary.opacity(0.5) : .clear, lineWidth: 2))
        .scaleEffect(targeted ? 1.06 : 1)
        .animation(.spring(duration: 0.25), value: targeted)
        .onDrop(of: [.fileURL, .pdf, .svg, .image], isTargeted: $targeted) { providers in
            Task { @MainActor in
                let files = await Intake.files(from: providers)
                if !files.isEmpty { onDrop(files) }
            }
            return true
        }
    }
}

/// Finder's tag colors as a row of dots, like the Tags menu in Finder.
struct TagColorDots: View {
    @Binding var color: FinderTag.Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(FinderTag.Color.allCases, id: \.self) { c in
                Button { color = c } label: {
                    ZStack {
                        if c == .none {
                            Circle().strokeBorder(Color.secondary, lineWidth: 1)
                        } else {
                            Circle().fill(c.swatch)
                        }
                        if c == color {
                            Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2).padding(-3)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .padding(3)
                }
                .buttonStyle(.plain)
                .help(c == .none ? "No color" : c.title)
                .accessibilityLabel(c == .none ? "No color" : c.title)
            }
        }
    }
}
