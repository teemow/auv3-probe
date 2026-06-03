# How AUv3 discovery works (and why third-party units go missing)

This app enumerates installed Audio Units with
`AVAudioUnitComponentManager.shared().components(...)`, filtered to the
component types we care about (`aumu` instruments, `aufx` effects, `aumf`
music effects). For each match it instantiates the unit, walks its
`AUParameterTree`, and emits an `AudioUnitDetails`.

## Enumeration is instance-independent

An audio unit's parameter tree is a property of the component, not of a
particular instance: any instance exposes the same tree the host (e.g. AUM)
would see. So `AudioUnitScanner` instantiates a throwaway instance purely to read
the tree, then discards it — no audio engine, no rendering, no I/O.

## The Inter-App Audio gotcha (the important one)

By default a freshly built host will only see **Apple's built-in Audio Units**
— `AUDelay`, `AUDistortion`, `AUNBandEQ`, `AUSampler`, and friends — and **none
of the third-party AUv3 plugins** installed on the device. The symptom is a
short, suspiciously alphabetical list where every entry is made by `appl`.

This is not a bug in the enumeration code, a pagination limit, or a timing
issue. It is an entitlement requirement:

> An app may only enumerate **third-party** AUv3 extensions if it has the
> **Inter-App Audio** capability (`inter-app-audio` entitlement). Without it,
> `AVAudioUnitComponentManager` returns only the in-process, Apple-provided
> Audio Units.

Apple's built-in AUs run in-process and are always visible. Third-party AUv3
plugins are App Extensions that run **out-of-process**, and the system only
hands their registrations to hosts that carry the Inter-App Audio entitlement.

Inter-App Audio itself is deprecated (Apple's recommended replacement *is*
AUv3), but the entitlement is still the gate for discovery, so we declare it.
It works with a **free Apple ID** — no paid Developer Program enrolment needed.

### How it's declared here

- **Xcode / XcodeGen build:** `Resources/AUv3Probe.entitlements` contains
  `inter-app-audio = true`, wired in via `CODE_SIGN_ENTITLEMENTS` in
  `project.yml`. XcodeGen + Xcode enable the matching capability on the App ID
  when you sign with your personal team.
- **Linux / xtool build:** an `App.entitlements` file with the same key,
  referenced from `xtool.yml` via `entitlementsPath`. xtool maps
  `inter-app-audio` to a free-account capability and enables it on the App ID
  during provisioning. See [building-on-linux.md](building-on-linux.md).

### If plugins are *still* missing after adding the entitlement

A known quirk: the system's AUv3 registry is populated lazily. If a host has
never browsed third-party AUs, the first scan can come back with built-ins
only. Opening the AU list in a known-good host (e.g. GarageBand or AUM) once,
then returning to this app and tapping **Rescan**, warms the registry. With the
entitlement in place this is rarely necessary, but it's the fallback.

Also make sure the plugin's containing app has actually been installed and
launched at least once, and that the device trusts this app's developer
certificate (Settings → General → VPN & Device Management).
