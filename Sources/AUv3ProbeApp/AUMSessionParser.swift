import Foundation
import ProbeKit

// On-device reader for AUM sessions (.aumproj) and standalone MIDI mappings
// (.aum_midimap). It decodes the NSKeyedArchiver graph (BinaryPlist.swift) and
// walks it into the same flat AUMSessionMap the inspector renders — so the app
// reads and inspects sessions entirely locally, without the daemon.
//
// This is a faithful port of the Go read model in the mcp-midi-controller repo
// (internal/aum: archive.go, session.go, spec.go, midimap.go). The graph walk,
// the two container shapes (keyed-object dict vs Foundation NS.keys/NS.objects),
// the component-blob decode and the two mapping-leaf encodings all mirror that
// reference implementation. The Go library remains the source of truth for the
// format; this is the read-only subset the iPad needs.
//
// Privacy: titles, channel names and node component sets are an installation
// snapshot. They are rendered in-UI but never logged or committed.

enum AUMParseError: LocalizedError {
    case notArchive

    var errorDescription: String? {
        switch self {
        case .notArchive:
            return "not an AUM session archive (missing $objects/$top)"
        }
    }
}

/// Parses `.aumproj` / `.aum_midimap` bytes into an `AUMSessionMap`.
enum AUMSessionParser {
    static func parse(data: Data, isMidiMap: Bool) throws -> AUMSessionMap {
        let archive = try AUMArchive(data: data)
        return archive.sessionMap(preferMidiMap: isMidiMap)
    }
}

/// A decoded NSKeyedArchiver graph: the flat `$objects` table plus `$top`. UIDs
/// elsewhere in the graph index `objects`; `deref` resolves them on demand.
struct AUMArchive {
    let objects: [PlistValue]
    let top: [String: PlistValue]

    init(data: Data) throws {
        let root = try BinaryPlistDecoder.decode(data)
        guard case .dict(let r) = root,
              case .array(let objs)? = r["$objects"] else {
            throw AUMParseError.notArchive
        }
        objects = objs
        if case .dict(let t)? = r["$top"] {
            top = t
        } else {
            top = [:]
        }
    }

    // MARK: - Graph helpers (mirroring session.go)

    /// Resolve `v` to a concrete value, following a `.uid` into `objects`.
    func deref(_ v: PlistValue?) -> PlistValue {
        guard let v = v else { return .null }
        if case .uid(let i) = v {
            return (i >= 0 && i < objects.count) ? objects[i] : .null
        }
        return v
    }

    /// The dereferenced `$top["root"]` — the AUMSession for a session, or the
    /// collection dict for a standalone map.
    var root: PlistValue { deref(top["root"]) }

    /// The `$classname` of a resolved object, or "" if none.
    func className(_ v: PlistValue) -> String {
        guard case .dict(let m) = deref(v),
              case .dict(let cls) = deref(m["$class"]) else { return "" }
        if case .string(let name) = (cls["$classname"] ?? .null) { return name }
        return ""
    }

    /// Resolve `v` to a string→value map, transparently unwrapping a Foundation
    /// NSDictionary (NS.keys / NS.objects) into a plain map. Returned values are
    /// raw (a `.uid` or inline scalar) and must be dereferenced on use.
    func dict(_ v: PlistValue?) -> [String: PlistValue]? {
        guard case .dict(let m) = deref(v) else { return nil }
        if case .array(let keys) = (m["NS.keys"] ?? .null),
           case .array(let objs) = (m["NS.objects"] ?? .null) {
            var out = [String: PlistValue]()
            for i in 0..<min(keys.count, objs.count) {
                if case .string(let k) = deref(keys[i]), !k.isEmpty {
                    out[k] = objs[i]
                }
            }
            return out
        }
        return m
    }

    /// Resolve `v` to an array, unwrapping an NSArray (NS.objects). Elements are
    /// raw (UIDs or inline).
    func array(_ v: PlistValue?) -> [PlistValue] {
        let obj = deref(v)
        if case .dict(let m) = obj {
            if case .array(let objs) = (m["NS.objects"] ?? .null) { return objs }
            return []
        }
        if case .array(let arr) = obj { return arr }
        return []
    }

