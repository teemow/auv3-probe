import SwiftUI

// AUMSessionInspectorView renders a parsed AUM project (AUMSessionMap) in the
// signalwave design language (see docs/signalwave.md). It mirrors
// AudioUnitInspectorView's "no obfuscation" style: header identity, an
// at-a-glance summary, the channel→node tree, the assigned MIDI mappings, and
// the literal raw JSON.
//
// The map is produced on-device by AUMSessionParser (a Swift port of the Go
// internal/aum read model), so inspection works with no daemon. Channel titles
// and node component sets are a private rig snapshot: shown in-UI, never logged
// or committed.

struct AUMSessionInspectorView: View {
    let entry: AUMSessionEntry
    let map: AUMSessionMap

    @Environment(\.dismiss) private var dismiss

    private var nodeCount: Int {
        map.channels.reduce(0) { $0 + ($1.nodes?.count ?? 0) }
    }
    private var enabledMappings: Int {
        map.mappings.filter(\.enabled).count
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
                        channelsSection
                        mappingsSection
                        RawAUMSessionJSONSection(map: map)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
            }
        }
        .tint(Signalwave.green)
        .preferredColorScheme(.dark)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(alignment: .center, spacing: 10) {
            WaveGlyph()
                .frame(width: 28, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("inspect")
                    .font(Signalwave.mono(.subheadline, weight: .bold))
                    .foregroundStyle(Signalwave.fg)
                Text("aum project · parsed on-device")
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.filename)
                .font(Signalwave.mono(.title3, weight: .bold))
                .foregroundStyle(Signalwave.fg)
                .textSelection(.enabled)

            FlowChips(chips: headerChips)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerChips: [String] {
        var chips: [String] = ["v\(map.version)"]
        chips.append(entry.isMidiMap ? "midimap" : "session")
        if entry.generated { chips.append("generated") }
        if let t = map.tempo, t > 0 { chips.append("\(formatNumber(t)) bpm") }
        return chips
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("summary")
            WrapLayout(spacing: 10, lineSpacing: 4) {
                statToken("channels", "\(map.channels.count)")
                statToken("nodes", "\(nodeCount)")
                statToken("mappings", "\(map.mappings.count)")
                if map.mappings.count != enabledMappings {
                    statToken("enabled", "\(enabledMappings)")
                }
                if let tempo = map.tempo, tempo > 0 {
                    statToken("tempo", "\(formatNumber(tempo))")
                }
            }
            .signalField()
        }
    }

    private func statToken(_ label: String, _ value: String, color: Color = Signalwave.fg) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(Signalwave.dim)
            Text(value).foregroundStyle(color).textSelection(.enabled)
        }
        .font(Signalwave.mono(.caption2, weight: .semibold))
    }

    // MARK: - Privacy note

    private var privacyNote: some View {
        Label {
            Text("channel/song names are installation-specific. parsed on-device and shown here only — never logged or committed to git.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(Signalwave.mono(.caption2))
        .foregroundStyle(Signalwave.dim)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Channels

    @ViewBuilder
    private var channelsSection: some View {
        Section {
            if map.channels.isEmpty {
                Text("// no channels in this project")
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(map.channels) { channel in
                        channelCard(channel)
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                SectionHeader("channels")
                Spacer()
                Text("\(map.channels.count)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            .padding(.vertical, 6)
            .background(Signalwave.bg)
        }
    }

    private func channelCard(_ channel: ChannelInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(channelTitle(channel))
                    .font(Signalwave.mono(.subheadline, weight: .semibold))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if channel.muted { SignalChip(text: "mute", color: Signalwave.amber) }
                if channel.soloed { SignalChip(text: "solo", color: Signalwave.green) }
            }

            Text(channelMeta(channel).joined(separator: " · "))
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim)
                .textSelection(.enabled)

            if let nodes = channel.nodes, !nodes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.element.slot) { idx, node in
                        if idx > 0 {
                            Rectangle().fill(Signalwave.grid).frame(height: 1)
                        }
                        nodeRow(node)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                )
            } else {
                Text("// no nodes")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Signalwave.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Signalwave.grid, lineWidth: 1)
        )
    }

    private func channelTitle(_ channel: ChannelInfo) -> String {
        if let t = channel.title, !t.isEmpty { return t }
        return "channel \(channel.index)"
    }

    private func channelMeta(_ channel: ChannelInfo) -> [String] {
        var meta: [String] = ["#\(channel.index)"]
        if !channel.kind.isEmpty { meta.append(channel.kind) }
        if let f = channel.faderLevel { meta.append("fader \(formatNumber(f))") }
        return meta
    }

    private func nodeRow(_ node: NodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(node.slot)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                    .frame(minWidth: 20, alignment: .leading)
                Text(node.label)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }

            if let component = node.component {
                let codes = [component.type, component.subtype, component.manufacturer]
                    .filter { !$0.isEmpty }
                    .joined(separator: "/")
                let extra = [codes, component.manufacturerName, component.version.map { "v\($0)" }]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !extra.isEmpty {
                    Text(extra)
                        .font(Signalwave.mono(.caption2))
                        .foregroundStyle(Signalwave.dim)
                        .textSelection(.enabled)
                        .padding(.leading, 28)
                }
            }

            if let main = node.auMainParam, !main.isEmpty {
                Text("main param · \(main)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim.opacity(0.8))
                    .textSelection(.enabled)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mappings

    @ViewBuilder
    private var mappingsSection: some View {
        Section {
            if map.mappings.isEmpty {
                Text("// no assigned mappings")
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.dim)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(map.mappings.enumerated()), id: \.offset) { idx, mapping in
                        if idx > 0 {
                            Rectangle().fill(Signalwave.grid).frame(height: 1)
                        }
                        mappingRow(mapping)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Signalwave.grid, lineWidth: 1)
                )
            }
        } header: {
            HStack(spacing: 8) {
                SectionHeader("mappings")
                Spacer()
                Text("\(map.mappings.count)")
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
            }
            .padding(.vertical, 6)
            .background(Signalwave.bg)
        }
    }

    private func mappingRow(_ mapping: MappingInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mapping.target.isEmpty ? "(unnamed target)" : mapping.target)
                    .font(Signalwave.mono(.caption))
                    .foregroundStyle(Signalwave.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if !mapping.enabled { SignalChip(text: "off", color: Signalwave.dim) }
                if mapping.autoToggle { SignalChip(text: "auto", color: Signalwave.green) }
            }

            if !mapping.collection.isEmpty {
                Text(mapping.collection)
                    .font(Signalwave.mono(.caption2))
                    .foregroundStyle(Signalwave.dim)
                    .textSelection(.enabled)
            }

            Text("type \(mapping.type) · data1 \(mapping.data1) · ch \(mapping.channel) · \(formatNumber(mapping.min))–\(formatNumber(mapping.max))")
                .font(Signalwave.mono(.caption2))
                .foregroundStyle(Signalwave.dim.opacity(0.85))
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

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
}

// MARK: - Raw JSON

/// The collapsible "raw json" section for an AUMSessionMap, encoded only on
/// reveal.
private struct RawAUMSessionJSONSection: View {
    let map: AUMSessionMap

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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else {
            return "// failed to encode session map"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
