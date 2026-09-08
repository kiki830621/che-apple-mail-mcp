/// The single committed source of truth for this server's own version (#303).
///
/// Before #303 the version lived as a bare `"2.7.2"` literal inside the
/// `Server(...)` init in `Server.swift` — nobody bumped it, so the MCP
/// handshake reported `2.7.2` for ~18 releases and the server had no reliable
/// self-version to compare against for staleness detection.
///
/// This value is bumped per release and its drift is guarded two ways so it can
/// never silently rot again:
///   - `scripts/release.sh` refuses to tag if `current` != the release version.
///   - `VersionTests` asserts `current` matches the newest `## [x.y.z]` entry in
///     `CHANGELOG.md`, so CI catches drift between releases too.
enum AppVersion {
    /// Semantic version of the last released binary this source tree targets.
    /// Between releases it equals the newest CHANGELOG version; the release
    /// script bumps it in lockstep with the tag.
    static let current = "3.1.0"
}
