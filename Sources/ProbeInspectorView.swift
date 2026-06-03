import SwiftUI

// ProbeInspectorView renders a single ProbeDump — the exact bytes a batch send
// would POST — in the signalwave design language (see docs/signalwave.md). It is
// a read-only "no obfuscation" view: header identity, an at-a-glance summary of
// what gets sent, a privacy note for installation-private user presets, the full
// group-sectioned parameter list, presets, and the literal raw JSON.
//
// Real dumps span 0 params to thousands (one file is ~1.8 MB with very long
// valueStrings), so the parameter list renders lazily, big valueStrings stay
// collapsed behind a count, and the raw JSON is only encoded when its disclosure
// is opened.

struct ProbeInspectorView: View {
    let dump: ProbeDump

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        ZStack {
            Signalwave.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                Divider().overlay(Signalwave.grid)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        header
                        summary
                        privacyNote
                        parameters
                        presets
                        RawJSONSection(dump: dump)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
    }

    // MARK: - Title bar (sheet chrome)

    private var titleBar: some View {
        HStack(alignment: .center, spacing: 10) {
            WaveGlyph()
                .frame(width: 28, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("inspect")
                    .font(Signalwave.mono(.subheadline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("local probe · not sent")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Label("close", systemImage: "xmark")
            }
            .buttonStyle(.signalGhost)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Header / component identity

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dump.name)
                .font(Signalwave.mono(.title3, weight: .bold))
                .foregroundStyle(Signalwave.fg)
                .textSelection(.enabled)

            if let short = dump.shortName, !short.isEmpty, short != dump.name {
                Text(short)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }

            let c = dump.component
            Text("\(c.type)/\(c.subtype)/\(c.manufacturer)")
                .font(Signalwave.mono(.subheadline, weight: .semibold))
                .foregroundStyle(Signalwave.green)
                .textSelection(.enabled)

            let extras = [c.manufacturerName, c.version.map { "v\($0)" }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !extras.isEmpty {
                Text(extras.joined(separator: " · "))
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary (what gets sent, at a glance)

    private var summary: some View {
        let params = dump.parameters
        let writable = params.lazy.filter(\.writable).count
        let nonFinite = params.lazy.filter { $0.nonFinite != nil }.count
        let factory = dump.factoryPresets?.count ?? 0
        let user = dump.userPresets?.count ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("summary")

            VStack(alignment: .leading, spacing: 6) {
                summaryRow("parameters", "\(params.count)")
                summaryRow("writable", "\(writable)")
                if nonFinite > 0 {
                    summaryRow("non-finite (sanitized)", "\(nonFinite)", color: Signalwave.amber)
                }
                summaryRow("factory presets", "\(factory)")
                summaryRow("user presets", "\(user)")
                if let caps = dump.channelCapabilities, !caps.isEmpty {
                    summaryRow("channel caps", formatChannelCaps(caps))
                }
                if let latency = dump.latency, latency != 0 {
                    summaryRow("latency", "\(formatNumber(latency)) s")
                }
                if let tail = dump.tailTime, tail != 0 {
                    summaryRow("tail time", "\(formatNumber(tail)) s")
                }
                if let supports = dump.supportsUserPresets {
                    summaryRow("supports user presets", supports ? "yes" : "no")
                }
            }
            .signalField()
        }
    }

    private func summaryRow(_ key: String, _ value: String, color: Color = Signalwave.fg) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(Signalwave.mono(.caption))
                .foregroundStyle(Signalwave.dim)
            Spacer(minLength: 8)
            Text(value)
                .font(Signalwave.mono(.caption, weight: .semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: - Privacy note

    private var privacyNote: some View {
        Label {
            Text("user-preset names are installation-specific. they only leave this device when you send to your own lan receiver — never committed to git.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(Signalwave.mono(.caption2))
        .foregroundStyle(Signalwave.dim)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Parameters

    private var filteredParameters: [ProbeParam] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return dump.parameters }
        return dump.parameters.filter { p in
            p.displayName.lowercased().contains(q)
                || p.keyPath.lowercased().contains(q)
                || p.identifier.lowercased().contains(q)
                || (p.group?.lowercased().contains(q) ?? false)
                || p.unit.lowercased().contains(q)
        }
    }

    /// Groups `params` by `group`, preserving first-appearance order; params
    /// with no group fall under a single "ungrouped" bucket appended last.
    private func grouped(_ params: [ProbeParam]) -> [(name: String, params: [ProbeParam])] {
        var order: [String] = []
        var buckets: [String: [ProbeParam]] = [:]
        let ungrouped = "ungrouped"
        for p in params {
            let key = (p.group?.isEmpty == false) ? p.group! : ungrouped
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(p)
        }
        // Keep the catch-all bucket last while preserving first-appearance order
        // for real groups (Array.sort is not guaranteed stable, so move by hand).
        if let idx = order.firstIndex(of: ungrouped), idx != order.count - 1 {
            order.remove(at: idx)
            order.append(ungrouped)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    @ViewBuilder
    private var parameters: some View {
        // Filter + group once per render: the worst-case dump has thousands of
        // params, so the result is reused by both the content and the header
        // count rather than recomputed for each.
        let filtered = filteredParameters
        let groups = grouped(filtered)

        Section {
            if dump.parameters.isEmpty {
                Text("// no parameters exposed by this plugin")
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.top, 4)
            } else {
                paramFilterField

                if filtered.isEmpty {
                    Text("// no parameters match “\(query)”")
                        .font(Signalwave.mono(.caption))
                        .foregroundStyle(Signalwave.dim)
                        .padding(.top, 4)
                } else {
                    ForEach(groups, id: \.name) { group in
                        paramGroup(group.name, params: group.params)
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                SectionHeader("parameters")
                Spacer()
                Text("\(filtered.count)/\(dump.parameters.count)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            .padding(.vertical, 6)
            .background(Signalwave.bg)
        }
    }

    private var paramFilterField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Signalwave.dim)
            TextField("filter params", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Signalwave.mono(.subheadline))
                .foregroundStyle(Signalwave.fg)
                .tint(Signalwave.green)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Signalwave.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .signalField()
    }

    @ViewBuilder
    private func paramGroup(_ name: String, params: [ProbeParam]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(name)
                    .font(Signalwave.mono(.caption, weight: .semibold))
                    .foregroundStyle(Signalwave.fg)
                Spacer()
                Text("\(params.count)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                ForEach(Array(params.enumerated()), id: \.element.address) { index, param in
                    if index > 0 {
                        Rectangle()
                            .fill(Signalwave.grid)
                            .frame(height: 1)
                    }
                    ParamRowView(param: param, formatNumber: formatNumber)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.grid, lineWidth: 1)
            )
        }
    }

    // MARK: - Presets

    @ViewBuilder
    private var presets: some View {
        let factory = dump.factoryPresets ?? []
        let user = dump.userPresets ?? []
        if !factory.isEmpty || !user.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("presets")
                if !factory.isEmpty {
                    presetList("factory", presets: factory, accent: Signalwave.green)
                }
                if !user.isEmpty {
                    presetList("user · on-device only", presets: user, accent: Signalwave.amber)
                }
            }
        }
    }

    private func presetList(_ label: String, presets: [ProbePreset], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("// \(label)")
                .font(Signalwave.mono(.caption2, weight: .semibold))
                .foregroundStyle(accent.opacity(0.85))
            VStack(spacing: 0) {
                ForEach(Array(presets.enumerated()), id: \.offset) { index, preset in
                    if index > 0 {
                        Rectangle().fill(Signalwave.grid).frame(height: 1)
                    }
                    HStack(spacing: 8) {
                        Text("\(preset.number)")
                            .font(Signalwave.mono(.caption2))
                            .foregroundStyle(Signalwave.dim)
                            .frame(minWidth: 28, alignment: .leading)
                        Text(preset.name)
                            .font(Signalwave.mono(.caption))
                            .foregroundStyle(Signalwave.fg)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Signalwave.grid, lineWidth: 1)
            )
        }
    }

    // MARK: - Formatting helpers

    /// Renders a Double tersely: integral values lose their ".0", others keep up
    /// to 6 significant-ish digits with trailing zeros trimmed.
    private func formatNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var s = String(format: "%.6g", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private func formatChannelCaps(_ caps: [Int]) -> String {
        // Flattened [in, out] pairs; -1 means "any".
        func token(_ v: Int) -> String { v == -1 ? "any" : "\(v)" }
        var pairs: [String] = []
        var i = 0
        while i + 1 < caps.count {
            pairs.append("\(token(caps[i]))→\(token(caps[i + 1]))")
            i += 2
        }
        if i < caps.count { pairs.append(token(caps[i])) }
        return pairs.joined(separator: ", ")
    }
}

// MARK: - Raw JSON

/// The collapsible "raw json" section, isolated into its own view so toggling it
/// open/closed only re-renders this subtree — not the parent's filtered/grouped
/// parameter list (which is O(params) and costly on the ~1.8 MB worst case). The
/// dump is encoded only when revealed.
private struct RawJSONSection: View {
    let dump: ProbeDump

    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showRaw.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showRaw ? "chevron.down" : "chevron.right")
                    SectionHeader("raw json")
                    Spacer()
                    Text(showRaw ? "hide" : "show")
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                }
            }
            .buttonStyle(.plain)

            if showRaw {
                Text(rawJSONString)
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Signalwave.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Signalwave.grid, lineWidth: 1)
                    )
            }
        }
    }