    func str(_ v: PlistValue?) -> String {
        if case .string(let s) = deref(v) { return s == "$null" ? "" : s }
        return ""
    }

    func bool(_ v: PlistValue?) -> Bool {
        if case .bool(let b) = deref(v) { return b }
        return false
    }

    func floatValue(_ v: PlistValue?) -> Double? {
        switch deref(v) {
        case .real(let f): return f
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    func intOr(_ v: PlistValue?, _ def: Int) -> Int {
        switch deref(v) {
        case .int(let i): return Int(i)
        case .real(let f): return Int(f)
        default: return def
        }
    }

    // MARK: - Session map

    /// Build the flat session map. Auto-detects a full session (carries
    /// `channels` / `midiCtrlState`) vs a standalone collection; `preferMidiMap`
    /// only tips the ambiguous case (an empty/odd root).
    func sessionMap(preferMidiMap: Bool) -> AUMSessionMap {
        let rootDict = dict(root) ?? [:]
        let looksLikeSession = rootDict["channels"] != nil || rootDict["midiCtrlState"] != nil
        let looksLikeMidiMap = rootDict["_collection_map_name"] != nil

        if looksLikeSession || (!looksLikeMidiMap && !preferMidiMap) {
            return fullSessionMap(rootDict)
        }
        return midiMapAsSessionMap(rootDict)
    }

    private func fullSessionMap(_ rootDict: [String: PlistValue]) -> AUMSessionMap {
        let version = intOr(rootDict["version"], 0)
        var tempo: Double?
        if let clock = dict(rootDict["transportClockState"]),
           let t = floatValue(clock["clockTempo"]), t > 0 {
            tempo = t
        }

        let strips = array(rootDict["channels"])
        let nodeArchives = array(rootDict["nodeArchives"])

        var channels = [ChannelInfo]()
        for (i, stripRef) in strips.enumerated() {
            guard let obj = dict(stripRef) else { continue }
            let nodes = i < nodeArchives.count ? nodesAt(nodeArchives[i]) : []
            channels.append(ChannelInfo(
                index: intOr(obj["index"], i),
                kind: channelKind(stripRef),
                title: nonEmpty(str(obj["title"])),
                faderLevel: floatValue(obj["faderLevel"]),
                muted: bool(obj["muted"]),
                soloed: bool(obj["soloed"]),
                nodes: nodes.isEmpty ? nil : nodes
            ))
        }

        var mappings = [MappingInfo]()
        if let ctrl = dict(rootDict["midiCtrlState"]) {
            walkMappings(ctrl, path: "", into: &mappings)
        }
        sortMappings(&mappings)

        let routes = parseRoutes(rootDict)

        return AUMSessionMap(version: version, tempo: tempo, channels: channels,
                             mappings: mappings, routes: routes)
    }

    private func midiMapAsSessionMap(_ rootDict: [String: PlistValue]) -> AUMSessionMap {
        let metaKeys: Set<String> = ["_collection_map_name", "_collection_editor_states", "Force Link Tempo"]
        var mappings = [MappingInfo]()
        for (key, val) in rootDict where !metaKeys.contains(key) {
            guard let child = dict(val), let leaf = readLeaf(child, collection: "", target: key) else { continue }
            mappings.append(leaf)
        }
        sortMappings(&mappings)
        return AUMSessionMap(version: intOr(rootDict["version"], 0), tempo: nil,
                             channels: [], mappings: mappings, routes: [])
    }

    private func channelKind(_ stripRef: PlistValue) -> String {
        switch className(stripRef) {
        case "AUMAudioStrip": return "audio"
        case "AUMMIDIStrip": return "midi"
        default: return ""
        }
    }

    private func nodesAt(_ v: PlistValue) -> [NodeInfo] {
        var out = [NodeInfo]()
        for (slot, ev) in array(v).enumerated() {
            guard let obj = dict(ev) else { continue }
            let descClass = nonEmpty(str(obj["archiveDescClass"]))
            let componentName = nonEmpty(str(obj["componentName"]))
            let component = decodeComponent(obj["audioComponentDescription"])

            // Drop empty slots: AUM pads each chain with placeholder nodes that
            // carry no class, component or name. They add only noise ("node 3").
            if descClass == nil && component == nil && componentName == nil { continue }

            var auMainParam: String?
            if let state = dict(obj["archiveNodeState"]) {
                auMainParam = nonEmpty(str(state["AuMainParam"]))
            }
            out.append(NodeInfo(
                slot: slot,
                archiveDescClass: descClass,
                componentName: componentName,
                component: component,
                auMainParam: auMainParam,
                busIndex: optInt(obj["busIndex"]),
                hwBusIndex: optInt(obj["hwBusIndex"]),
                monoSelect: optInt(obj["monoSelect"])
            ))
        }
        return out
    }

    /// Resolve `v` to an Int only when it is actually present as a number.
    private func optInt(_ v: PlistValue?) -> Int? {
        switch deref(v) {
        case .int(let i): return Int(i)
        case .real(let f): return Int(f)
        default: return nil
        }
    }

    // MARK: - MIDI routing (midiMatrixState)

    /// Parse AUM's MIDI routing matrix into source→destination edges. The matrix
    /// is `connections` (source key → [destination keys]) plus `sourcesInfo` /
    /// `destsInfo` ([displayName, category, …] per endpoint) and user
    /// `customNames`.
    private func parseRoutes(_ rootDict: [String: PlistValue]) -> [MidiRoute] {
        guard let matrix = dict(rootDict["midiMatrixState"]),
              let connections = dict(matrix["connections"]) else { return [] }
        let sourcesInfo = dict(matrix["sourcesInfo"]) ?? [:]
        let destsInfo = dict(matrix["destsInfo"]) ?? [:]
        let customNames = dict(matrix["customNames"]) ?? [:]

        var routes = [MidiRoute]()
        for (srcKey, destsRef) in connections {
            let src = endpoint(key: srcKey, info: sourcesInfo[srcKey], custom: customNames[srcKey])
            for destRef in array(destsRef) {
                let destKey = str(destRef)
                guard !destKey.isEmpty else { continue }
                let dst = endpoint(key: destKey, info: destsInfo[destKey], custom: customNames[destKey])
                routes.append(MidiRoute(
                    source: src.name, sourceCategory: src.category,
                    destination: dst.name, destinationCategory: dst.category
                ))
            }
        }
        routes.sort {
            if $0.source != $1.source {
                return $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending
            }
            return $0.destination.localizedCaseInsensitiveCompare($1.destination) == .orderedAscending
        }
        return routes
    }

    /// Resolve an endpoint's display name + category from its info array
    /// (`[name, category, …]`), a user custom name, or — as a last resort — the
    /// `Type:Name` key itself.
    private func endpoint(key: String, info: PlistValue?, custom: PlistValue?) -> (name: String, category: String) {
        let infoArr = array(info)
        var name = infoArr.count > 0 ? str(infoArr[0]) : ""
        let category = infoArr.count > 1 ? str(infoArr[1]) : ""
        let customName = str(custom)
        if !customName.isEmpty { name = customName }
        if name.isEmpty {
            if let colon = key.firstIndex(of: ":") {
                name = String(key[key.index(after: colon)...])
                return (name, category.isEmpty ? endpointType(String(key[..<colon])) : category)
            }
            name = key
        }
        return (name, category)
    }

    /// Friendly label for an endpoint key prefix (used only when info/category
    /// is missing).
    private func endpointType(_ prefix: String) -> String {
        switch prefix {
        case "BuiltIn": return "Built-in"
        case "CoreMIDISrc", "CoreMIDIDest", "CoreMIDIDst": return "MIDI"
        default: return prefix
        }
    }

    /// Decode a 20-byte audioComponentDescription blob into a {type, subtype,
    /// manufacturer} tuple. Each FourCC is four little-endian-stored bytes, so we
    /// reverse each 4-byte group to recover the human code (e.g. "aumu").
    private func decodeComponent(_ v: PlistValue?) -> AudioUnitComponent? {
        guard case .data(let bytes) = deref(v), bytes.count >= 12 else { return nil }
        return AudioUnitComponent(
            type: fourCCLE(bytes, 0),
            subtype: fourCCLE(bytes, 4),
            manufacturer: fourCCLE(bytes, 8)
        )
    }

    private func fourCCLE(_ bytes: [UInt8], _ offset: Int) -> String {
        let group = [bytes[offset + 3], bytes[offset + 2], bytes[offset + 1], bytes[offset]]
        return String(decoding: group, as: UTF8.self)
    }

    // MARK: - Mappings (session.go / spec.go)

    private func walkMappings(_ node: [String: PlistValue], path: String, into out: inout [MappingInfo]) {
        for (key, val) in node {
            guard let child = dict(val) else { continue }
            if let leaf = readLeaf(child, collection: path, target: key) {
                out.append(leaf)
                continue
            }
            let childPath = path.isEmpty ? key : path + "/" + key
            walkMappings(child, path: childPath, into: &out)
        }
    }

    /// Decode a dict as a mapping leaf if it carries a trigger encoding. Returns
    /// nil for a non-leaf (a container to recurse into) and drops unassigned
    /// placeholder leaves (`enabled == false`), matching the Go read model's
    /// includePlaceholders=false default.
    private func readLeaf(_ m: [String: PlistValue], collection: String, target: String) -> MappingInfo? {
        let minV = floatValue(m["min"]) ?? 0
        let maxV = floatValue(m["max"]) ?? 0
        let autoToggle = bool(m["autoToggle"])

        // (a) nested specState dict (version 13 / .aum_midimap).
        if let ss = dict(m["specState"]) {
            return makeLeaf(collection: collection, target: target, specState: true,
                            type: intOr(ss["type"], 0), data1: intOr(ss["data1"], 0),
                            channel: intOr(m["channel"], 0), enabled: bool(ss["enabled"]),
                            min: minV, max: maxV, autoToggle: autoToggle)
        }
        // (b) flat-dotted specState keys.
        if m["specState.enabled"] != nil {
            return makeLeaf(collection: collection, target: target, specState: true,
                            type: intOr(m["specState.type"], 0), data1: intOr(m["specState.data1"], 0),
                            channel: intOr(m["channel"], 0), enabled: bool(m["specState.enabled"]),
                            min: minV, max: maxV, autoToggle: autoToggle)
        }
        // (c) packed spec int (version 8 / 10).
        if let raw = m["spec"] {
            let spec = decodePacked(intOr(raw, 0))
            return makeLeaf(collection: collection, target: target, specState: false,
                            type: spec.type, data1: spec.data1, channel: spec.channel, enabled: spec.enabled,
                            min: minV, max: maxV, autoToggle: autoToggle)
        }
        return nil
    }

    private func makeLeaf(collection: String, target: String, specState: Bool, type: Int, data1: Int,
                          channel: Int, enabled: Bool, min: Double, max: Double, autoToggle: Bool) -> MappingInfo? {
        guard enabled else { return nil }
        let typeName = MappingInfo.typeLabel(specState: specState, type: type, data1: data1)
        return MappingInfo(collection: collection, target: target, type: type, typeName: typeName,
                           data1: data1, channel: channel, min: min, max: max,
                           autoToggle: autoToggle, enabled: enabled)
    }

    /// Split a packed `spec` int (version 8 / 10) into type/data1/channel and
    /// apply the unassigned-placeholder rule (type-default with data1 0).
    private func decodePacked(_ spec: Int) -> (type: Int, data1: Int, channel: Int, enabled: Bool) {
        let channel = spec & 0x0F
        let data1 = (spec >> 4) & 0x7F
        let type = spec >> 11
        let placeholder = (data1 == 0 && (type == 4 || type == 6))
        return (type, data1, channel, !placeholder)
    }

    private func sortMappings(_ mappings: inout [MappingInfo]) {
        mappings.sort {
            if $0.collection != $1.collection {
                return $0.collection.localizedCaseInsensitiveCompare($1.collection) == .orderedAscending
            }
            return $0.target.localizedCaseInsensitiveCompare($1.target) == .orderedAscending
        }
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}
