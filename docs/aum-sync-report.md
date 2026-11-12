# The sync report

After every sync cycle of the **aum sessions** tab the app tells
[mcp-midi-controller](https://github.com/teemow/mcp-midi-controller) what it
made of each file, and how far the **audio units** tab's sync is. Without the
report the daemon sees only the app's manifest polls and downloads: it cannot
tell a file the app is about to fetch from one it holds back as a conflict, and
had to read the app's screen to find out.

The session sync itself is described in [aum-sessions-tab.md](aum-sessions-tab.md).

> Public-repo rule: the paths in a report are private rig data. The app sends
> them to the daemon the files are synced with and nowhere else, and never logs
> them. The examples here are made up.

## The request

```
POST /aum-session/sync
Content-Type: application/json
```

One JSON document, a few hundred bytes when nothing needs attention:

```json
{
  "v": 1,
  "app": "auv3-probe 0.4.0",
  "at": "2026-01-02T03:04:05Z",
  "rev": 42,
  "synced": 131,
  "conflicts": ["Songs/Held.aumproj"],
  "errors": [
    {"path": "Songs/Broken.aumproj", "error": "mcp-midi-controller returned HTTP 400: decode session"}
  ],
  "in_flight": [
    {"path": "Songs/Down.aumproj", "to": "device"}
  ],
  "audio_units": {"state": "syncing", "total": 96, "synced": 60, "failed": 1}
}
```

| Key | Type | Meaning |
|---|---|---|
| `v` | number | Format version, `1`. |
| `app` | string, optional | The app and its version. |
| `at` | string | When the report was made, RFC 3339, UTC. |
| `rev` | number | The staging rev of the manifest this cycle diffed against (`rev` of `GET /aum-session`), `0` without one. A file staged at a later rev is not covered by this report. |
| `synced` | number | Files both sides hold as the same. |
| `conflicts` | array of strings | Files both sides changed since the last sync. The app copies them neither way until a side is picked on the file's row. |
| `errors` | array of `{path, error}` | Files the app could not copy, with the text the row shows. |
| `in_flight` | array of `{path, to}` | Copies that are queued or running; `to` is `"device"` (a fetch) or `"controller"` (an upload). |
| `error` | string, optional | Why the cycle mirrored nothing at all: no AUM folder is linked, or the folder could not be read. Absent when the cycle ran. |
| `audio_units` | object, optional | The audio units tab's sync, see below. |

Paths are relative to the AUM folder, slash-separated, the same as `path` in
the manifest. The three lists are always present, in path order, empty or not.
A file in none of them needs nothing: it is in sync, or it is a MIDI mapping
only the device has (the app never uploads those).

`audio_units`:

| Key | Meaning |
|---|---|
| `state` | `"syncing"` while a run is under way; `"done"` when every installed unit was sent or failed; `"waiting"` when units are left and no run is under way (the daemon was not reachable, or a run was cut short). |
| `total` | Installed units. |
| `synced` | Units the daemon holds, those without parameters included. |
| `failed` | Units that could not be read or sent. |

`done` does not need `synced` to reach `total`: a unit that does not
instantiate fails at every attempt.

## The answer

Any `2xx` status; the app ignores the body. A daemon from before the report
answers `404` or `405`: the app then stops reporting to it until its next
start. A report that does not arrive (a timeout, no connection) is not
repeated; the next cycle sends its own.

## When it is sent

- **At the end of every sync cycle** that reached the daemon. The app runs a
  cycle when the daemon becomes reachable, when the app comes to the front,
  when the tab appears, and every 20 seconds while the app is in front. In this
  report `in_flight` is empty, unless the cycle put a copy off: a file that
  changed while the cycle ran is left to the next cycle and stays listed.
- **Before the first copy** of a cycle that has something to copy. `in_flight`
  then lists every queued copy.
- **After a conflict was resolved** on its row.

The app only runs while it is in front. The daemon gets no report from an app
iPadOS has suspended.

## Reading it

To learn what became of a file it staged at rev *R*, the daemon waits for a
report with `rev` ≥ *R*. Then the file's path is

- in `conflicts`: the app will not fetch it. Somebody has to pick a side;
- in `errors`: the fetch failed, the text says why;
- in `in_flight`: the app is on it, the next report follows;
- in none of them: the app holds the staged bytes.

A report with `error` says the app mirrors nothing for now.

An upload by the app bumps the staging rev as well, so a cycle that uploaded
reports a `rev` older than the daemon's current one. The next cycle's report
catches up.

## Accessibility identifiers

For UI automation of the sessions tab (the daemon drives the app through
WebDriverAgent), the elements that a label cannot tell apart carry the path in
their accessibility identifier:

| Element | Label | Identifier |
|---|---|---|
| A conflict row's first button | `keep device` | `keep-device:<file path>` |
| A conflict row's second button | `keep controller` | `keep-controller:<file path>` |
| The browser's navigation bar | the folder's last path part | `aum-folder:<folder path>` (`aum-folder:` at the root) |

Labels are unchanged. The paths are the report's paths.