    private var rawJSONString: String {
        guard let data = try? dump.encoded() else {
            return "// failed to encode dump"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Parameter row

/// One parameter, rendered as a compact capture-style entry. Long valueStrings
/// stay collapsed behind a count (`indexed · N values`) and only render when
/// tapped, so a plugin with thousands of long strings does not blow up the list.
private struct ParamRowView: View {
    let param: ProbeParam
    let formatNumber: (Double) -> String

    @State private var showValueStrings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(param.displayName.isEmpty ? param.keyPath : param.displayName)
                    .font(Signalwave.mono(.subheadline))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                accessBadges
            }

            if !param.keyPath.isEmpty && param.keyPath != param.displayName {
                Text(param.keyPath)
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Text("\(formatNumber(param.min))–\(formatNumber(param.max))")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                Text("= \(formatNumber(param.value))")
                    .font(Signalwave.mono(.caption2, weight: .semibold))
                    .foregroundStyle(Signalwave.green)
                if let unitLabel = unitLabel {
                    Text(unitLabel)
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                }
            }
            .textSelection(.enabled)

            if !flagChips.isEmpty {
                FlowChips(chips: flagChips)
            }

            if let nf = param.nonFinite {
                chip("non-finite · \(nf)", color: Signalwave.amber)
            }

            valueStringsView

            metaLine
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessBadges: some View {
        HStack(spacing: 4) {
            Text(param.writable ? "[w]" : "[-]")
                .foregroundStyle(param.writable ? Signalwave.green : Signalwave.dim)
            Text(param.readable ? "[r]" : "[-]")
                .foregroundStyle(param.readable ? Signalwave.green : Signalwave.dim)
        }
        .font(Signalwave.mono(.caption2, weight: .bold))
    }

    private var unitLabel: String? {
        let name = param.unitName?.isEmpty == false ? param.unitName! : nil
        if let name = name { return "\(param.unit) · \(name)" }
        return param.unit.isEmpty ? nil : param.unit
    }

    private var flagChips: [String] {
        var chips: [String] = []
        if param.displayLogarithmic == true { chips.append("log") }
        if param.displayExponential == true { chips.append("exp") }
        if param.isHighResolution == true { chips.append("hi-res") }
        if param.isRampable == true { chips.append("ramp") }
        if param.isMeta == true { chips.append("meta") }
        if let deps = param.dependentParameters, !deps.isEmpty {
            chips.append("deps:\(deps.count)")
        }
        return chips
    }

    @ViewBuilder
    private var valueStringsView: some View {
        if let values = param.valueStrings, !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showValueStrings.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showValueStrings ? "chevron.down" : "chevron.right")
                        Text("indexed · \(values.count) values")
                    }
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                }
                .buttonStyle(.plain)

