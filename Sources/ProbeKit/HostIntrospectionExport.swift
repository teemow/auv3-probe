// The host-diagnostics snapshot, collectors and reporter were factored out into
// the standalone `auv3-host-introspection` package. Re-export it from ProbeKit so
// the existing consumers (both AUv3 extensions, the diagnostics channel/streamer,
// and the app) keep reaching `HostDiagnostics`, `HostDiagnosticsCollector`,
// `HostDiagnosticsReporter` and `HostRenderSnapshot` through `import ProbeKit`.
@_exported import AUv3HostIntrospection
