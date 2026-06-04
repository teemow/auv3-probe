import SwiftUI
import ProbeKit

// AudioUnitInspectorView renders one audio unit's details (AudioUnitDetails) —
// the exact bytes a batch send would POST — in the signalwave design language
// (see docs/signalwave.md). It is a read-only "no obfuscation" view: header
// identity, an at-a-glance summary of what gets sent, a privacy note for
// installation-private user presets, the full group-sectioned parameter list,
// presets, and the literal raw JSON.
//
// Real records span 0 params to thousands (one is ~1.8 MB with very long
// valueStrings), so the parameter list renders lazily, big valueStrings stay
// collapsed behind a count, and the raw JSON is only encoded when revealed.

struct AudioUnitInspectorView: View {
    let details: AudioUnitDetails

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var focus: Focus = .all

    /// Optional "isolate" lens set by tapping a chip in the summary.
    enum Focus: Equatable {
        case all
        case group(String)
        case factoryPresets
        case userPresets
    }

    private var showsParameters: Bool {
        switch focus {
        case .all, .group: return true
        case .factoryPresets, .userPresets: return false
        }
    }

    private var showsPresets: Bool {
        switch focus {
        case .all, .factoryPresets, .userPresets: return true
        case .group: return false
        }
    }

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
                        if showsParameters { parameters }
                        if showsPresets { presets }
                        RawJSONSection(details: details)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
    }

    private func toggleFocus(_ target: Focus) {
        focus = (focus == target) ? .all : target
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
                Text("read locally · not sent")
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
            Text(details.name)
                .font(Signalwave.mono(.title3, weight: .bold))
                .foregroundStyle(Signalwave.fg)
                .textSelection(.enabled)

            if let short = details.shortName, !short.isEmpty, short != details.name {
                Text(short)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }

            let c = details.component
            let extras = [c.typeName, c.manufacturerName, c.version.map { "v\($0)" }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !extras.isEmpty {
                Text(extras.joined(separator: " · "))
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }

            if let tags = details.component.tags, !tags.isEmpty {
                FlowChips(chips: tags)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary (what gets sent, at a glance)

    private var summary: some View {
        let params = details.parameters
        let writable = params.lazy.filter(\.writable).count
        let nonFinite = params.lazy.filter { $0.nonFinite != nil }.count
        let factory = details.factoryPresets?.count ?? 0
        let user = details.userPresets?.count ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("summary")

            VStack(alignment: .leading, spacing: 10) {
                WrapLayout(spacing: 10, lineSpacing: 4) {
                    statToken("params", "\(params.count)")
                    statToken("writable", "\(writable)")
                    if nonFinite > 0 {
                        statToken("non-finite", "\(nonFinite)", color: Signalwave.amber)
                    }
                    if let caps = details.channelCapabilities, !caps.isEmpty {
                        statToken("caps", formatChannelCaps(caps))
                    }
                    if let latency = details.latency, latency != 0 {
                        statToken("latency", "\(formatNumber(latency))s")
                    }
                    if let tail = details.tailTime, tail != 0 {
                        statToken("tail", "\(formatNumber(tail))s")
                    }
                    if let supports = details.supportsUserPresets {
                        statToken("user presets", supports ? "yes" : "no")
                    }
                }

                if hasFilterChips {
                    WrapLayout(spacing: 6, lineSpacing: 6) {
                        if groupChips.count > 1 {
                            ForEach(groupChips, id: \.name) { item in
                                filterChip("\(item.name) (\(item.count))",
                                           accent: Signalwave.green,
                                           isActive: focus == .group(item.name)) {
                                    toggleFocus(.group(item.name))
                                }
                            }
                        }
                        if factory > 0 {
                            filterChip("factory (\(factory))",
                                       accent: Signalwave.green,
                                       isActive: focus == .factoryPresets) {
                                toggleFocus(.factoryPresets)
                            }
                        }
                        if user > 0 {
                            filterChip("user (\(user))",
                                       accent: Signalwave.amber,
                                       isActive: focus == .userPresets) {
                                toggleFocus(.userPresets)
                            }
                        }
                    }
                }
            }
            .signalField()
        }
    }

    private var hasFilterChips: Bool {
        groupChips.count > 1
            || details.factoryPresets?.isEmpty == false
            || details.userPresets?.isEmpty == false
    }

    private var groupChips: [(name: String, count: Int)] {
        grouped(details.parameters).map { ($0.name, $0.params.count) }
    }

    private func statToken(_ label: String, _ value: String, color: Color = Signalwave.fg) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Signalwave.dim)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .font(Signalwave.mono(.caption2, weight: .semibold))
    }

    private func filterChip(_ title: String, accent: Color, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Signalwave.mono(.caption2, weight: .semibold))
                .foregroundStyle(isActive ? Signalwave.bg : accent)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isActive ? accent : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(accent.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Privacy note

    private var privacyNote: some View {
        Label {
            Text("user-preset names are installation-specific. they only leave this device when you send to your own mcp-midi-controller on the lan — never committed to git.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(Signalwave.mono(.caption2))
        .foregroundStyle(Signalwave.dim)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Parameters

    private static let ungroupedKey = "ungrouped"

    private func groupKey(_ p: ParameterInfo) -> String {
        (p.group?.isEmpty == false) ? p.group! : Self.ungroupedKey
    }

    private var filteredParameters: [ParameterInfo] {
        var params = details.parameters
        if case .group(let g) = focus {
            params = params.filter { groupKey($0) == g }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return params }
        return params.filter { p in
            p.displayName.lowercased().contains(q)
                || p.keyPath.lowercased().contains(q)
                || p.identifier.lowercased().contains(q)
                || (p.group?.lowercased().contains(q) ?? false)
                || p.unit.lowercased().contains(q)
        }
    }

    private func grouped(_ params: [ParameterInfo]) -> [(name: String, params: [ParameterInfo])] {
        var order: [String] = []
        var buckets: [String: [ParameterInfo]] = [:]
        for p in params {
            let key = groupKey(p)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(p)
        }
        if let idx = order.firstIndex(of: Self.ungroupedKey), idx != order.count - 1 {
            order.remove(at: idx)
            order.append(Self.ungroupedKey)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    @ViewBuilder
    private var parameters: some View {
        let filtered = filteredParameters
        let groups = grouped(filtered)

        Section {
            if details.parameters.isEmpty {
                Text("// no parameters exposed by this audio unit")
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
                Text("\(filtered.count)/\(details.parameters.count)")
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
    private func paramGroup(_ name: String, params: [ParameterInfo]) -> some View {
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
                    ParameterRowView(param: param, formatNumber: formatNumber)
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
        let factory = details.factoryPresets ?? []
        let user = details.userPresets ?? []
        let showFactory = !factory.isEmpty && focus != .userPresets
        let showUser = !user.isEmpty && focus != .factoryPresets
        if showFactory || showUser {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("presets")
                if showFactory {
                    presetList("factory", presets: factory, accent: Signalwave.green)
                }
                if showUser {
                    presetList("user · on-device only", presets: user, accent: Signalwave.amber)
                }
            }
        }
    }

    private func presetList(_ label: String, presets: [PresetInfo], accent: Color) -> some View {
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
/// open/closed only re-renders this subtree. The details are encoded only on
/// reveal.
private struct RawJSONSection: View {
    let details: AudioUnitDetails

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
        guard let data = try? details.encoded() else {
            return "// failed to encode details"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Parameter row

/// One parameter, rendered as a compact capture-style entry. Long valueStrings
/// stay collapsed behind a count and only render when tapped.
private struct ParameterRowView: View {
    let param: ParameterInfo
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
                SignalChip(text: "non-finite · \(nf)", color: Signalwave.amber)
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
}
