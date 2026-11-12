import Foundation

/// The accessibility identifiers of the sessions tab that carry a path, for UI
/// automation (the daemon reads the app's window through WebDriverAgent). A
/// label is shared by every row's button and a folder's title by every folder
/// of that name; these tell them apart. Paths are relative to the AUM folder,
/// slash-separated, as in the sync report (docs/aum-sync-report.md).
public enum AUMSessionsAccessibility {
    /// A conflict row's "keep device" button: `keep-device:<file path>`.
    public static func keepDevice(_ path: String) -> String { "keep-device:\(path)" }

    /// A conflict row's "keep controller" button: `keep-controller:<file path>`.
    public static func keepController(_ path: String) -> String { "keep-controller:\(path)" }

    /// The browser's navigation bar below the root: `aum-folder:<folder path>`.
    public static func folder(_ path: String) -> String { "aum-folder:\(path)" }
}