                if showValueStrings {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            Text("\(index): \(value)")
                                .font(Signalwave.mono(.caption2))
                                .foregroundStyle(Signalwave.fg)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let flags = param.flags.map { "flags:0x\(String($0, radix: 16))" }
        let addr = "addr:\(param.address)"
        let parts = [addr, flags].compactMap { $0 }
        Text(parts.joined(separator: " · "))
            .font(Signalwave.mono(.caption2))
            .foregroundStyle(Signalwave.dim.opacity(0.7))
            .textSelection(.enabled)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Signalwave.mono(.caption2, weight: .semibold))
            .foregroundStyle(color)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
    }
}

// MARK: - Flow-wrapping chip row

/// A wrapping row of small chips backed by a flexible `WrapLayout` (iOS 16
/// `Layout`); kept tiny so flag chips wrap cleanly on narrow parameter rows.
private struct FlowChips: View {
    let chips: [String]

    var body: some View {
        WrapLayout(spacing: 6, lineSpacing: 4) {
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(Signalwave.mono(.caption2, weight: .semibold))
                    .foregroundStyle(Signalwave.green.opacity(0.9))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Signalwave.green.opacity(0.4), lineWidth: 1)
                    )
            }
        }
    }
}

/// Minimal flow layout that wraps subviews to the available width.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
