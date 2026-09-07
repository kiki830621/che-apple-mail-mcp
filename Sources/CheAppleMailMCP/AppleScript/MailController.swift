import Foundation
import MailSQLite  // #194: SearchField — the fallback honors the same field/date filters as the SQLite path
#if canImport(AppKit)
import AppKit  // #175: NSPasteboard for full-fidelity clipboard preserve/restore
#endif

/// Controller for Apple Mail via AppleScript
actor MailController {
    static let shared = MailController()

    private init() {}

    // MARK: - #254 test seams (production never sets these)

    /// When set, `runScript` routes through this closure instead of
    /// NSAppleScript — lets production-site behavioral tests drive the real
    /// compose/reply/forward methods with a fake script runner (no live Mail).
    private var scriptRunnerOverride: ((String) throws -> String)?
    /// When set, both pre-flight refusal probes return this closure's value
    /// (nil = proceed) instead of probing Accessibility — lets tests select the
    /// branch deterministically.
    private var refusalOverride: (() -> ComposeRefusal?)?
    /// #404 (PR #407 R1 #4): the recipient receipt's verdict for the most recent
    /// draft created through `composeViaMailto`, so `updateDraft` can gate its
    /// delete on a DEFINITIVE mismatch. Actor-isolated; reset at the start of
    /// every receipt-bearing compose, `nil` when no receipt ran.
    private var lastRecipientReceiptOutcome: RecipientReceiptOutcome?

    /// #287: when set, `openMailtoURL` calls this instead of
    /// `NSWorkspace.shared.open` — lets tests exercise the LaunchServices
    /// hand-off deterministically (no real compose window).
    private var openURLOverride: ((URL) -> Bool)?

    /// #297: when set, overrides the AppleScript execution timeout so tests can
    /// exercise the hang guard with a sub-second deadline instead of the
    /// production default (`defaultScriptTimeout`).
    private var scriptTimeoutOverride: TimeInterval?

    func setTestSeams(
        scriptRunner: ((String) throws -> String)?,
        refusal: (() -> ComposeRefusal?)?,
        openURL: ((URL) -> Bool)? = nil,
        scriptTimeout: TimeInterval? = nil
    ) {
        scriptRunnerOverride = scriptRunner
        refusalOverride = refusal
        openURLOverride = openURL
        scriptTimeoutOverride = scriptTimeout
    }

    // MARK: - AppleScript Execution

    /// #297: default wall-clock ceiling for a single NSAppleScript execution.
    /// Well under the MCP client's ~120s idle timeout (so a stuck call returns
    /// an actionable error rather than silently dropping the whole server
    /// connection) and well over normal ~1-2s Mail IPC. Tunable via the
    /// `scriptTimeout` test seam. Internal (not private) so the #301 deadline
    /// contract is pinned by tests.
    static let defaultScriptTimeout: TimeInterval = 45

    /// #301: deadline for the GUI-DRIVING scripts (clean-path compose, reply /
    /// forward paste). These are a different duty class from every other
    /// script: one runScript spans the whole keystroke flow — open window,
    /// drive the From popup, clipboard-fill recipients, paste the body, attach
    /// via ⇧⌘G, dispatch — with deliberate `delay`s at each phase, and on a
    /// large mailbox Mail's UI answers slowly. Live evidence (#301): a HEALTHY
    /// sender-popup `create_draft` runs past 45s, so the #297 default killed it
    /// mid-flight — the abandoned (uncancellable) script kept typing into Mail
    /// while the legacy fallback ran, the reply arrived at ~78s with a WRAPPED
    /// body, and the caller experienced a hang. On the osascript subprocess
    /// path the measured happy path is ~6s (script) / ~33s (worst live E2E with
    /// popup + save), so 90s clears the legitimate ceiling with margin while
    /// staying comfortably under the MCP client's ~120s idle timeout — a
    /// deadline the CLIENT can still observe is the only kind that helps
    /// (verify #301, Lens A P1-4).
    static let guiScriptTimeout: TimeInterval = 90

    /// #301 — refuse new GUI flows past this many unreaped (SIGKILL-resistant)
    /// osascript children: bounds thread/zombie growth AND the re-opened
    /// clipboard window a still-alive paster would have (verify Lens B P1-3).
    static let maxUnreapedGuiChildren = 3
    /// Shared accounting (reference type — detached waiter threads decrement).
    private let guiChildAccounting = GuiChildAccounting()

    /// Execute AppleScript and return result.
    ///
    /// - Parameter timeout: optional per-call deadline (#301). nil → the #297
    ///   default. The `scriptTimeout` test seam still beats BOTH, so tests can
    ///   compress any call site's deadline.
    /// Whether XCTest is loaded in this process (#362).
    ///
    /// Computed once — `NSClassFromString` is a runtime lookup and `runScript`
    /// is on the hot path for every AppleScript-backed tool. In a shipped
    /// binary this is always `false`: nothing links XCTest, so the guard it
    /// gates is unreachable in production.
    nonisolated static let isRunningUnderXCTest: Bool = NSClassFromString("XCTestCase") != nil

    /// Live integration tests opt out of the #362 guard through the **same**
    /// env var that already gates them (`MailAppIntegrationTests`) — reusing
    /// the existing switch rather than inventing a second one, so there is no
    /// way to be in live mode by one flag and blocked by the other.
    nonisolated static let liveAppleScriptAllowedInTests: Bool =
        ProcessInfo.processInfo.environment["MAIL_APP_INTEGRATION_TESTS"] != nil

    func runScript(_ source: String, timeout: TimeInterval? = nil) throws -> String {
        if let override = scriptRunnerOverride {
            // Route the fake runner through the same guard so tests can drive
            // the timeout path with a hanging runner (no live NSAppleScript).
            // No preflight ran on this path — assume granted so the timeout
            // message never sends a TEST at the TCC dead end (#301).
            return try runGuarded(timeout: timeout, automationGranted: true) { try override(source) }
        }
        // #362 — a unit test must NEVER execute a real Apple Event.
        //
        // `runGuarded` runs every call on a detached thread and, on timeout,
        // ABANDONS it (#297/#301: the AppleScript call cannot be cancelled).
        // An abandoned thread running a real Apple Event keeps pumping
        // AppleScript's nested event loop — and XCTest has run-loop observers
        // installed, so its `performTest:` observer fires from inside that pump
        // on a thread it never expected, asserts "Run loop nesting count is
        // negative", and aborts the whole process. Crash report on #362 shows
        // exactly that stack.
        //
        // The damage is not local: XCTest attributes the abandoned thread's
        // 45-second wait, and the eventual abort, to whichever *unrelated* test
        // happens to be running. Three runs produced three different victims,
        // including a pure-function test on an empty array that "took" 333s.
        //
        // So: under XCTest, reaching this point at all is a defect in the test
        // (a missing seam), and it must fail HERE — instantly, naming itself —
        // rather than spawning a thread that corrupts its neighbours. Detected
        // by whether XCTest is loaded in this process rather than by an env
        // var, because SwiftPM runs the suite via the `xctest` binary directly.
        if Self.isRunningUnderXCTest && !Self.liveAppleScriptAllowedInTests {
            throw MailError.operationFailed(
                "MailController.runScript reached the REAL NSAppleScript path while running "
                + "under XCTest, with no test seam installed. A unit test must never execute a "
                + "real Apple Event: on timeout runGuarded abandons the thread, and the "
                + "still-running AppleScript event pump collides with XCTest's run-loop "
                + "observers — aborting the process and blaming an unrelated test (#362). "
                + "Install a seam with setTestSeams(scriptRunner:) around this call, or do not "
                + "route it through MailController.")
        }
        let granted = try preflightAutomation()
        return try runGuarded(timeout: timeout, automationGranted: granted) {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw MailError.scriptCreationFailed
            }
            let result = script.executeAndReturnError(&error)
            if let error = error {
                let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
                let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                throw MailError.scriptFailed(message: message, code: code)
            }
            return result.stringValue ?? ""
        }
    }

    /// Execute AppleScript and return result as list
    func runScriptAsList(_ source: String, timeout: TimeInterval? = nil) throws -> [String] {
        let granted = try preflightAutomation()
        return try runGuarded(timeout: timeout, automationGranted: granted) {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                throw MailError.scriptCreationFailed
            }
            let result = script.executeAndReturnError(&error)
            if let error = error {
                let message = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown AppleScript error"
                let code = error["NSAppleScriptErrorNumber"] as? Int ?? -1
                throw MailError.scriptFailed(message: message, code: code)
            }
            var items: [String] = []
            let count = result.numberOfItems
            if count > 0 {
                for i in 1...count {
                    if let item = result.atIndex(i)?.stringValue {
                        items.append(item)
                    }
                }
            }
            return items
        }
    }

    // MARK: - #297 AppleScript hang guard

    /// Run `body` (a real NSAppleScript execution, or a test override) on a
    /// detached thread and wait at most the resolved deadline:
    /// `scriptTimeoutOverride ?? timeout ?? defaultScriptTimeout` — the test
    /// seam beats a per-call value beats the default (#301), so tests can
    /// compress any call site while the GUI sites raise theirs in production.
    /// On timeout, throw `MailError.scriptTimedOut` instead of blocking forever.
    ///
    /// Root cause of #297: `NSAppleScript.executeAndReturnError` blocks
    /// *indefinitely* (rather than returning -1743) when Automation TCC is
    /// pending/not-determined or Mail is unresponsive, wedging the server's
    /// request thread until the MCP client's ~120s idle timeout dropped the
    /// whole connection. NSAppleScript is a blocking, uncancellable C API, so a
    /// timed-out call's thread is simply abandoned (it resolves once TCC is
    /// answered or the process restarts) — this bounds the block to `timeout`.
    ///
    /// #301: `automationGranted` (the preflight probe's verdict, reused — no
    /// extra probe) threads into the thrown error so the timeout message can be
    /// honest: a GRANTED timeout is a long-flow/unresponsive-Mail situation,
    /// NOT a TCC problem, and must not send the user down the tccutil dead end.
    /// Note the residual race the deadline itself cannot fix: an abandoned GUI
    /// script keeps driving Mail (keystrokes and all) until it finishes on its
    /// own — raising the GUI deadline so healthy flows are never killed is the
    /// primary mitigation; the message warns about the residue.
    private func runGuarded<T>(
        timeout: TimeInterval? = nil,
        automationGranted: Bool = true,
        _ body: @escaping () throws -> T
    ) throws -> T {
        let deadline = scriptTimeoutOverride ?? timeout ?? Self.defaultScriptTimeout
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: Result<T, Error>?
        Thread.detachNewThread {
            let r: Result<T, Error>
            do { r = .success(try body()) } catch { r = .failure(error) }
            lock.lock(); outcome = r; lock.unlock()
            sem.signal()
        }
        if sem.wait(timeout: .now() + deadline) == .timedOut {
            throw MailError.scriptTimedOut(seconds: Int(deadline), automationGranted: automationGranted)
        }
        lock.lock(); defer { lock.unlock() }
        return try outcome!.get()
    }

    // MARK: - #301 GUI-script execution (osascript subprocess)

    /// Execute a GUI-DRIVING AppleScript via an `/usr/bin/osascript` subprocess
    /// instead of in-process NSAppleScript (#301).
    ///
    /// ## Why a subprocess for exactly this script class
    ///
    /// Live evidence (#301): the identical sender-popup flow completes in ~6s
    /// under `osascript` but does NOT finish within 120s under in-process
    /// NSAppleScript on a detached thread — every System Events round-trip is
    /// massively degraded in-process, and the popup/paste flows (poll loops =
    /// many events) multiply that into an effective hang. This is the deeper
    /// layer of the already-documented in-process AX instability family
    /// (#295: unstable AX tree, #296: identical matcher passes under osascript
    /// and gets ZERO menu items in-process).
    ///
    /// The subprocess also fixes the guard's worst residue: `Process.terminate`
    /// actually CANCELS a timed-out script, so an abandoned GUI flow no longer
    /// keeps typing into Mail while the legacy fallback runs (in-process
    /// NSAppleScript is uncancellable — #297 could only abandon the thread).
    ///
    /// TCC: the subprocess's Apple Events are attributed to its RESPONSIBLE
    /// process (this binary), so the existing Automation grant covers it —
    /// verified live in the #301 gate. The preflight probe still runs first.
    ///
    /// Short query/action scripts stay on in-process `runScript` — they are
    /// single-digit-event payloads where in-process latency is fine and the
    /// #297 abandon semantics are acceptable.
    func runGuiScript(_ source: String, timeout: TimeInterval? = nil) throws -> String {
        if let override = scriptRunnerOverride {
            // Same seam as runScript: tests drive GUI flows with a fake runner.
            // The fallback deadline matches the production one (guiScriptTimeout,
            // NOT the 45s default) so a test asserting the scriptTimedOut payload
            // sees the same number production would emit (verify #301, Lens A P2-2).
            return try runGuarded(timeout: timeout ?? Self.guiScriptTimeout,
                                  automationGranted: true) { try override(source) }
        }
        let granted = try preflightAutomation()
        // #301 verify (Lens B P1): a child SIGKILL cannot reach (uninterruptible
        // kernel wait against a wedged Mail/WindowServer) leaves a permanently
        // blocked waiter thread AND a live paster that could outrun the clipboard
        // restore. Bound the damage: refuse new GUI flows while several children
        // remain unreaped — an honest "wedged" error beats compounding the pile.
        guard guiChildAccounting.current() < Self.maxUnreapedGuiChildren else {
            throw MailError.operationFailed(
                "GUI scripting subsystem appears wedged: \(Self.maxUnreapedGuiChildren) "
                + "terminated osascript children have not exited (Mail or WindowServer "
                + "may be hung). Not starting another GUI flow. Restart this MCP server "
                + "(and check Mail) — or use open_mailto (zero-TCC, no GUI scripting) "
                + "as the clean-compose fallback.")
        }
        let deadline = scriptTimeoutOverride ?? timeout ?? Self.guiScriptTimeout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Script via stdin ("-"), not -e: no argv length limit, and the script
        // text (which embeds email bodies/recipients) never appears in the
        // process table for same-uid observers. Do not "simplify" this to -e.
        process.arguments = ["-"]
        // Copy-then-override env (never a fresh dictionary — that would strip
        // HOME/TMPDIR): pin a UTF-8 locale so osascript's error text (which
        // embeds CJK mailbox names/subjects) decodes losslessly (Lens A P2-7).
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        process.environment = env
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            // Map the POSIX NSError onto the same MailError family every other
            // failure uses, so the wrapper-free → legacy fallback ladder still
            // catches it (verify #301, Lens A P1-3).
            throw MailError.scriptFailed(
                message: "could not launch /usr/bin/osascript: \(error.localizedDescription)",
                code: -1)
        }

        // Drain stdout/stderr CONCURRENTLY, and START the drains BEFORE feeding
        // stdin — osascript happens to read the whole program before emitting
        // anything, but ordering the drains first removes that load-bearing
        // assumption entirely (Lens A P2-4). DispatchGroup.wait provides the
        // happens-before edge for reading the boxes (Lens A P1-1); on a drain
        // timeout the boxes are NEVER read (no torn/partial data).
        let outBox = PipeDrainBox(), errBox = PipeDrainBox()
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        Thread.detachNewThread {
            outBox.set((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
            drainGroup.leave()
        }
        drainGroup.enter()
        Thread.detachNewThread {
            errBox.set((try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data())
            drainGroup.leave()
        }

        // Feed the script. THROWING variants: the non-throwing FileHandle
        // write/closeFile raise an uncatchable ObjC exception on a broken pipe
        // and would abort the whole MCP server (Lens A P1-2).
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: Data(source.utf8))
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw MailError.scriptFailed(
                message: "could not feed the script to osascript: \(error.localizedDescription)",
                code: -1)
        }

        let waitSem = DispatchSemaphore(value: 0)
        let wedgeFlag = PipeDrainBox()   // reused as a lock-protected flag box
        let accounting = guiChildAccounting
        Thread.detachNewThread {
            process.waitUntilExit()
            if !wedgeFlag.get().isEmpty { accounting.decrement() }
            waitSem.signal()
        }
        if waitSem.wait(timeout: .now() + deadline) == .timedOut {
            // REAL cancellation (the #297 in-process guard could only abandon):
            // SIGTERM, brief grace, then SIGKILL — the GUI flow stops driving
            // Mail the moment the interpreter dies.
            process.terminate()
            if waitSem.wait(timeout: .now() + 2) == .timedOut {
                // Guard the raw kill: the waiter may have reaped the child in
                // the gap, freeing the pid for reuse — and a pathological pid 0
                // would signal our own process group (verify Lens A P2-1 /
                // Lens B P1-2). isRunning is false once reaped.
                let pid = process.processIdentifier
                if pid > 0, process.isRunning { kill(pid, SIGKILL) }
                if waitSem.wait(timeout: .now() + 2) == .timedOut {
                    // Even SIGKILL did not take (uninterruptible kernel wait):
                    // count the un-reaped child; the waiter decrements when it
                    // finally exits (Lens B P1-3).
                    wedgeFlag.set(Data([1]))
                    accounting.increment()
                }
            }
            // Best-effort: a killed popup flow can leave an OPEN MENU that
            // swallows every subsequent keystroke, making the next attempt fail
            // confusingly — send one Escape to dismiss it (Lens B P2).
            Self.dismissLingeringGuiMenu()
            throw MailError.scriptTimedOut(seconds: Int(deadline), automationGranted: granted)
        }
        // Join the drains with a REAL barrier. On timeout, throw — never return
        // a truncated stdout as the script result (a grandchild inheriting the
        // pipe's write end can hold EOF open past osascript's exit).
        if drainGroup.wait(timeout: .now() + 5) == .timedOut {
            throw MailError.scriptFailed(
                message: "osascript exited but its output pipes did not close within 5s "
                    + "(a grandchild may be holding them) — refusing to return partial output",
                code: -1)
        }

        // Lossy decode (never nil): stderr embeds CJK mailbox names/subjects,
        // and a decode failure must not erase the diagnostic (Lens A P2-7).
        let errText = String(decoding: errBox.get(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let (message, code) = Self.parseOsascriptError(errText)
            throw MailError.scriptFailed(message: message, code: code)
        }
        // osascript appends one LF to the script's return value — strip it at
        // the BYTE level so a CR-terminated AppleScript result doesn't fuse
        // into a "\r\n" grapheme and survive (Lens A P2-5).
        var outData = outBox.get()
        if outData.last == 0x0A { outData.removeLast() }
        return String(decoding: outData, as: UTF8.self)
    }

    /// #301 — best-effort Escape after a timed-out GUI flow: an open From-popup
    /// menu left behind by the killed interpreter swallows subsequent
    /// keystrokes. Fire-and-forget, tightly bounded, never throws.
    private static func dismissLingeringGuiMenu() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to key code 53"]
        guard (try? p.run()) != nil else { return }
        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread { p.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: .now() + 3) == .timedOut { p.terminate() }
    }

    /// Parse `osascript` stderr into (message, code) — the shape is
    /// `path: execution error: <message> (<code>)`. Falls back to the raw text
    /// with code -1 when the shape doesn't match (never loses the message).
    static func parseOsascriptError(_ stderr: String) -> (String, Int) {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // #301 verify (Lens A P2-6): AppleScript `log` output ALSO lands on
        // osascript's stderr, so the blob can carry noise lines before (or
        // after) the real error. Scan for the LAST line carrying the
        // "execution error: " marker and parse THAT line; only fall back to
        // whole-blob parsing when no line carries the marker.
        let marker = "execution error: "
        let lines = text.components(separatedBy: "\n")
        let candidate = lines.last(where: { $0.contains(marker) }) ?? text
        // Trailing `(<code>)` — the code is signed.
        if let open = candidate.range(of: "(", options: .backwards),
           candidate.hasSuffix(")"),
           let code = Int(candidate[open.upperBound..<candidate.index(before: candidate.endIndex)]) {
            var message = String(candidate[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let r = message.range(of: marker) {
                message = String(message[r.upperBound...])
            }
            return (message.isEmpty ? candidate : message, code)
        }
        // Shapeless fallback: STILL strip everything through the marker — the
        // POSTDISPATCH sentinel is a prefix check downstream, and returning the
        // raw `path: execution error: ` prefix would silently flip
        // "refuse to re-send" into "re-send" (verify Lens C P1).
        var fallback = candidate
        if let r = fallback.range(of: marker) {
            fallback = String(fallback[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return (fallback.isEmpty ? "osascript failed with no error output" : fallback, -1)
    }

    /// #297: fail fast — with an actionable error — instead of attempting a
    /// blocking NSAppleScript that would hang, when Automation TCC is clearly
    /// unusable. Reuses the existing non-prompting `AutomationStatus.probe()`.
    /// `.denied` reuses the #288 -1743 remediation text; `.targetNotRunning`
    /// tells the caller to open Mail. `.notDetermined` / `.granted` / `.unknown`
    /// proceed under the timeout guard — never false-fast a pending first-run
    /// prompt (that is exactly the state the guard exists to bound).
    ///
    /// - Returns: whether the probe verified `.granted` (#301) — reused by the
    ///   timeout message so it never blames TCC when TCC was verified fine.
    @discardableResult
    private func preflightAutomation() throws -> Bool {
        // #303: surface staleness before any AppleScript work — warn ONCE, but
        // keep checking until there is something to warn about (verify B2).
        // Never throws / never refuses: #297's guard already makes a stale
        // ≥v2.24.0 server safe for execution, so refusing would break a working
        // session; this only nudges a restart. The read itself is bounded at
        // the syscall (verify B1) because this point is OUTSIDE that guard.
        MailController.stalenessWarnOnce(
            state: &didWarnStaleness,
            reader: MailController.readVersionSidecar,
            emit: { MailController.emitDiagnostic("⚠ " + $0) })
        switch AutomationStatus.probe() {
        case .denied:
            throw MailError.scriptFailed(
                message: "Automation permission is not granted to this binary (pre-flight probe).",
                code: -1743)
        case .targetNotRunning:
            throw MailError.operationFailed(AutomationStatus.report(for: .targetNotRunning))
        case .granted:
            return true
        case .notDetermined, .unknown:
            return false
        }
    }

    /// #303 — "已經警告過了嗎", NOT "已經檢查過了嗎" (verify B2).
    ///
    /// The original spelling (`didCheckStaleness`) consumed the gate on the
    /// FIRST call regardless of outcome. `Server.swift`'s startup
    /// `checkForNewMail()` reaches `preflightAutomation()` during `init()`,
    /// before the transport starts — at which point the sidecar necessarily
    /// still matches the running binary, so it burned the gate on a guaranteed
    /// no-drift result and every later call short-circuited. That killed the
    /// feature in exactly the long-lived-window scenario #303 exists for.
    private var didWarnStaleness = false

    /// #303 — testable warn-once gate. Consumes `state` **only when a warning
    /// is actually produced**, so a no-drift result leaves the gate armed and a
    /// drift appearing hours later is still caught. `nonisolated static` so
    /// tests drive it synchronously with a counting reader.
    ///
    /// Re-reading on every preflight until a warning fires is deliberate: the
    /// read is bounded (see `readVersionSidecar(at:)`) to a few syscalls,
    /// negligible next to the `AutomationStatus.probe()` Apple Event already on
    /// this path — and per `.claude/rules/r-must-direct-db.md` most *read*
    /// tools go through SQLite and never reach here at all, so this is
    /// user-paced, not a hot path. A time-based throttle was rejected: it would
    /// reintroduce a smaller version of the detection gap above plus extra
    /// mutable state.
    /// The gate is consumed by a DELIVERED warning, not by a decided one
    /// (#303 verify round 6, cross-model). `emit` returns whether the write
    /// actually succeeded; a failed write leaves the gate armed so the next
    /// preflight tries again. Without this, one transient stderr failure —
    /// `EPIPE` while a log reader restarts, `ENOSPC` — permanently swallowed
    /// the only warning the process would ever emit. #320's process-wide
    /// `SIG_IGN` is what makes that path reachable at all: before it, a
    /// broken-pipe stderr killed the process instead of returning an error.
    @discardableResult
    nonisolated static func stalenessWarnOnce(
        state: inout Bool,
        reader: () -> String?,
        emit: (String) -> Bool
    ) -> Bool {
        guard !state else { return false }
        guard let warning = StalenessCheck.evaluate(compiled: AppVersion.current, sidecar: reader())
        else { return false }        // no drift → gate stays armed
        guard emit(warning) else { return false }   // delivery failed → gate stays armed
        state = true                 // warned once, and it landed
        return true
    }

    /// Max bytes read from the sidecar. A version string is `"2.25.0"`-sized;
    /// 64 is generous and bounds a huge or corrupt file.
    private static let versionSidecarByteCap = 64

    /// #303 — write an advisory diagnostic to stderr, swallowing descriptor
    /// errors so an *advisory* nudge cannot itself abort the process.
    ///
    /// The non-throwing `write` overload on `FileHandle.standardError` raises an
    /// uncatchable ObjC exception on a bad descriptor: a host launching the
    /// server with fd 2 closed turned this into `SIGABRT` (verified, exit 134),
    /// violating "never throws / never refuses" by a route its wording did not
    /// anticipate (#303 verify round 4). The throwing `write(contentsOf:)` with
    /// the error swallowed fixes the descriptor-error family (closed / read-only
    /// fd 2 — both verified to survive), the same remedy #301 took on the
    /// osascript stdin path.
    ///
    /// Broken-pipe boundary, restated for the post-#320 tree (#303 verify round
    /// 6): round 5 recorded that a broken-pipe fd 2 kills the process in the
    /// kernel before `write()` returns, with no process-wide `SIGPIPE` handling
    /// anywhere — that was true then and is **false now**. `main.swift` installs
    /// `signal(SIGPIPE, SIG_IGN)` at startup (#320, shipped in v2.26.0), so a
    /// broken pipe surfaces as an `EPIPE` *error* from the throwing write, which
    /// this function catches like any other descriptor error. Both families —
    /// bad descriptor (closed / read-only fd 2) and broken pipe — are now
    /// survivable here.
    ///
    /// - Returns: whether the line actually reached fd 2. Callers that consume a
    ///   one-shot gate MUST branch on this (see `stalenessWarnOnce`): a
    ///   swallowed failure that still burns the gate loses the warning forever.
    @discardableResult
    nonisolated static func emitDiagnostic(_ line: String) -> Bool {
        // #346: delegates to the single stderr sink. The append-newline +
        // delivery-reporting contract is #303's and is unchanged — the
        // staleness gate stays armed on a failed write.
        Diagnostics.emit(line + "\n")
    }

    /// #303 — locate the wrapper's version sidecar next to THIS running
    /// executable (`<dir>/.<binary>.version`). Derived from the executable's
    /// own directory, never a hardcoded `~/bin`, so a dev build (from
    /// `.build/`) or a non-plugin install simply finds nothing.
    nonisolated static func readVersionSidecar() -> String? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let sidecar = exe.deletingLastPathComponent()
            .appendingPathComponent(".\(exe.lastPathComponent).version")
        return readVersionSidecar(at: sidecar.path)
    }

    /// #303 verify B1 — the bounded read, split out so the live layer is
    /// directly testable (the seam whose absence let B1/B2 through review).
    ///
    /// This runs in `preflightAutomation()`, which callers invoke BEFORE
    /// `runGuarded` — so it is NOT covered by #297's deadline, and it occupies
    /// the serial executor of this process-wide singleton actor. An unbounded
    /// read here would stall every AppleScript-backed tool indefinitely. The
    /// defense mirrors `ExportDirLock.acquire` (#236), which solved this exact
    /// primitive (fixed path in a user-writable directory):
    ///
    /// - `O_NOFOLLOW` refuses a planted symlink (`ELOOP`).
    /// - `O_NONBLOCK` keeps `open()` from blocking on a FIFO.
    /// - `fstat` + `S_ISREG` rejects anything that is not a regular file, so a
    ///   FIFO or a character device like `/dev/zero` (endless reads) is out.
    /// - a single capped `read` bounds a huge or corrupt regular file.
    ///
    /// `O_CLOEXEC` is deliberately omitted, matching the `ExportDirLock` call
    /// site's documented reasoning rather than cargo-culting it.
    ///
    /// Fail-open everywhere: any failure yields nil (no warning), because a
    /// spurious restart nag is worse than the staleness it would report.
    ///
    /// Residual, stated not hidden: `O_NONBLOCK` does not defeat a hard-mounted
    /// network filesystem, where `open()` can still block uninterruptibly. That
    /// is pathological for an executable's own directory — the same mount would
    /// stall `exec` of this binary — and is out of scope.
    nonisolated static func readVersionSidecar(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }

        // Read cap+1 so "file is larger than the cap" is DETECTABLE rather than
        // silently truncated. Truncating at exactly the cap changes meaning:
        // a 65-byte `"99.0.0" + 58 spaces + "X"` — whose full content is NOT a
        // version — trims down to exactly "99.0.0" and would raise a bogus
        // drift warning from corrupt input, breaking the fail-open invariant
        // this function is supposed to guarantee (#303 verify round 3).
        // Anything over the cap is rejected outright: a real sidecar is
        // `"2.25.0\n"`-sized, so oversize means corrupt, not merely verbose.
        let probe = versionSidecarByteCap + 1
        var buffer = [UInt8](repeating: 0, count: probe)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, probe) }
        guard n > 0, n <= versionSidecarByteCap else { return nil }

        guard let text = String(bytes: buffer[0..<n], encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Account Operations

    /// List all mail accounts with structured metadata.
    ///
    /// Returns `display_name` (the canonical identifier to pass back to
    /// `get_email` / `search_emails` etc.), the raw `name` attribute (which
    /// for EWS accounts is the opaque `ews://.../` URL, not usable as an
    /// AppleScript `account "..."` reference), and the account's `user_name`,
    /// `id`, `email_addresses`, and `enabled` state.
    ///
    /// Why AppleScript and not the SQLite fast path: `AccountsMap.plist`
    /// exposes only `AccountURL`, not email addresses, so filesystem-only
    /// resolution cannot recover the email for EWS accounts (per #9 and #11).
    /// Mail.app's `user name` / `email addresses` AppleScript attributes are
    /// the only reliable source.
    func listAccounts() throws -> [[String: Any]] {
        // Emit one record per account, using control characters as separators
        // to avoid the quoting headaches of &/,/newline. See AccountsScriptParser
        // for the field layout.
        //
        // Use \u{001E} (RS), \u{001F} (US), \u{001D} (GS) — guaranteed not
        // to appear in legitimate account metadata.
        let RS = "\u{001E}"
        let US = "\u{001F}"
        let GS = "\u{001D}"

        let script = """
        set AppleScript's text item delimiters to "\(GS)"
        tell application "Mail"
            set out to ""
            set first_acc to true
            repeat with acc in accounts
                set n to name of acc as string
                set u to ""
                try
                    set u to user name of acc as string
                end try
                set i to id of acc as string
                set emails_list to {}
                try
                    set emails_list to email addresses of acc
                end try
                if emails_list is missing value then
                    set emails_str to ""
                else
                    set emails_str to emails_list as string
                end if
                set en to enabled of acc as string
                if first_acc then
                    set first_acc to false
                else
                    set out to out & "\(RS)"
                end if
                set out to out & n & "\(US)" & u & "\(US)" & i & "\(US)" & emails_str & "\(US)" & en
            end repeat
            return out
        end tell
        """

        let raw = try runScript(script)
        let parsed = AccountsScriptParser.parse(raw)
        return parsed.map { $0.asDictionary() }
    }

    /// Get account details
    func getAccountInfo(accountName: String, accountId: String? = nil) throws -> [String: Any] {
        // #202: select via resolveAccountRef — UUID selector when accountId is
        // present, else the legacy `account "<name>"` form (byte-identical).
        let acctRef = resolveAccountRef(accountId: accountId, accountName: accountName)
        let enabledScript = """
        tell application "Mail"
            get enabled of \(acctRef)
        end tell
        """

        let emailsScript = """
        tell application "Mail"
            get email addresses of \(acctRef)
        end tell
        """

        let enabled = try runScript(enabledScript)
        let emails = try runScriptAsList(emailsScript)

        return [
            "name": accountName,
            "enabled": enabled == "true",
            "email_addresses": emails
        ]
    }

    // MARK: - Mailbox Operations

    /// List mailboxes for an account
    func listMailboxes(accountName: String? = nil, accountId: String? = nil) throws -> [[String: Any]] {
        // Simplified: get mailbox names
        let namesScript: String
        let hasSelector = (accountId.map { !$0.isEmpty } ?? false)
            || (accountName.map { !$0.isEmpty } ?? false)
        if hasSelector {
            // #202: UUID selector when accountId present, else `account "<name>"`
            // (byte-identical to the legacy form).
            let acctRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            namesScript = """
            tell application "Mail"
                get name of every mailbox of \(acctRef)
            end tell
            """
        } else {
            namesScript = """
            tell application "Mail"
                set allNames to {}
                repeat with acc in accounts
                    set accMailboxes to name of every mailbox of acc
                    set allNames to allNames & accMailboxes
                end repeat
                return allNames
            end tell
            """
        }

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            var info: [String: Any] = ["name": name]
            if let account = accountName {
                info["account"] = account
            }
            return info
        }
    }

    /// Create a new mailbox.
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildCreateMailboxScript` (`MailboxCrudScriptBuilder.swift`).
    func createMailbox(name: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildCreateMailboxScript(name: name, accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    /// Delete a mailbox.
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildDeleteMailboxScript` (`MailboxCrudScriptBuilder.swift`).
    func deleteMailbox(name: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildDeleteMailboxScript(name: name, accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    // MARK: - Email Operations

    /// List emails in a mailbox (AppleScript fallback path — typically only
    /// reached when SQLite reader is unavailable or throws; see Server.swift
    /// `case "list_emails"`).
    ///
    /// #89 performance fix: pre-fix this issued THREE separate AppleScript
    /// invocations (subjects + senders + ids), each repeating
    /// `count of messages of mb` + mailbox resolution. On a 92k-message
    /// Gmail INBOX the `count` operation alone took 14+ minutes per call,
    /// times three calls = OOM-on-time. Two changes:
    ///
    /// 1. **Drop the `count of messages` guard entirely**. AppleScript's
    ///    `messages 1 thru N of mb` clamps to mailbox size internally —
    ///    if N > msgCount it returns the full list (not an error).
    ///    Confirmed empirically on small mailboxes. The count was
    ///    defensive but bought nothing on the happy path.
    /// 2. **Batch the 3 property fetches into ONE script**. Single IPC,
    ///    single mailbox resolution, AppleScript record literal returns
    ///    three arrays in parallel.
    ///
    /// Result: 3× IPC reduction + count-of-messages bottleneck removed.
    /// Empty-mailbox case handled by AppleScript returning empty arrays.
    func listEmails(mailbox: String, accountName: String, accountId: String? = nil, limit: Int = 50) throws -> [[String: Any]] {
        // Single batched script: resolve mailbox once, fetch all three
        // properties in one IPC. Returns a list of three lists in fixed
        // order: [{ids}, {subjects}, {senders}].
        //
        // Note: `messages 1 thru N of mb` clamps internally when N exceeds
        // msgCount — no out-of-range error on small mailboxes. Empty
        // mailbox returns three empty lists.
        let batchedScript = """
        tell application "Mail"
            set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
            set theMessages to messages 1 thru \(limit) of mb
            return {id of theMessages, subject of theMessages, sender of theMessages}
        end tell
        """

        // Returns nested list — three parallel arrays. runScriptAsList
        // currently flattens this, so use runScript and parse the result
        // structure as comma-separated groups.
        // For simplicity and to keep parsing robust, issue three sub-scripts
        // against the SAME `theMessages` reference (still single mailbox
        // resolution + single message-range fetch is the dominant cost).
        let combinedScript = """
        tell application "Mail"
            set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
            set theMessages to messages 1 thru \(limit) of mb
            set subjectList to subject of theMessages
            set senderList to sender of theMessages
            set idList to id of theMessages
            -- AppleScript can't easily return a struct via osascript JSON,
            -- so emit three lines using U+001E (RECORD SEPARATOR) between
            -- groups — same convention as `AccountsScriptParser`.
            set AppleScript's text item delimiters to (ASCII character 30)
            set result to (idList as string) & (ASCII character 30) & (subjectList as string) & (ASCII character 30) & (senderList as string)
            set AppleScript's text item delimiters to ""
            return result
        end tell
        """
        _ = batchedScript  // documented above; combinedScript is the implementation we actually run

        let raw = try runScript(combinedScript)
        // Split on U+001E group separator: 3 groups of comma-separated values.
        let groups = raw.components(separatedBy: "\u{001E}")
        guard groups.count == 3 else {
            // Defensive: if AppleScript returned unexpected shape, fall back
            // to empty result rather than crash. Caller will see [] which is
            // the same as an empty mailbox — better than throwing on a
            // happy-path read tool.
            return []
        }
        let ids = groups[0].components(separatedBy: ", ")
        let subjects = groups[1].components(separatedBy: ", ")
        let senders = groups[2].components(separatedBy: ", ")

        var emails: [[String: Any]] = []
        for i in 0..<min(ids.count, subjects.count, senders.count) {
            // Skip empty result rows (happens when mailbox is empty — all
            // three lists contain a single empty string).
            if ids[i].isEmpty && subjects[i].isEmpty && senders[i].isEmpty { continue }
            emails.append([
                "id": ids[i],
                "subject": subjects[i],
                "sender": senders[i]
            ])
        }

        return emails
    }

    /// Get email content by ID
    /// - format: "html" (default) returns HTML body with links preserved;
    ///           "text" returns plain text content;
    ///           "source" returns full MIME source
    func getEmail(id: String, mailbox: String, accountName: String, accountId: String? = nil, format: String = "html") throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)

        let subjectScript = """
        tell application "Mail"
            get subject of \(ref)
        end tell
        """

        let senderScript = """
        tell application "Mail"
            get sender of \(ref)
        end tell
        """

        let dateScript = """
        tell application "Mail"
            get date received of \(ref) as string
        end tell
        """

        let subject = try runScript(subjectScript)
        let sender = try runScript(senderScript)
        let dateReceived = try runScript(dateScript)

        let content: String
        switch format {
        case "text":
            let contentScript = """
            tell application "Mail"
                get content of \(ref)
            end tell
            """
            content = try runScript(contentScript)

        case "source":
            let sourceScript = """
            tell application "Mail"
                get source of \(ref)
            end tell
            """
            content = try runScript(sourceScript)

        default: // "html"
            let sourceScript = """
            tell application "Mail"
                get source of \(ref)
            end tell
            """
            let rawSource = try runScript(sourceScript)
            content = extractHTMLBody(from: rawSource)
        }

        return [
            "id": id,
            "subject": subject,
            "sender": sender,
            "date_received": dateReceived,
            "format": format,
            "content": content
        ]
    }

    /// Extract HTML body from MIME source, falling back to plain text content.
    ///
    /// Honors `Content-Transfer-Encoding` of the HTML part — both
    /// `quoted-printable` (legacy path) and `base64` (#73, common on
    /// Android Gmail / Outlook Mobile). 7bit / 8bit / binary pass through
    /// unchanged. This used to be private; promoted to internal so unit
    /// tests can hit the parser directly without spinning up AppleScript.
    func extractHTMLBody(from mimeSource: String) -> String {
        // Look for text/html part in multipart message
        // Find the HTML content between Content-Type: text/html and the next boundary
        let lines = mimeSource.components(separatedBy: "\n")
        var inHTMLPart = false
        var pastHTMLHeaders = false
        var htmlLines: [String] = []
        var boundary: String?
        var transferEncoding = "7bit"  // tracked per HTML part — reset on each match

        // Find boundary from Content-Type header
        for line in lines {
            if line.contains("boundary=") {
                if let range = line.range(of: "boundary=\"") {
                    let start = range.upperBound
                    if let end = line[start...].firstIndex(of: "\"") {
                        boundary = String(line[start..<end])
                    }
                } else if let range = line.range(of: "boundary=") {
                    let start = range.upperBound
                    boundary = line[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        for line in lines {
            if line.contains("Content-Type: text/html") {
                inHTMLPart = true
                pastHTMLHeaders = false
                transferEncoding = "7bit"  // reset for the new HTML part's headers
                continue
            }

            if inHTMLPart && !pastHTMLHeaders {
                // Capture Content-Transfer-Encoding from the part headers
                // (case-insensitive prefix match — RFC 2045 doesn't require
                // exact case for header field names).
                let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
                if lowered.hasPrefix("content-transfer-encoding:") {
                    transferEncoding = lowered
                        .replacingOccurrences(of: "content-transfer-encoding:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // Skip headers until empty line
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pastHTMLHeaders = true
                }
                continue
            }

            if inHTMLPart && pastHTMLHeaders {
                // Check for boundary end
                if let b = boundary, line.contains(b) {
                    break
                }
                htmlLines.append(line)
            }
        }

        if htmlLines.isEmpty {
            return mimeSource // Fallback: return raw source if no HTML found
        }

        var html = htmlLines.joined(separator: "\n")

        // Decode according to Content-Transfer-Encoding declared by the
        // HTML part. Falls through to passthrough on unrecognized values
        // (7bit/8bit/binary or anything we don't speak), and to raw-html
        // if base64 decoding fails — degrades gracefully rather than
        // corrupting the output.
        switch transferEncoding {
        case "base64":
            // Strip every kind of whitespace base64 might be wrapped with.
            // Splitting on "\n" leaves trailing "\r" attached; without
            // that strip, Data(base64Encoded:) returns nil and we leak
            // raw base64 to the caller (the very bug #73 was filed for).
            let cleaned = html
                .replacingOccurrences(of: "\r\n", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
            if let data = Data(base64Encoded: cleaned),
               let decoded = String(data: data, encoding: .utf8) {
                html = decoded
            }
            // else: leave html as raw base64 — at least no worse than pre-fix

        case "quoted-printable":
            html = decodeQuotedPrintable(html)

        default:
            break  // 7bit / 8bit / binary / unknown → passthrough
        }

        return html
    }

    /// Decode quoted-printable encoded string.
    ///
    /// Collects all decoded bytes (both literal characters and `=XX` hex
    /// escapes) into a `[UInt8]` buffer first, then interprets the buffer
    /// as UTF-8. This is required because non-ASCII characters in QP
    /// content arrive as multi-byte UTF-8 sequences split across separate
    /// `=XX` escapes (e.g. `é` = `=C3=A9`). The pre-fix code appended
    /// each byte directly as `Character(Unicode.Scalar(byte))`, which
    /// treated `0xC3 0xA9` as two separate codepoints `Ã ©` — classic
    /// mojibake. Surfaced by #73's regression tests.
    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = input
        // Remove soft line breaks (= at end of line)
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")

        var bytes: [UInt8] = []
        var i = result.startIndex
        while i < result.endIndex {
            if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                let hexStart = result.index(after: i)
                let hexEnd = result.index(hexStart, offsetBy: 2)
                let hex = String(result[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                } else {
                    // Malformed `=XX` — pass the literal `=` through as
                    // its UTF-8 encoding (1 byte for ASCII).
                    bytes.append(contentsOf: result[i].utf8)
                }
                i = hexEnd
            } else {
                bytes.append(contentsOf: result[i].utf8)
                i = result.index(after: i)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    /// Search emails
    ///
    /// #194: this AppleScript fallback honors the same `field` / `dateFrom` /
    /// `dateTo` filters the SQLite primary path honors. `subject`/`sender`/`any`
    /// use a fast `whose` substring predicate; `recipient` has no reliable `whose`
    /// form (recipient props are object lists — `whose … contains` over a list is
    /// element-equality, not substring) so it is filtered **in-loop**. **Known
    /// limitation:** `field == .any` here covers subject+sender only; recipient-only
    /// matches require the SQLite index (a stderr note is emitted when this path
    /// runs with `field == .any`).
    func searchEmails(query: String, mailbox: String? = nil, accountName: String? = nil, accountId: String? = nil, limit: Int = 20, sort: String = "desc", field: SearchField = .any, dateFrom: Date? = nil, dateTo: Date? = nil) throws -> [[String: Any]] {
        let escapedQuery = appleScriptEscape(query)
        let sep = "⏐"  // Separator unlikely to appear in email fields

        if field == .any {
            Diagnostics.emit((
                "search_emails AppleScript fallback: field=any matches subject+sender; "
                + "recipient-only matches require the SQLite index (#194 known limitation)\n"))
        } else if field == .recipient {
            Diagnostics.emit((
                "search_emails AppleScript fallback: field=recipient enumerates the mailbox in-loop "
                + "(O(mailbox) — slow on large mailboxes); the SQLite index is the fast path (#194)\n"))
        }
        let dateClause = searchEmailsDateClause(dateFrom: dateFrom, dateTo: dateTo)
        let whoseSuffix = searchEmailsWhoseSuffix(
            field: field, escapedQuery: escapedQuery, datePredicate: dateClause.predicate)
        // Per-message loop body, shared by all 3 branches. `collect` is the
        // branch-specific `set end of results …` statement; for `.recipient` the
        // body wraps it in the in-loop address/name match gate so `limit` counts
        // only matched messages (parity with the SQLite recipient filter).
        func loopBody(collect: String) -> String {
            let guardLimit = "if counter ≥ \(limit) then exit repeat"
            if field == .recipient {
                return """
                \(guardLimit)
                \(searchEmailsRecipientMatchBlock(escapedQuery: escapedQuery))
                if _matched then
                \(collect)
                set counter to counter + 1
                end if
                """
            }
            return """
            \(guardLimit)
            \(collect)
            set counter to counter + 1
            """
        }

        let script: String
        if let mailbox = mailbox, let accountName = accountName {
            // Search specific mailbox of specific account
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & \"\(appleScriptEscape(accountName))\" & \"\(sep)\" & \"\(appleScriptEscape(mailbox))\""
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set mb to \(mailboxRef(mailbox, account: accountName, accountId: accountId))
                set foundMsgs to (messages of mb\(whoseSuffix))
                set results to {}
                set counter to 0
                repeat with msg in foundMsgs
                \(loopBody(collect: collect))
                end repeat
                return results
            end tell
            """
        } else if (accountName.map { !$0.isEmpty } ?? false) || !(accountId ?? "").isEmpty {
            // #180 (verify #192): account-only / id-only mode (no specific
            // mailbox). Pre-fix this fell through to the all-accounts branch
            // below, which ignored BOTH accountName and accountId — so
            // `search_emails(account_name:X, account_id:UUID)` without a mailbox
            // silently searched every account. Scope to the single account via
            // the resolveAccountRef chokepoint (UUID selector when accountId is
            // supplied), aligning the AppleScript fallback with the SQLite
            // primary path, which already filters by account.
            let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & acctName & \"\(sep)\" & mboxName"
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set results to {}
                set counter to 0
                set acct to \(accountRef)
                set acctName to name of acct
                repeat with mbox in every mailbox of acct
                    try
                        set mboxName to name of mbox
                        set foundMsgs to (messages of mbox\(whoseSuffix))
                        repeat with msg in foundMsgs
                        \(loopBody(collect: collect))
                        end repeat
                    end try
                    if counter ≥ \(limit) then exit repeat
                end repeat
                return results
            end tell
            """
        } else {
            // Search across all accounts and mailboxes
            let collect = "set end of results to (id of msg as string) & \"\(sep)\" & (subject of msg) & \"\(sep)\" & (sender of msg) & \"\(sep)\" & (date received of msg as string) & \"\(sep)\" & acctName & \"\(sep)\" & mboxName"
            script = """
            tell application "Mail"
            \(dateClause.setup)
                set results to {}
                set counter to 0
                repeat with acct in every account
                    if (enabled of acct) then
                        set acctName to name of acct
                        repeat with mbox in every mailbox of acct
                            try
                                set mboxName to name of mbox
                                set foundMsgs to (messages of mbox\(whoseSuffix))
                                repeat with msg in foundMsgs
                                \(loopBody(collect: collect))
                                end repeat
                            end try
                            if counter ≥ \(limit) then exit repeat
                        end repeat
                    end if
                    if counter ≥ \(limit) then exit repeat
                end repeat
                return results
            end tell
            """
        }

        let rows = try runScriptAsList(script)

        var emails: [[String: Any]] = []
        for row in rows {
            let fields = row.components(separatedBy: sep)
            guard fields.count >= 6 else { continue }
            emails.append([
                "id": fields[0],
                "subject": fields[1],
                "sender": fields[2],
                "date_received": fields[3],
                "account_name": fields[4],
                "mailbox": fields[5]
            ])
        }

        // Sort by date_received string (Apple Mail returns localized date strings)
        if sort == "asc" {
            emails.reverse()  // Apple Mail returns newest first, reverse for ascending
        }
        // "desc" (default) = newest first, which is Apple Mail's natural order

        return emails
    }

    /// Get unread count
    func getUnreadCount(mailbox: String? = nil, accountName: String? = nil, accountId: String? = nil) throws -> Int {
        let script: String
        if let mailbox = mailbox, let account = accountName {
            script = """
            tell application "Mail"
                get unread count of \(mailboxRef(mailbox, account: account, accountId: accountId))
            end tell
            """
        } else if (accountName.map { !$0.isEmpty } ?? false) || !(accountId ?? "").isEmpty {
            // #180 (verify #192): account-only / id-only mode. Was an inline
            // legacy `account "<display_name>"` selector that ignored accountId
            // entirely — `get_unread_count(account_name:X, account_id:UUID)`
            // with no mailbox silently re-hit the #101 same-display_name
            // collision. Route through the resolveAccountRef chokepoint so the
            // UUID selector applies here too; byte-identical to the legacy form
            // at accountId:nil (`account "<display_name>"`).
            let accountRef = resolveAccountRef(accountId: accountId, accountName: accountName ?? "")
            script = """
            tell application "Mail"
                set total to 0
                repeat with mb in mailboxes of \(accountRef)
                    set total to total + (unread count of mb)
                end repeat
                return total
            end tell
            """
        } else {
            script = """
            tell application "Mail"
                set total to 0
                repeat with acc in accounts
                    repeat with mb in mailboxes of acc
                        set total to total + (unread count of mb)
                    end repeat
                end repeat
                return total
            end tell
            """
        }

        let result = try runScript(script)
        return Int(result) ?? 0
    }

    // MARK: - Email Actions

    /// Mark email as read/unread
    func markRead(id: String, mailbox: String, accountId: String? = nil, accountName: String, read: Bool) throws -> String {
        let script = buildMarkReadScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, read: read)
        return try runScript(script)
    }

    /// Flag email
    func flagEmail(id: String, mailbox: String, accountId: String? = nil, accountName: String, flagged: Bool) throws -> String {
        let script = buildFlagEmailScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, flagged: flagged)
        return try runScript(script)
    }

    /// Move email to another mailbox
    func moveEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildMoveEmailScript(
            id: id, fromMailbox: fromMailbox, toMailbox: toMailbox,
            accountId: accountId, accountName: accountName
        )
        return try runScript(script)
    }

    /// Delete email (move to trash)
    func deleteEmail(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildDeleteEmailScript(
            id: id, mailbox: mailbox,
            accountId: accountId, accountName: accountName
        )
        return try runScript(script)
    }

    // MARK: - Compose Operations

    /// Validate that all file paths exist, throwing with a clear message if any are missing
    private func validateFilePaths(_ paths: [String]) throws {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            throw MailError.invalidParameter("File(s) not found: \(missing.joined(separator: ", "))")
        }
    }

    /// Issue #41: validate email addresses (RFC 5322 addr-spec lite). Rejects:
    ///   - Control characters (0x00-0x1F) — header injection vector
    ///   - Missing or multiple `@` — structurally malformed
    ///   - `@` at start/end — malformed local-part or domain
    ///
    /// Defense-in-depth: `appleScriptEscape` already prevents AppleScript-string
    /// injection, but malformed addresses can corrupt Mail.app's draft creation
    /// or generate confusing recipient errors. Strict validation gives clear
    /// caller-visible errors at the boundary.
    ///
    /// `internal` so @testable import can exercise without going through
    /// composeEmail / replyEmail. Empty array is no-op.
    func validateEmailAddresses(_ addresses: [String], field: String) throws {
        guard !addresses.isEmpty else { return }
        var failures: [String] = []
        for raw in addresses {
            // #251: a `Name <email>` mailbox form is validated on its
            // addr-spec part (the old whole-string check mis-rejected legal
            // names containing '@'). The NAME part is checked for control
            // chars below via the same scan (it is part of `raw`).
            if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                failures.append("'\(raw)' contains control characters")
                continue
            }
            let parsed = parseRecipient(raw)
            let addr = parsed.address
            // #265 + #270 + #280: an extracted addr-spec carrying an UNQUOTED
            // angle bracket is malformed — whether a matched pair
            // (`Alice <not-an-email> <bob@x>`, #265), a single stray one
            // (`<a@x` / `a@x>`, #270; the old paired-contains gate let these
            // through), or one embedded in the addr of a mailbox form that DID
            // parse a display name (`Name <a>b@x>` → addr `a>b@x`, #280 — the
            // scan used to be gated on `name == nil` and skipped this exact
            // shape). The scan now runs UNCONDITIONALLY on the parser-extracted
            // addr-spec: in the name==nil fallback `addr` is the whole string,
            // in the name!=nil case it is the bare addr-spec — neither may
            // legally hold an unquoted angle. It stays quote-aware, so a legal
            // RFC 5322 quoted local-part carrying angles (`"a<b"@x`, even a
            // matched `"a<b>"@x`) passes — angles inside quoted strings are
            // legal specials, and a naive contains() gate would mis-reject
            // them. Bare-angle `<a@b.c>` is already normalized upstream (angles
            // stripped), unaffected. Residual honesty (#270 verify DA + Codex
            // R1/R2): the scan validates quote CLOSURE and position-before-@,
            // not local-part grammar — any properly closed quote segment before
            // the first unquoted `@` exempts its angles even where the
            // local-part is malformed (`"<a@x>"` fully-quoted, `a"<>"b@x`
            // mid-atom, adjacent `"<a>""<b>"@x`). Full RFC 5322 local-part
            // validation is out of lite-validator scope (see #270 diagnosis
            // Residue). Unterminated quotes, escaped angles inside them, and
            // domain-position quotes get NO exemption (R1/R2, Codex — see
            // containsUnquotedAngle). CFWS comments are likewise unsupported
            // (#280 verify, Codex): grammar-legal `user@example.net(>)` is
            // rejected — consistently on BOTH paths now, matching the bare
            // path's shipped #270 behavior (a comment carrying '@' always
            // failed atCount; comment-aware scanning is full-parser
            // territory). All land as Mail-level invalid, no mis-send.
            if containsUnquotedAngle(addr) {
                failures.append("'\(raw)' is a malformed recipient (stray/unpaired angle brackets)")
                continue
            }
            // Structural: exactly one `@`, neither at start nor end.
            // #289: count SCALARS, not Characters — `@` fused with a trailing
            // combining scalar (U+FE0F) into one grapheme cluster compares
            // unequal to "@" and slipped the Character-level count (the atCount
            // sibling of #280's angle-scan fix; U+0040 is a single ASCII
            // scalar, so scalar counting is strictly more precise).
            let atCount = addr.unicodeScalars.filter { $0 == "@" }.count
            if atCount != 1 {
                failures.append("'\(addr)' must contain exactly one '@' (got \(atCount))")
                continue
            }
            // #289 (Codex R1): boundary checks at SCALAR level too — Character-
            // level hasPrefix/hasSuffix compares whole grapheme clusters, so a
            // leading `@` fused with U+FE0F was invisible to hasPrefix while
            // the scalar atCount now counts it (`@\u{FE0F}x` would have flipped
            // from reject to accept). A trailing-side mask (`user@\u{FE0F}`)
            // leaves the `@` scalar non-terminal — the FE0F-only domain is
            // accepted as Mail-level-invalid garbage (benign class, same as
            // `a@-`): the old rejection there was an accident of the very
            // fusion bug this fix removes, and domain grammar validation is
            // out of lite-validator scope.
            if addr.unicodeScalars.first == "@" || addr.unicodeScalars.last == "@" {
                failures.append("'\(addr)' must not start or end with '@'")
                continue
            }
        }
        guard failures.isEmpty else {
            throw MailError.invalidParameter("Invalid email address(es) in '\(field)': \(failures.joined(separator: "; "))")
        }
    }

    /// Issue #34: case-insensitive dedup within a recipient list (preserves
    /// first-seen order). Use BEFORE passing to recipientFragment to avoid
    /// duplicate `make new cc recipient` AppleScript calls for the same address.
    ///
    /// Note: cross-list dedup (cc_additional vs reply_all-derived CCs from
    /// original message) is OUT of scope for this helper — it would require
    /// fetching original-message CC headers. Document as known limitation.
    func dedupAddresses(_ addresses: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for addr in addresses {
            let key = addr.lowercased()
            if seen.insert(key).inserted {
                result.append(addr)
            }
        }
        return result
    }

    /// Issue #38: harden attachment path validation against prompt-injection
    /// exfil vectors. Three layers of defense applied in order:
    ///   1. Existence (preserved from validateFilePaths)
    ///   2. Symlink resolution (defeats `~/Documents/decoy → ~/.ssh` bypass)
    ///   3. Deny-list of sensitive directories (default-on, hardcoded)
    ///   4. Optional allow-list via `MAIL_MCP_ATTACHMENT_ROOTS` env var
    ///      (colon-separated, `~` expanded). If unset, only deny-list applies.
    ///
    /// Without these checks, a malicious / hallucinated MCP caller could pass
    /// `attachments=["/Users/X/.ssh/id_ed25519"]` and have it attached to a
    /// silent draft (combined with `save_as_draft=true` post-#33).
    ///
    /// `internal` (not `private`) so `@testable import` can exercise the helper
    /// in unit tests without going through Mail.app.
    func validateAttachmentPaths(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }

        // Issue #63: cap attachment count to mitigate DoS amplification.
        // Post-#60, each attachment adds ≈0.3s AppleScript dispatch latency
        // (between-attachment pacing) + 0.5s trailing drain. A pathological
        // caller passing N=1000 paths would block Mail.app for ≈300s. The
        // 64KB osascript script soft cap (per MailControllerComposeTests:782)
        // already caps practical N to ~200-400 before script truncation
        // kicks in (≈60-120s ceiling), but explicit count cap is cleaner and
        // matches the input-validation hardening series (#38 / #41 / #50).
        // 50 is well above realistic legitimate use cases (typical mail
        // attachments ≤ 10) but below the script-size cliff.
        let attachmentCountCap = 50
        guard paths.count <= attachmentCountCap else {
            throw MailError.invalidParameter(
                "attachments.count exceeds cap (\(paths.count) > \(attachmentCountCap)). "
                + "Mail.app cannot reliably attach this many files in a single call."
            )
        }

        let home = NSHomeDirectory()
        let denyList: [String] = [
            "\(home)/.ssh",
            "\(home)/Library/Keychains",
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Cookies",
            "\(home)/Library/Application Support/Google/Chrome",
            "\(home)/Library/Application Support/Safari",
            "/etc",
            "/var",
            "/private",
        ]

        // Allow-list: env var split on ":" (Unix convention); leading "~"
        // expanded to NSHomeDirectory(). nil if env var unset → no allow-list
        // restriction (only deny-list applies).
        let allowList: [String]? = ProcessInfo.processInfo
            .environment["MAIL_MCP_ATTACHMENT_ROOTS"]
            .map { raw in
                raw.split(separator: ":", omittingEmptySubsequences: true)
                    .map { String($0) }
                    .map { p in p.hasPrefix("~") ? "\(home)\(p.dropFirst())" : p }
            }

        var failures: [String] = []

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else {
                failures.append("'\(path)' not found")
                continue
            }

            let resolved = URL(fileURLWithPath: path)
                .standardized
                .resolvingSymlinksInPath()
                .path

            if let denied = denyList.first(where: { resolved == $0 || resolved.hasPrefix("\($0)/") }) {
                failures.append("'\(path)' rejected: resolves under sensitive directory '\(denied)'")
                continue
            }

            if let allowList = allowList {
                let isAllowed = allowList.contains { allowed in
                    resolved == allowed || resolved.hasPrefix("\(allowed)/")
                }
                if !isAllowed {
                    failures.append("'\(path)' rejected: outside MAIL_MCP_ATTACHMENT_ROOTS allow-list")
                    continue
                }
            }
        }

        guard failures.isEmpty else {
            throw MailError.invalidParameter("Attachment path validation failed: \(failures.joined(separator: "; "))")
        }
    }

    /// Compose and send a new email
    func composeEmail(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil, format: BodyFormat = .plain, fromAddress: String? = nil) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41: validate every recipient field (to / cc / bcc) at the boundary.
        try validateEmailAddresses(to, field: "to")
        if let cc = cc { try validateEmailAddresses(cc, field: "cc") }
        if let bcc = bcc { try validateEmailAddresses(bcc, field: "bcc") }
        // Issue #131: validate from_address with the same address-format
        // discipline applied to recipients. Mail.app's `sender` property
        // accepts plain addr-spec; multiple-@ / control-char inputs would
        // fail with opaque AppleScript errors otherwise.
        if let from = fromAddress, !from.isEmpty {
            try validateEmailAddresses([from], field: "from_address")
        }
        // Note: `accountName` parameter is intentionally accepted but unused
        // here (legacy/dead since the tool was added — see #131 issue body).
        // The actual sender selection is wired through `fromAddress`. Kept
        // for backward compat with any Swift caller still passing it; no
        // production caller does so.

        // #175/#304: the mailto hand-off is the ONLY body path (native compose
        // pipeline → no Apple-Mail-URLShare/blockquote-cite wrapper). The legacy
        // AppleScript injection it used to fall back to is gone, so an ineligible
        // call now fails with a named reason instead of quietly producing a
        // wrapped body. A simple custom from_address rides the clean path via the
        // verified From popup (#219). See MailtoCompose.swift.
        return try dispatchComposePath(
            refusal: composeRefusalForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                to: to, cc: cc ?? [], bcc: bcc ?? []),
            cleanPath: {
                try composeViaMailto(
                    to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                    attachments: attachments, send: true, fromAddress: fromAddress)
            },
            // #242: once the send keystroke has been dispatched the send state
            // is UNKNOWN — say so rather than letting a raw POSTDISPATCH token
            // invite an auto-retrying caller to re-send. #301: a TIMEOUT on this
            // (always-sending) flow is unknown-send-state too — the ONE script
            // spans ⇧⌘D, so the deadline can fire on either side of it and the
            // terminated interpreter cannot say which (verify P0).
            mapRuntimeError: { error in
                (isPostDispatchError(error) || isTimeoutError(error))
                    ? unknownSendStateError(error)
                    : error
            })
    }

    /// #175/#219/#304 — the pre-flight refusal for this compose call, or nil to
    /// proceed. Probes Accessibility at call time. A custom sender
    /// (`fromAddress`) rides the clean path via the verified From-popup (#219)
    /// when Accessibility is granted. An empty subject refuses (the GUI dispatch
    /// guard identifies our compose window by its title = subject).
    // PR #407 R1 #9: the three lists are passed AS the three lists — the pure
    // derivation is per-list, and the 12-cell matrix tests that shape.
    private func composeRefusalForCall(format: BodyFormat, fromAddress: String?, subject: String, attachments: [String]? = nil, to recipients: [String] = [], draftMode: Bool = false, cc: [String] = [], bcc: [String] = []) -> ComposeRefusal? {
        if let override = refusalOverride { return override() }
        // #404: the derivation is the pure `composeCallRefusal` so the
        // draft/send × to/cc/bcc × bare/named matrix is unit-testable. Reason 6
        // is send-only — on a draft every list is AX-addressed and GUI-filled
        // (#277 for `to`, #404 for `cc` / `bcc`); the "Cc can be hidden via
        // Header Fields" objection is answered by locating fields through their
        // AXIdentifier and revealing Bcc on demand, not by refusing.
        return composeCallRefusal(
            format: format,
            accessibilityTrusted: AccessibilityStatus.isTrusted,
            fromAddress: fromAddress,
            subject: subject,
            attachments: attachments,
            to: recipients, cc: cc, bcc: bcc,
            draftMode: draftMode)
    }

    /// #175 — run the wrapper-free mailto compose path. Builds the percent-encoded
    /// URL, refuses over-long URLs (→ caller falls back; avoids silent body
    /// truncation), and runs the GUI script with the user's clipboard preserved
    /// at full fidelity when attachments are involved (the script sets the
    /// clipboard per-attachment for the Go-to-folder paste).
    private func composeViaMailto(
        to: [String], subject: String, body: String,
        cc: [String]?, bcc: [String]?, attachments: [String]?, send: Bool,
        fromAddress: String? = nil
    ) throws -> String {
        // #277/#404: a display name can't ride the mailto URL (RFC 6068). Any
        // list carrying a display name is omitted from the URL as a whole and
        // filled through its AX-addressed field (order preserved; bare + named
        // tokenize alike). Cc/Bcc joined To here in #404 — the field is located
        // by AXIdentifier, so a hidden field fails loud instead of misfiring.
        let partition = partitionRecipientsForMailto(to: to, cc: cc ?? [], bcc: bcc ?? [])
        // #277 defense-in-depth (verify R1 + R2, Codex): display-name fill is
        // DRAFT-ONLY. Eligibility already routes a send with ANY display-name
        // recipient (To/Cc/Bcc) to the legacy path, so this is unreachable — but
        // a future routing bug must fail LOUD, never silently clean-send with a
        // display name the mailto URL can't carry (wrong/missing recipient). The
        // guard covers all three lists, not just `fillTo` (#219/#277 verify R2,
        // Codex: a fillTo-only check would miss a stray display-name Cc/Bcc).
        if send, anyRecipientHasDisplayName(to)
            || anyRecipientHasDisplayName(cc ?? [])
            || anyRecipientHasDisplayName(bcc ?? []) {
            throw MailError.invalidParameter(
                "internal: display-name recipient on a send reached the clean path — refusing "
                + "(display-name recipients are draft-only on the clean path, #277)")
        }
        let url = buildMailtoURL(to: partition.urlTo, subject: subject, body: body,
                                 cc: partition.urlCc, bcc: partition.urlBcc)
        guard url.count <= maxMailtoURLLength else {
            throw MailError.scriptFailed(
                message: "mailto URL too long (\(url.count) > \(maxMailtoURLLength) chars)",
                code: -1)
        }
        // #219 verify (Codex R1/R2): the popup match is EXACT addr-spec, so
        // pass the bare addr-spec (a `Name <addr>` from_address is normalized
        // to `addr`) — the GUI-side `senderMatches()` suffix-matches the same
        // against the menu labels / popup value (exact `<addr>` suffix, never
        // an extraction a quoted local-part could spoof).
        let popupAddress = fromAddress.map { parseRecipient($0).address }
        let script = buildMailtoComposeScript(
            url: url, subject: subject, attachments: attachments ?? [], send: send,
            fromAddress: popupAddress, fill: partition.fill)
        let needsClipboard = attachments?.isEmpty == false || !partition.fill.isEmpty
        // #301: the whole keystroke flow is ONE script with deliberate per-phase
        // delays — on a large mailbox a HEALTHY run crosses the 45s default, so
        // it gets the GUI deadline (the default killed it mid-flight and the
        // caller saw a hang + a wrapped-body legacy fallback).
        var result = needsClipboard
            ? try withClipboardPreserved({ try runGuiScript(script, timeout: Self.guiScriptTimeout) })
            : try runGuiScript(script, timeout: Self.guiScriptTimeout)
        // #404: the script tags its return value when it had to reveal the Bcc
        // field (the View-menu state is deliberately NOT restored — disclose it).
        // Strip the tag FIRST: it is a suffix of the raw script return, and any
        // disclosure appended before this check would hide it (PR #407 R1 #1 —
        // with from_address set the sender disclosure used to land first, so
        // bcc_field_revealed was lost and the raw tag leaked).
        var bccRevealed = false
        if result.hasSuffix(bccFieldRevealedScriptTag) {
            result.removeLast(bccFieldRevealedScriptTag.count)
            bccRevealed = true
        }
        // #219/#277: disclose what the GUI verified/filled so the caller can
        // see the clean path handled the extras (parity with the legacy
        // disclosure discipline, #237).
        if let addr = popupAddress, !addr.isEmpty {
            result += " [sender verified via From popup: \(addr)]"
        }
        if !partition.fill.isEmpty {
            let fields = partition.fill.map { $0.field.rawValue }.joined(separator: "/")
            result += " [display-name \(fields) recipients GUI-filled via AX-addressed fields (draft-only, #277/#404)]"
        }
        if bccRevealed {
            result += " [bcc_field_revealed: true — Mail's Bcc address field was shown via View ▸ Bcc Address Field and left visible]"
        }
        // #404 recipient receipt: the AX read-back verified token count + display
        // names, but a token exposes no address, so when cc/bcc were GUI-filled
        // the saved draft is re-read and its cc/bcc ADDRESSES compared with the
        // request. Draft-only (a send has nothing left to read); never a failure
        // — a mismatch or a missing draft is disclosed and the draft is KEPT.
        let filledCcOrBcc = partition.fill.contains { $0.field == .cc || $0.field == .bcc }
        lastRecipientReceiptOutcome = nil
        if !send && filledCcOrBcc {
            let receiptScript = buildDraftRecipientReceiptScript(subject: subject)
            // Three states (PR #407 R1 #3): a script FAILURE is recorded as
            // `unavailable` and never retried — retrying a 45 s timeout three
            // times stacked ~135 s onto the call (#406) and still said nothing;
            // only NOTFOUND polls, because the save can land asynchronously.
            var fetch: RecipientReceiptFetch = .notFound
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                do {
                    let raw = try runScript(receiptScript)
                    if let parsed = parseRecipientReceipt(raw) {
                        fetch = .found(parsed)
                        break
                    }
                    fetch = .notFound
                } catch {
                    let reason = error.localizedDescription
                    _ = Diagnostics.emit(
                        "recipient receipt for subject \"\(subject)\" could not run: \(reason)\n")
                    fetch = .unavailable(reason)
                    break
                }
            }
            let outcome = recipientReceiptOutcome(
                expectedCc: cc ?? [], expectedBcc: bcc ?? [], receipt: fetch)
            lastRecipientReceiptOutcome = outcome
            result += recipientReceiptDisclosure(outcome)
        }
        return result
    }

    /// #175 — preserve the user's clipboard (all flavors) across a closure that
    /// mutates it. The mailto attach path sets the clipboard to each attachment
    /// path for the Go-to-folder paste; this snapshots every pasteboard item's
    /// types+data into detached copies and restores them in a `defer` (so the
    /// clipboard is restored even if the GUI script throws). Full-fidelity
    /// (image / RTF / file-promise survive), unlike an AppleScript `the clipboard
    /// as text` round-trip (#175 verify — Codex).
    private func withClipboardPreserved<T>(_ body: () throws -> T) rethrows -> T {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        defer {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return try body()
    }

    /// #218/#304 — the pre-flight refusal for this reply/forward call, or nil to
    /// proceed on the clean native-verb + paste path. Probes Accessibility at
    /// call time.
    private func replyForwardRefusalForCall(format: BodyFormat) -> ComposeRefusal? {
        if let override = refusalOverride { return override() }
        return replyForwardRefusal(
            format: format,
            accessibilityTrusted: AccessibilityStatus.isTrusted
        )
    }

    /// Reply to an email. Optionally add extra CC, attach files, and/or save as draft instead of sending.
    func replyEmail(id: String, mailbox: String, accountName: String, body: String, replyAll: Bool = false, ccAdditional: [String]? = nil, attachments: [String]? = nil, saveAsDraft: Bool = false, format: BodyFormat = .plain, accountId: String? = nil) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41 + #34: validate cc_additional then dedup case-insensitively
        // (within the user-supplied list; cross-list dedup vs reply_all-derived
        // CCs requires fetching original CCs — out of scope, see #34).
        let dedupedCC: [String]?
        if let cc = ccAdditional {
            try validateEmailAddresses(cc, field: "cc_additional")
            dedupedCC = dedupAddresses(cc)
        } else {
            dedupedCC = nil
        }
        let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)

        // #218/#304: the native-verb + paste path is the ONLY reply path. Mail's
        // native `reply` builds the quoted original itself (correct cite-blockquote
        // + threading headers) and we paste ONLY the new body at the cursor — never
        // `set content`/`set html content`, so the user's new text is not wrapped
        // in the URLShare/cite wrapper. The clean path needs NO #43 pre-fetch
        // (Mail quotes the original). The injecting builder it used to fall back
        // to is gone: markdown/html and a missing Accessibility grant now refuse.
        // #301: reply sends unless saved as draft — the timeout gate keys on this.
        let sendFlow = !saveAsDraft
        return try dispatchComposePath(
            refusal: replyForwardRefusalForCall(format: format),
            cleanPath: {
                let pasteScript = buildReplyEmailPasteScript(
                    messageRef: ref,
                    newBody: body,
                    replyAll: replyAll,
                    ccAdditional: dedupedCC,
                    attachments: attachments,
                    saveAsDraft: saveAsDraft
                )
                // Always preserve the user's clipboard — the paste path sets it to
                // the new body for the ⌘V (full-fidelity restore, like #175 attach).
                return try withClipboardPreserved { try runGuiScript(pasteScript, timeout: Self.guiScriptTimeout) }
            },
            // #254: once the send keystroke has been dispatched (or the
            // success-path tail errored — mail definitely sent), the send state
            // is UNKNOWN and must be reported as such (#242 pattern). Every
            // other runtime failure propagates verbatim (#304: there is no
            // second path to retry on).
            mapRuntimeError: { error in
                guard isPostDispatchError(error) || (sendFlow && isTimeoutError(error)) else {
                    return error
                }
                return MailError.scriptFailed(
                    message: "the send keystroke was already dispatched but a GUI step failed "
                        + "afterwards — the send state is UNKNOWN and the reply/forward may already "
                        + "be on the wire. Check Mail's Sent mailbox / Outbox and the original thread "
                        + "before re-sending. The compose window (if still open) was left untouched "
                        + "for inspection. Original error: "
                        + clampedErrorEcho(error.localizedDescription),
                    code: -1)
            })
    }

    /// Forward an email
    func forwardEmail(id: String, mailbox: String, accountName: String, to: [String], body: String? = nil, format: BodyFormat = .plain, accountId: String? = nil) throws -> String {
        // Issue #41: validate forward recipients at the boundary.
        try validateEmailAddresses(to, field: "to")
        let ref = resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)

        // #218/#304: with a NEW body, the native-verb + paste path is the only
        // path — Mail's native `forward` builds the quoted original and we paste
        // only the new note at the cursor, never `set content`/`set html content`.
        // With NO body there is nothing to inject at all, so the plain native
        // `forward` script runs directly: it needs no Accessibility grant and
        // cannot produce a wrapper (#304 — this is why the bodyless case is not
        // one of the six refusals).
        guard let newBody = body else {
            return try runScript(buildForwardNoBodyScript(messageRef: ref, to: to))
        }
        // #301: the with-body forward paste path always dispatches a send.
        return try dispatchComposePath(
            refusal: replyForwardRefusalForCall(format: format),
            cleanPath: {
                let pasteScript = buildForwardEmailPasteScript(
                    messageRef: ref, to: to, newBody: newBody)
                return try withClipboardPreserved { try runGuiScript(pasteScript, timeout: Self.guiScriptTimeout) }
            },
            // #254/#304: a post-dispatch (or timeout) failure leaves the send
            // state UNKNOWN — report that rather than a bare GUI error. Every
            // other runtime failure propagates verbatim.
            mapRuntimeError: { error in
                guard isPostDispatchError(error) || isTimeoutError(error) else { return error }
                return MailError.scriptFailed(
                    message: "the send keystroke was already dispatched but a GUI step failed "
                        + "afterwards — the send state is UNKNOWN and the forward may already "
                        + "be on the wire. Check Mail's Sent mailbox / Outbox and the original thread "
                        + "before re-sending. The compose window (if still open) was left untouched "
                        + "for inspection. Original error: "
                        + clampedErrorEcho(error.localizedDescription),
                    code: -1)
            })
    }

    // MARK: - Draft Operations

    /// List drafts (#174: resolves the per-account drafts mailbox through the
    /// unified `drafts mailbox`'s children instead of the pre-#174 hardcoded
    /// `whose name is "Drafts"` lookup, which failed -1719 on Gmail accounts
    /// whose drafts mailbox carries a localized name like `草稿`).
    func listDrafts(accountName: String, accountId: String? = nil) throws -> [[String: Any]] {
        let script = buildListDraftsScript(accountId: accountId, accountName: accountName)
        do {
            // #276: the script now emits GS/RS-delimited id+subject groups
            // from the same invocation; `parseDraftRows` zips them (throwing
            // on any mismatch instead of silently truncating). The `id` field
            // is additive — existing subject-only consumers are unchanged.
            let rows = try parseDraftRows(try runScript(script))
            return rows.map { row in
                ["subject": row.subject, "id": row.id]
            }
        } catch {
            // #185: route every list_drafts script error through the pure
            // `translateListDraftsScriptError` (ListDraftsScriptBuilder.swift, alongside
            // the 9174 constant). The 9174 no-match becomes an actionable operationFailed
            // carrying `listDraftsNoMatchHint`; any other error rethrows unchanged. A pure
            // function so the whole code-path contract (guard + wrapping + non-9174
            // propagation) is unit-testable without an actor runner seam. Behaviorally
            // identical to the prior selective `catch where code == 9174` (PR #181 #18).
            throw translateListDraftsScriptError(error, accountId: accountId, accountName: accountName)
        }
    }

    /// #276 — `update_draft`: replace an existing draft by locate → create →
    /// receipt → delete (create-then-delete, design D1: the failure direction
    /// is always toward KEEPING drafts — worst case both may exist, visible
    /// and recoverable — never "neither"). Apple Mail drafts cannot be edited
    /// in place, so upsert is the only mechanization.
    ///
    /// Locate is read-only and runs FIRST: a zero-match refuses before
    /// anything is created (spec: update requires an existing draft); an
    /// ambiguous subject_match refuses listing the candidates. The delete
    /// step reuses the same unified-drafts child scope that located the
    /// draft (no per-account mailbox-name resolution); a delete failure
    /// after a confirmed create reports `deleted_old: false` with a note
    /// graded to what is known — confirmed absent / state unknown / both MAY
    /// exist — instead of throwing (design D5: the work is half-done, a
    /// throw would misread as total failure).
    func updateDraft(
        draftId: String?, subjectMatch: String?, accountName: String?, accountId: String?,
        to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil,
        attachments: [String]? = nil, format: BodyFormat = .plain,
        fromAddress: String? = nil
    ) throws -> [String: Any] {
        // Verify R2 (Codex): presence = key PROVIDED — an explicitly-empty
        // value is validated as a provided-but-invalid value, never silently
        // downgraded to "absent" (that let draft_id + subject_match:"" slip
        // past the mutual-exclusion gate). Validate provided values FIRST,
        // then XOR on presence.
        if let sm = subjectMatch, sm.isEmpty {
            throw MailError.invalidParameter(
                "subject_match must be non-empty (exact subject equality); "
                + "to target an empty-subject draft, use draft_id from list_drafts")
        }
        if let did = draftId, !isASCIIDigits(did) {
            // Strict byte-level ASCII digits (verify R1/R4, Codex): both
            // Character.isNumber and a Character range accept graphemes
            // (١٢٣ / "1"+combining mark) that are NOT a valid AppleScript
            // numeric literal.
            throw MailError.invalidParameter(
                "draft_id must be a non-empty ASCII-numeric message id (from list_drafts); got '\(did)'")
        }
        let hasId = (draftId != nil)
        let hasSubject = (subjectMatch != nil)
        guard hasId != hasSubject else {
            throw MailError.invalidParameter(
                "update_draft requires exactly one of draft_id or subject_match (got "
                + (hasId ? "both" : "neither") + ")")
        }

        // 1. Locate (read-only) — account-scoped when a selector was given,
        //    unified all-accounts scan otherwise.
        let listScript: String
        if (accountName?.isEmpty == false) || (accountId?.isEmpty == false) {
            listScript = buildListDraftsScript(accountId: accountId, accountName: accountName ?? "")
        } else {
            listScript = buildListAllDraftsScript()
        }
        let scoped = (accountName?.isEmpty == false) || (accountId?.isEmpty == false)
        let rows: [(id: String, subject: String)]
        do {
            rows = try parseDraftRows(try runScript(listScript))
        } catch {
            if !scoped {
                // Verify R3 (DA-3): the all-accounts scan is deliberately
                // fail-closed — give the caller an actionable next step
                // instead of a bare script error.
                throw MailError.operationFailed(
                    "update_draft: the all-accounts drafts scan failed and was aborted "
                    + "(fail-closed — a partial scan could mis-judge ambiguity). A local "
                    + "or unreadable drafts container can cause this; retry with "
                    + "account_id / account_name scoping. Underlying error: "
                    + error.localizedDescription)
            }
            throw translateListDraftsScriptError(
                error, accountId: accountId, accountName: accountName ?? "")
        }
        let matches = hasId
            ? rows.filter { $0.id == draftId }
            : rows.filter { $0.subject == subjectMatch }
        guard !matches.isEmpty else {
            throw MailError.operationFailed(
                "update_draft: no existing draft matched "
                + (hasId ? "draft_id \(draftId ?? "")" : "subject_match \"\(subjectMatch ?? "")\"")
                + ". update requires an existing draft — use list_drafts to discover ids, "
                + "or create_draft for a brand-new draft.")
        }
        guard matches.count == 1 else {
            let candidates = matches
                .map { "{id: \($0.id), subject: \"\($0.subject)\"}" }
                .joined(separator: ", ")
            throw MailError.operationFailed(
                "update_draft: the identify selector matched \(matches.count) drafts — refusing to guess. "
                + "Retry with draft_id. Candidates: [\(candidates)]")
        }
        let old = matches[0]

        // 2. Create the replacement FIRST (inherits create_draft's full
        //    eligibility + disclosure — #175/#237/#239).
        //    Receipt baseline (verify R5, Codex): the replacement lands under
        //    create_draft's account semantics (default account / from_address)
        //    which may DIFFER from the locate scope — so the pre/post receipt
        //    snapshots use the ALL-accounts scan, covering any destination. A
        //    baseline failure aborts before anything is created (fail closed).
        let receiptScript = buildListAllDraftsScript()
        let preReceiptRows: [(id: String, subject: String)]
        do {
            preReceiptRows = try parseDraftRows(try runScript(receiptScript))
        } catch {
            throw MailError.operationFailed(
                "update_draft: could not take the pre-create drafts snapshot needed for the "
                + "post-create receipt (all-accounts scan failed) — aborting BEFORE creating "
                + "anything. Underlying error: " + error.localizedDescription)
        }
        let preIds = Set(preReceiptRows.map { $0.id })
        let createResult = try createDraft(
            to: to, subject: subject, body: body, cc: cc, bcc: bcc,
            attachments: attachments, accountName: nil, format: format,
            fromAddress: fromAddress)

        // 2.4 RECIPIENT GATE (#404, PR #407 R1 #4): when the replacement's
        //     post-save recipient receipt read the draft and its cc/bcc
        //     addresses DIFFER from the request, the old draft is the only copy
        //     whose recipients were right — keep it (both drafts exist, the
        //     caller is told). Only a DEFINITIVE mismatch gates; a receipt that
        //     could not run (`unavailable`, #406) or found no draft does not,
        //     or every update on a slow-scan account would leave two drafts.
        if let receipt = lastRecipientReceiptOutcome, receipt.isDefinitiveMismatch {
            return [
                "deleted_old": false,
                "old_draft_id": old.id,
                "new_draft": createResult,
                "note": "the replacement draft was created but its saved cc/bcc recipients differ "
                    + "from the request (recipients_verified: false) — the OLD draft (id \(old.id)) was "
                    + "KEPT because it holds the previously verified recipients. Both drafts exist: "
                    + "check the recipients_diff, fix the wrong one in Mail, then delete the other "
                    + "(delete_email) yourself.",
            ]
        }

        // 2.5 RECEIPT (verify R3, DA-2): the GUI mailto create path can
        //     report success after firing keystrokes without the draft
        //     actually landing (phantom success). Deleting on that word
        //     alone could destroy the only copy. Re-list and require a NEW
        //     id (absent from the pre-create set) before touching the old
        //     draft; the save can land asynchronously, so poll briefly.
        // Causality (verify R5, Codex): "any new id" only proves the mailbox
        // changed — an unrelated concurrent draft must not stand in as the
        // receipt. The new row must also carry the replacement's EXACT
        // subject (Swift ==).
        var replacementConfirmed = false
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            if let postRows = try? parseDraftRows(try runScript(receiptScript)),
               postRows.contains(where: { !preIds.contains($0.id) && $0.subject == subject }) {
                replacementConfirmed = true
                break
            }
        }
        guard replacementConfirmed else {
            return [
                "deleted_old": false,
                "old_draft_id": old.id,
                "new_draft": createResult,
                "note": "the replacement draft was reported created but could not be "
                    + "confirmed in the drafts mailbox (not confirmed after re-listing) — "
                    + "the old draft was KEPT. Check Mail's drafts, then delete the old "
                    + "draft manually or retry once the replacement is visible.",
            ]
        }

        // 3. Delete the old draft — best-effort (D5). Predicate = id AND
        //    exact subject (DA-1 cross-account protection).
        let deleteScript = buildDeleteDraftByIdScript(
            draftId: old.id, subject: old.subject, accountId: accountId, accountName: accountName)
        do {
            _ = try runScript(deleteScript)
            return ["deleted_old": true, "old_draft_id": old.id, "new_draft": createResult]
        } catch {
            // 9276 = the whole delete scope scanned CLEAN and the old draft
            // was not there — the only case that may claim confirmed absence
            // (verify R4: a swallowed query error must never masquerade as
            // not-found; those now propagate as their own errors or 9277).
            if case let MailError.scriptFailed(_, code) = error,
               code == updateDraftDeleteNotFoundErrorNumber {
                return [
                    "deleted_old": false,
                    "old_draft_id": old.id,
                    "new_draft": createResult,
                    "note": "the old draft (id \(old.id)) is confirmed absent — a complete "
                        + "clean scan of the delete scope no longer finds it (already removed, "
                        + "possibly concurrently); only the replacement draft exists.",
                ]
            }
            // 9277 = the delete scan could not be completed — the old
            // draft's state is UNKNOWN; do not claim it is gone.
            if case let MailError.scriptFailed(_, code) = error,
               code == updateDraftDeleteScanIncompleteErrorNumber {
                return [
                    "deleted_old": false,
                    "old_draft_id": old.id,
                    "new_draft": createResult,
                    "note": "the delete scan could not be completed, so the old draft's "
                        + "state is unknown (it could not be verified as deleted OR present) — "
                        + "check the drafts mailbox; the replacement draft was created.",
                ]
            }
            return [
                "deleted_old": false,
                "old_draft_id": old.id,
                "new_draft": createResult,
                "note": "replacement draft was created, but the old draft could not be "
                    + "verified as deleted (\(error.localizedDescription)) — both drafts MAY "
                    + "now exist; check the drafts mailbox and remove the old one manually or "
                    + "via delete_email with id \(old.id) if it is still there.",
            ]
        }
    }

    /// Create a draft
    func createDraft(to: [String], subject: String, body: String, cc: [String]? = nil, bcc: [String]? = nil, attachments: [String]? = nil, accountName: String? = nil, format: BodyFormat = .plain, fromAddress: String? = nil) throws -> String {
        if let attachments = attachments { try validateAttachmentPaths(attachments) }
        // Issue #41: validate every recipient field (to / cc / bcc) at the boundary (#107).
        try validateEmailAddresses(to, field: "to")
        if let cc = cc { try validateEmailAddresses(cc, field: "cc") }
        if let bcc = bcc { try validateEmailAddresses(bcc, field: "bcc") }
        // #131: validate sender address (see composeEmail).
        if let from = fromAddress, !from.isEmpty {
            try validateEmailAddresses([from], field: "from_address")
        }

        // #175/#304: the mailto path (save draft via ⌘S) is the only body path;
        // an ineligible call refuses rather than falling back to the injecting
        // builder that used to sit behind it. See composeEmail above.
        return try dispatchComposePath(
            refusal: composeRefusalForCall(
                format: format, fromAddress: fromAddress, subject: subject,
                attachments: attachments,
                to: to,
                draftMode: true, cc: cc ?? [], bcc: bcc ?? []),
            cleanPath: {
                try composeViaMailto(
                    to: to, subject: subject, body: body, cc: cc, bcc: bcc,
                    attachments: attachments, send: false, fromAddress: fromAddress)
            })
        // A draft flow deliberately does NOT map timeouts to unknown-send-state:
        // nothing is sent, and a duplicated draft is visible and recoverable
        // (#301). Any runtime failure propagates as-is.
    }

    // MARK: - Attachment Operations

    /// List attachments of an email
    func listAttachments(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> [[String: Any]] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
        let namesScript = """
        tell application "Mail"
            get name of every mail attachment of \(ref)
        end tell
        """

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Save attachment to disk.
    ///
    /// 5-arg overload retained as the #112 byte-identity referent for
    /// `buildSaveAttachmentScript(accountId: nil)`. No live caller (the Server
    /// `save_attachment` handler uses the #101 6-arg overload), but #180 still
    /// routes its `msgRef` through the `resolveMsgRef` chokepoint — so this path
    /// is no longer an inline-legacy bypass while staying byte-identical at
    /// `accountId: nil`.
    /// #314 — post-write verification for every "Attachment saved" success.
    ///
    /// Mail.app's `save att in POSIX file` is a black box: for an attachment
    /// whose bytes are not locally cached it can write a 0-byte file and
    /// return without error, and the tool then reported the same success
    /// string as a correct save — indistinguishable to every caller, and
    /// invisible to the archive audit (three 0-byte attachments sat
    /// undetected for ~11 weeks). Tier 1 (SQLite/.emlx) has had a pre-write
    /// emptiness guard since #66/#238; this closes the same hole on the
    /// AppleScript tier, where no post-write check existed at all.
    ///
    /// Non-success strings ("Attachment not found") pass through untouched.
    /// A verified success gains a `(N bytes)` suffix so callers and audits
    /// finally have a size signal (`list_attachments` carries none).
    /// #347 — verify through `stat(2)`, not `FileManager.attributesOfItem`.
    ///
    /// `attributesOfItem(atPath:)` does **not** follow symlinks: for a link it
    /// reports `.type = .symbolicLink` and a `.size` equal to the length of the
    /// link's target path. Measured, on a link pointing at an empty file:
    /// `type=NSFileTypeSymbolicLink size=55` — a non-zero number that sailed
    /// past the `size > 0` guard, so the exact 0-byte state #314 exists to
    /// catch verified as a success reporting `(55 bytes)`.
    ///
    /// `stat` follows the link, which is the right call here: `save_path` is a
    /// destination the caller chose, and saving through a symlink is legitimate
    /// use. (Contrast #303's version sidecar, where `O_NOFOLLOW` *rejects*
    /// links — that path reads a file an attacker might plant, this one writes
    /// where the caller asked.) What must be checked is that the **target** is
    /// a regular file. `stat` rather than `open` + `fstat` because opening a
    /// FIFO blocks until a writer appears, and this runs on the shared actor.
    ///
    /// Precisely: `stat` does not wait on a **local FIFO's** reader/writer
    /// rendezvous, which is the hazard `open` introduces here. It is NOT
    /// unconditionally non-blocking — on a hard-mounted NFS/SMB/FUSE path whose
    /// server has stopped answering, any pathname resolution can hang, and this
    /// one is outside #297's timeout guard. An earlier draft of this comment
    /// claimed more than that (#347 verify round 1).
    ///
    /// Also inherent: this is a path-based check, so it cannot bind the result
    /// to the inode Mail actually wrote. Between the save returning and this
    /// `stat`, another process could swap the destination — the size reported
    /// would then describe the substitute. Verifying "Mail wrote THIS inode"
    /// would require a descriptor handed back by Mail, which AppleScript's
    /// `save att in POSIX file` does not provide.
    ///
    /// - Parameter allowEmpty: accept a 0-byte regular file — for an attachment
    ///   that is genuinely empty (#347 C). The success string then discloses it,
    ///   because the envelope carries no size and neither the caller nor this
    ///   code can distinguish "empty on purpose" from "the bytes never arrived":
    ///   the override is a caller's attestation, and it has to leave a trace an
    ///   archive audit can find later.
    nonisolated static func verifySavedAttachmentOnDisk(
        _ result: String, savePath: String, allowEmpty: Bool = false
    ) throws -> String {
        guard result.hasPrefix("Attachment saved") else { return result }

        var st = stat()
        guard stat(savePath, &st) == 0 else {
            // ENOENT (and ENOTDIR on a missing intermediate) is genuinely
            // "nothing is there" — the state Mail's silent no-op produces, and
            // the one a download retry can still resolve. Every other errno
            // describes a path that DOES exist but could not be examined;
            // calling those "missing" both misinforms the caller and buys them
            // a pointless 30s poll (#347 verify round 1).
            let e = errno
            throw MailError.attachmentWriteUnverified(
                path: savePath,
                problem: (e == ENOENT || e == ENOTDIR) ? .missing : .statFailed(errno: e))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw MailError.attachmentWriteUnverified(
                path: savePath, problem: .notRegular(Self.fileKindName(st.st_mode)))
        }
        let size = Int64(st.st_size)
        guard size > 0 else {
            guard allowEmpty else {
                throw MailError.attachmentWriteUnverified(path: savePath, problem: .empty)
            }
            return "\(result) (0 bytes — empty write accepted via allow_empty)"
        }
        return "\(result) (\(size) bytes)"
    }

    /// Human-readable name for a `st_mode` file type, for the rejection message.
    private nonisolated static func fileKindName(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR:  return "directory"
        case S_IFIFO:  return "FIFO"
        case S_IFSOCK: return "socket"
        case S_IFBLK:  return "block device"
        case S_IFCHR:  return "character device"
        default:       return "non-regular file"
        }
    }

    func saveAttachment(id: String, mailbox: String, accountName: String, attachmentName: String, savePath: String, allowEmpty: Bool = false) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName)
        let script = """
        tell application "Mail"
            set msg to \(ref)
            repeat with att in mail attachments of msg
                if name of att is "\(appleScriptEscape(attachmentName))" then
                    save att in POSIX file "\(appleScriptEscape(savePath))"
                    return "Attachment saved to \(appleScriptEscape(savePath))"
                end if
            end repeat
            return "Attachment not found"
        end tell
        """
        return try Self.verifySavedAttachmentOnDisk(
            try runScript(script), savePath: savePath, allowEmpty: allowEmpty)
    }

    /// `save_attachment` overload with optional `accountId` (UUID) for
    /// multi-account-same-display_name disambiguation (#101).
    ///
    /// When `accountId` is non-nil and non-empty, the underlying AppleScript
    /// uses Mail.app's `(account id "<UUID>")` selector — globally unique,
    /// no collision risk. Otherwise behavior is identical to the 5-arg
    /// `saveAttachment(id:mailbox:accountName:...)` overload above.
    ///
    /// Script construction is delegated to `buildSaveAttachmentScript` (in
    /// `SaveAttachmentScriptBuilder.swift`) so the AppleScript generation
    /// is testable without spinning up the actor — same pattern as
    /// `ComposeScriptBuilder`.
    func saveAttachment(
        id: String,
        mailbox: String,
        accountId: String?,
        accountName: String,
        attachmentName: String,
        savePath: String,
        allowEmpty: Bool = false
    ) throws -> String {
        let script = buildSaveAttachmentScript(
            id: id,
            mailbox: mailbox,
            accountId: accountId,
            accountName: accountName,
            attachmentName: attachmentName,
            savePath: savePath
        )
        return try Self.verifySavedAttachmentOnDisk(
            try runScript(script), savePath: savePath, allowEmpty: allowEmpty)
    }

    /// Best-effort `save_attachment` for a server-side-only (`not_downloaded`)
    /// attachment (#272, Option B): nudge Mail to fetch the message, then
    /// re-attempt the save on a bounded poll loop until it lands or the budget
    /// is spent.
    ///
    /// This is **best-effort and unverified** — see `AttachmentDownloadScriptBuilder`
    /// for why Mail exposes no real download verb. On timeout it fails
    /// **honestly** with the `not_downloaded` guidance (never a false "saved").
    /// Only invoked when the caller opted in via `download_if_missing` AND local
    /// state already proved the part is not downloaded (`shouldAttemptDownloadRetry`).
    ///
    /// - Note: triggering the fetch mutates local Mail state (server→local), so
    ///   this stays on the AppleScript side — allowed by `r-must-direct-db` for
    ///   the C/U/D (state-changing) class; detection stayed on the SQLite path.
    func saveAttachmentRetryingForDownload(
        id: String,
        mailbox: String,
        accountId: String?,
        accountName: String,
        attachmentName: String,
        savePath: String,
        allowEmpty: Bool = false,
        enteredAfterUnverifiedWrite: AttachmentWriteProblem? = nil,
        policy: DownloadRetryPolicy = .default
    ) async throws -> String {
        // 1. Nudge Mail to materialize the message (best-effort). Errors are
        //    non-fatal — the save-retry below is the real success test — but log
        //    them so a no-op fetch is distinguishable from a working one (the
        //    r-must-direct-db stderr-observability convention).
        let trigger = buildTriggerDownloadScript(
            id: id, mailbox: mailbox, accountId: accountId, accountName: accountName)
        do {
            _ = try runScript(trigger)
        } catch {
            Diagnostics.emit(
                ("download_if_missing: fetch-trigger failed for \"\(attachmentName)\": "
                 + "\(error.localizedDescription); continuing to poll-retry the save\n"))
        }

        // 2. Poll: re-attempt the save until it succeeds or the wall-clock budget
        //    is spent. A downloaded attachment saves cleanly; a still-server-side
        //    one raises the generic -10000 (unfetched-binary class) — keep waiting.
        //    The loop is bounded by BOTH a real deadline (each save is itself a
        //    ~1-2s Mail IPC that a fixed sleep-count would ignore — so the deadline
        //    keeps real elapsed ≈ policy.timeout) AND `maxAttempts` as a hard cap
        //    (belt-and-suspenders if the clock misbehaves; the range is always
        //    valid since maxAttempts ≥ 1).
        let saveScript = buildSaveAttachmentScript(
            id: id, mailbox: mailbox, accountId: accountId, accountName: accountName,
            attachmentName: attachmentName, savePath: savePath)
        let intervalNanos = UInt64(min(max(0, policy.pollInterval), policy.timeout) * 1_000_000_000)
        let deadline = Date().addingTimeInterval(max(0, policy.timeout))
        for _ in 1...policy.maxAttempts {
            // Wait BEFORE re-checking: the fetch is asynchronous, so even the
            // first poll gives Mail one interval to land the download.
            try await Task.sleep(nanoseconds: intervalNanos)
            do {
                let result = try runScript(saveScript)
                // "Attachment saved to ..." = the binary is now local — but
                // verify the bytes actually landed (#314): a stale cache can
                // produce a 0-byte write with a success return, which is the
                // exact state this retry loop exists to escape.
                if result.hasPrefix("Attachment saved") {
                    return try Self.verifySavedAttachmentOnDisk(
                        result, savePath: savePath, allowEmpty: allowEmpty)
                }
                // A non-throwing NON-saved result ("Attachment not found") is a
                // DEFINITIVE negative — the named part isn't on this message (a
                // name-matching problem, not a download delay). Don't burn the
                // budget polling it; surface it now with the honest cause.
                throw MailError.operationFailed(
                    "save_attachment could not find an attachment named \"\(attachmentName)\" "
                    + "on the message (download_if_missing aborted — this is not a download problem).")
            } catch MailError.scriptFailed(let message, let code) {
                // -10000 = still unfetched → keep polling. A SPECIFIC code
                // (bad account/mailbox, permissions, disk full) is terminal —
                // retrying cannot fix it, so surface it immediately.
                if code != -10000 {
                    throw MailError.scriptFailed(message: message, code: code)
                }
            } catch MailError.attachmentWriteUnverified(let path, let problem) {
                // #347 — this arm did not exist. The verifier threw the generic
                // `operationFailed`, which the `scriptFailed` catch above cannot
                // match, so ONE empty write exited the whole loop — burning the
                // caller's opt-in on the very state the loop exists to escape.
                // An empty or absent file is exactly "the bytes have not landed
                // yet": consume the attempt and keep polling. A non-regular file
                // is terminal (see `shouldAttemptDownloadRetry`).
                guard shouldAttemptDownloadRetry(afterUnverifiedWrite: problem,
                                                 downloadIfMissing: true) else {
                    throw MailError.attachmentWriteUnverified(path: path, problem: problem)
                }
            }
            if Date() >= deadline { break }   // wall-clock budget spent
        }
        // Budget spent — fail honestly, and name the RIGHT failure.
        //
        // #347 verify round 1: this used to report "not downloaded" whatever
        // brought us here. On the unverified-write entry that is a fabricated
        // diagnosis — the attachment may well be local and genuinely empty, and
        // the caller was told to go fetch something that is already there. It
        // also dropped the typed error an upstream `catch` was matching on.
        if let problem = enteredAfterUnverifiedWrite {
            throw MailError.attachmentWriteUnverified(path: savePath, problem: problem)
        }
        throw MailError.operationFailed(
            "Best-effort download did not complete within \(Int(policy.timeout))s. "
            + MailSQLiteError.attachmentNotDownloaded(name: attachmentName).localizedDescription)
    }

    // MARK: - VIP Operations

    /// List VIP senders
    func listVIPSenders() throws -> [String] {
        let script = """
        tell application "Mail"
            get sender of messages of mailbox "VIP"
        end tell
        """

        return try runScriptAsList(script)
    }

    // MARK: - Rule Operations

    /// List mail rules
    func listRules() throws -> [[String: Any]] {
        let script = """
        tell application "Mail"
            get name of every rule
        end tell
        """

        let names = try runScriptAsList(script)

        return names.map { name in
            ["name": name]
        }
    }

    /// Enable/disable a rule
    func enableRule(name: String, enabled: Bool) throws -> String {
        let script = """
        tell application "Mail"
            set enabled of rule "\(appleScriptEscape(name))" to \(enabled)
            return "Rule '\(appleScriptEscape(name))' \(enabled ? "enabled" : "disabled")"
        end tell
        """
        return try runScript(script)
    }

    /// Get detailed rule information
    func getRuleDetails(name: String) throws -> [String: Any] {
        let enabledScript = """
        tell application "Mail"
            get enabled of rule "\(appleScriptEscape(name))"
        end tell
        """

        let allConditionsScript = """
        tell application "Mail"
            get all conditions must be met of rule "\(appleScriptEscape(name))"
        end tell
        """

        let stopScript = """
        tell application "Mail"
            get stop evaluating rules of rule "\(appleScriptEscape(name))"
        end tell
        """

        let enabled = try runScript(enabledScript) == "true"
        let allConditions = try runScript(allConditionsScript) == "true"
        let stopEvaluating = try runScript(stopScript) == "true"

        return [
            "name": name,
            "enabled": enabled,
            "all_conditions_must_be_met": allConditions,
            "stop_evaluating_rules": stopEvaluating
        ]
    }

    /// Create a simple mail rule.
    ///
    /// Delegates AppleScript generation to `buildCreateRuleScript` in
    /// `CreateRuleScriptBuilder.swift` (#140 — sister fix to #116). The
    /// builder enforces `ruleQualifierWhitelist` membership via
    /// `precondition` as defense-in-depth; the user-facing reject path
    /// lives in `Server.swift`'s `create_rule` handler, which validates
    /// before reaching this method.
    ///
    /// Signature unchanged from pre-extraction (#140 commit `... → ...`);
    /// for valid inputs the AppleScript output is byte-identical to the
    /// pre-extraction inline string (pinned by
    /// `CreateRuleScriptBuilderTests.testBuildCreateRuleScript_byteEquivalenceWithInlineImplementation`).
    func createRule(name: String, conditions: [[String: String]], actions: [String: Any]) throws -> String {
        let script = buildCreateRuleScript(name: name, conditions: conditions, actions: actions)
        return try runScript(script)
    }

    /// Delete a rule
    func deleteRule(name: String) throws -> String {
        let script = """
        tell application "Mail"
            delete rule "\(appleScriptEscape(name))"
            return "Rule '\(appleScriptEscape(name))' deleted"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Mail Check & Sync Operations

    /// Check for new mail.
    ///
    /// #191: optional `accountId` adds the UUID-selector escape hatch (mirrors the
    /// #104/#176 account_id overload). Delegates to `buildCheckForNewMailScript`
    /// (pure, unit-tested); the name-mode / check-all output is byte-identical to
    /// the pre-#191 inline script.
    func checkForNewMail(accountName: String? = nil, accountId: String? = nil) throws -> String {
        let script = buildCheckForNewMailScript(accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    /// Synchronize IMAP account.
    ///
    /// #191: optional `accountId` adds the UUID-selector escape hatch (mirrors the
    /// #104/#176 account_id overload). Delegates to `buildSynchronizeAccountScript`
    /// (pure, unit-tested); the name-mode output is byte-identical to the pre-#191
    /// inline script.
    func synchronizeAccount(accountName: String, accountId: String? = nil) throws -> String {
        let script = buildSynchronizeAccountScript(accountId: accountId, accountName: accountName)
        return try runScript(script)
    }

    // MARK: - Advanced Email Operations

    /// Copy email to another mailbox
    func copyEmail(id: String, fromMailbox: String, toMailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let script = buildCopyEmailScript(
            id: id, fromMailbox: fromMailbox, toMailbox: toMailbox,
            accountId: accountId, accountName: accountName
        )
        return try runScript(script)
    }

    /// Set flag color (0-6: red, orange, yellow, green, blue, purple, gray; -1 to clear)
    func setFlagColor(id: String, mailbox: String, accountId: String? = nil, accountName: String, colorIndex: Int) throws -> String {
        let script = buildSetFlagColorScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, colorIndex: colorIndex)
        return try runScript(script)
    }

    /// Set email background color
    func setBackgroundColor(id: String, mailbox: String, accountId: String? = nil, accountName: String, color: String) throws -> String {
        // Valid colors: blue, gray, green, none, orange, purple, red, yellow
        let script = buildSetBackgroundColorScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, color: color)
        return try runScript(script)
    }

    /// Mark email as junk or not junk
    func markAsJunk(id: String, mailbox: String, accountId: String? = nil, accountName: String, isJunk: Bool) throws -> String {
        let script = buildMarkAsJunkScript(id: id, mailbox: mailbox, accountId: accountId, accountName: accountName, isJunk: isJunk)
        return try runScript(script)
    }

    /// Get all email headers
    func getEmailHeaders(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
        let script = """
        tell application "Mail"
            get all headers of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Get email source (raw message)
    func getEmailSource(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> String {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)
        let script = """
        tell application "Mail"
            get source of \(ref)
        end tell
        """
        return try runScript(script)
    }

    /// Redirect email (different from forward - keeps original sender).
    ///
    /// `accountId` (UUID), when non-nil/non-empty, disambiguates accounts that
    /// share a display_name (#104 sweep). Script construction is delegated to
    /// `buildRedirectEmailScript` (`RedirectEmailScriptBuilder.swift`).
    func redirectEmail(id: String, mailbox: String, accountName: String, to: [String], accountId: String? = nil) throws -> String {
        // Issue #41 (consistency with compose/reply/forward — closes #133):
        // validate redirect recipients at the boundary. Pre-fix the AppleScript
        // builder simply `appleScriptEscape`d the addresses (no injection
        // vector) but a malformed address would land in Mail.app and surface
        // as an opaque AppleScript error or silent undeliverable redirect.
        try validateEmailAddresses(to, field: "to")
        let script = buildRedirectEmailScript(
            id: id,
            mailbox: mailbox,
            accountId: accountId,
            accountName: accountName,
            to: to
        )
        return try runScript(script)
    }

    /// Get email metadata (was forwarded, replied to, redirected)
    func getEmailMetadata(id: String, mailbox: String, accountName: String, accountId: String? = nil) throws -> [String: Any] {
        let ref = msgRef(id, mailbox: mailbox, account: accountName, accountId: accountId)

        let forwardedScript = """
        tell application "Mail"
            get was forwarded of \(ref)
        end tell
        """

        let repliedScript = """
        tell application "Mail"
            get was replied to of \(ref)
        end tell
        """

        let redirectedScript = """
        tell application "Mail"
            get was redirected of \(ref)
        end tell
        """

        let messageIdScript = """
        tell application "Mail"
            get message id of \(ref)
        end tell
        """

        let sizeScript = """
        tell application "Mail"
            get message size of \(ref)
        end tell
        """

        let wasForwarded = try runScript(forwardedScript) == "true"
        let wasReplied = try runScript(repliedScript) == "true"
        let wasRedirected = try runScript(redirectedScript) == "true"
        let msgId = try runScript(messageIdScript)
        let size = try runScript(sizeScript)

        return [
            "was_forwarded": wasForwarded,
            "was_replied_to": wasReplied,
            "was_redirected": wasRedirected,
            "message_id": msgId,
            "size_bytes": Int(size) ?? 0
        ]
    }

    // MARK: - Signature Operations

    /// List all signatures
    func listSignatures() throws -> [[String: Any]] {
        // First check if there are any signatures
        let countScript = """
        tell application "Mail"
            get count of signatures
        end tell
        """

        let countResult = try runScript(countScript)
        guard let count = Int(countResult), count > 0 else {
            return []
        }

        let namesScript = """
        tell application "Mail"
            get name of every signature
        end tell
        """

        let names = try runScriptAsList(namesScript)

        return names.map { name in
            ["name": name]
        }
    }

    /// Get signature content
    func getSignature(name: String) throws -> [String: Any] {
        let contentScript = """
        tell application "Mail"
            get content of signature "\(appleScriptEscape(name))"
        end tell
        """

        let content = try runScript(contentScript)

        return [
            "name": name,
            "content": content
        ]
    }

    // MARK: - SMTP Server Operations

    /// List SMTP servers
    func listSMTPServers() throws -> [[String: Any]] {
        let namesScript = """
        tell application "Mail"
            get name of every smtp server
        end tell
        """

        let serverNamesScript = """
        tell application "Mail"
            get server name of every smtp server
        end tell
        """

        let names = try runScriptAsList(namesScript)
        let serverNames = try runScriptAsList(serverNamesScript)

        var servers: [[String: Any]] = []
        for i in 0..<names.count {
            var server: [String: Any] = ["name": names[i]]
            if i < serverNames.count {
                server["server_name"] = serverNames[i]
            }
            servers.append(server)
        }

        return servers
    }

    // MARK: - Special Mailboxes

    /// Get special mailboxes (inbox, drafts, sent, trash, junk, outbox)
    /// Special mailbox names.
    ///
    /// #179: when an account selector (`accountId` / `accountName`) is supplied,
    /// returns *that account's* per-account special-mailbox real names (localized /
    /// provider) via the unified-children reverse-lookup; otherwise returns the
    /// app-level unified names unchanged (backward-compat). Default-nil parameters
    /// keep existing no-arg callers source-compatible.
    func getSpecialMailboxes(accountId: String? = nil, accountName: String? = nil) throws -> [String: Any] {
        // Per-account mode (#179): an account selector is supplied.
        let hasAccount = !(accountId ?? "").isEmpty || !(accountName ?? "").isEmpty
        if hasAccount {
            let script = buildSpecialMailboxNamesScript(accountId: accountId, accountName: accountName ?? "")
            let raw = try runScriptAsList(script)  // [matchedId, matchedName, matchCount, n0…n4 (leaf)] for drafts/sent/trash/junk/inbox (#249 lifted the inbox deferral; #315 removed the vacuous path walk)
            // Pure parse + pure throw-translation (both unit-tested without the actor):
            // .resolved → canonical metadata + present special names (absent omitted, D3);
            // .noMatch → operationFailed; .ambiguous → invalidParameter (#179).
            let resolution = resolveSpecialMailboxesResult(raw)
            let obj = try specialMailboxesResultOrThrow(resolution, accountId: accountId, accountName: accountName ?? "")
            // #315: `<type>_path` is NOT produced here any more. The #268
            // AppleScript container walk succeeded vacuously (references from
            // the unified container have a non-mailbox `container` on first
            // probe) and returned leaf-for-nested — 4/5 wrong on every live
            // account. Paths are joined from the Envelope Index at the Server
            // layer (`joinSpecialMailboxPath`), where `indexReader` lives.
            return obj.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        }

        // Unified mode (unchanged): app-level special mailbox names.
        let inboxScript = """
        tell application "Mail"
            get name of inbox
        end tell
        """

        let draftsScript = """
        tell application "Mail"
            get name of drafts mailbox
        end tell
        """

        let sentScript = """
        tell application "Mail"
            get name of sent mailbox
        end tell
        """

        let trashScript = """
        tell application "Mail"
            get name of trash mailbox
        end tell
        """

        let junkScript = """
        tell application "Mail"
            get name of junk mailbox
        end tell
        """

        let outboxScript = """
        tell application "Mail"
            get name of outbox
        end tell
        """

        return [
            "inbox": try runScript(inboxScript),
            "drafts": try runScript(draftsScript),
            "sent": try runScript(sentScript),
            "trash": try runScript(trashScript),
            "junk": try runScript(junkScript),
            "outbox": try runScript(outboxScript)
        ]
    }

    // MARK: - Address Operations

    /// Extract name from email address
    func extractNameFromAddress(address: String) throws -> String {
        let script = """
        tell application "Mail"
            extract name from "\(appleScriptEscape(address))"
        end tell
        """
        return try runScript(script)
    }

    /// Extract email address from full address string
    func extractAddressFrom(address: String) throws -> String {
        let script = """
        tell application "Mail"
            extract address from "\(appleScriptEscape(address))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Application Operations

    /// Get Mail application info
    func getMailAppInfo() throws -> [String: Any] {
        let versionScript = """
        tell application "Mail"
            get application version
        end tell
        """

        let fetchIntervalScript = """
        tell application "Mail"
            get fetch interval
        end tell
        """

        let backgroundCountScript = """
        tell application "Mail"
            get background activity count
        end tell
        """

        let version = try runScript(versionScript)
        let fetchInterval = try runScript(fetchIntervalScript)
        let bgCount = try runScript(backgroundCountScript)

        return [
            "version": version,
            "fetch_interval_minutes": Int(fetchInterval) ?? -1,
            "background_activity_count": Int(bgCount) ?? 0
        ]
    }

    /// Open mailto URL — via LaunchServices, NOT AppleScript (#287).
    ///
    /// The old implementation drove `tell application "Mail" / mailto` — an
    /// Apple event, so the nominally "just open a URL" tool required Automation
    /// TCC and died with -1743 on an unauthorized machine (the exact situation
    /// where a zero-TCC escape hatch is needed). `NSWorkspace.shared.open`
    /// posts the URL through LaunchServices: no Apple events, no TCC, and the
    /// mailto compose window is inherently cite-block-free (#175 — the wrapper
    /// only afflicts AppleScript-injected bodies). Trade-offs, disclosed in
    /// the result string: the window opens in the system DEFAULT mail client
    /// (which may not be Mail.app), and mailto cannot carry attachments
    /// (RFC 6068) — drag them in manually.
    func openMailtoURL(url: String) throws -> String {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "mailto" else {
            throw MailError.invalidParameter(
                "open_mailto requires a valid mailto: URL (got: '\(String(url.prefix(80)))')")
        }
        let opened = openURLOverride?(parsed) ?? NSWorkspace.shared.open(parsed)
        guard opened else {
            throw MailError.operationFailed(
                "LaunchServices could not open the mailto URL — no handler registered for "
                + "mailto: (set a default email app in System Settings → Desktop & Dock → "
                + "Default web browser section, or Mail.app → Settings → General).")
        }
        return "Handed the mailto URL to LaunchServices (zero Automation TCC — works even "
            + "where AppleScript tools fail with -1743); the compose window should open in "
            + "the system default mail client, which may not be Mail.app. Attachments cannot "
            + "be carried by mailto (RFC 6068) — drag files into the window manually. Body is "
            + "cite-block-free (mailto compose never wraps, #175)."
    }

    // MARK: - Import/Export Operations

    /// Import mailbox from file
    func importMailbox(path: String) throws -> String {
        let script = """
        tell application "Mail"
            import Mail mailbox POSIX file "\(appleScriptEscape(path))"
            return "Mailbox imported from \(appleScriptEscape(path))"
        end tell
        """
        return try runScript(script)
    }

    // MARK: - Helpers

    /// Generate AppleScript expression to reference a mailbox by display name.
    /// `mailbox "X" of account "Y"` fails for Gmail localized names (e.g. "寄件備份").
    /// `first mailbox of account "Y" whose name is "X"` always works.
    /// #180: delegates to the `resolveMailboxRef` chokepoint instead of inlining
    /// the legacy `account "<name>" whose name is "<path>"` form. Byte-identical
    /// for non-nested names at `accountId: nil` (proven against the prior inline
    /// body), and now inherits #174 nested-mailbox container chains + #101/#176
    /// account-UUID disambiguation when `accountId` is threaded through.
    private func mailboxRef(_ mailbox: String, account: String, accountId: String? = nil) -> String {
        return resolveMailboxRef(mailbox: mailbox, accountId: accountId, accountName: account)
    }

    /// Generate AppleScript reference to find a message by its numeric id.
    /// Apple Mail's `message id` refers to the RFC822 Message-ID (string),
    /// but `id` is the internal numeric identifier returned by search/list.
    /// We must use `first message ... whose id is N` instead of `message id N`.
    ///
    /// Issue #50 / #145: `id` is interpolated unquoted into `whose id is`. A
    /// release-safe numeric guard rejects non-numeric `id` — `Int(id)` succeeds
    /// only for `[+-]?\d+`; on failure an impossible id (-1) is substituted so the
    /// malicious string is never interpolated and the script fails cleanly with
    /// -1728. Server.swift's `requireMessageId` remains the user-facing contract.
    /// `internal` (not `private`) purely as the #145 test seam.
    func msgRef(_ id: String, mailbox: String, account: String, accountId: String? = nil) -> String {
        // #180: delegate to the resolveMsgRef chokepoint (was an inline build via
        // the legacy mailboxRef). Byte-identical for non-nested names at
        // accountId: nil (same #118 safeId guard, applied inside resolveMsgRef);
        // inherits #174 nested chains + #101/#176 UUID disambiguation when
        // accountId is provided.
        return resolveMsgRef(id: id, mailbox: mailbox, accountId: accountId, accountName: account)
    }
}

// MARK: - Mail Error

/// Why a post-write verification of `save_attachment` failed (#347).
///
/// Split by **whether waiting can fix it**, which is what the download-retry
/// loop needs to decide: bytes can still land in a file that is missing or
/// empty; no amount of polling turns a directory or a FIFO into a regular file.
enum AttachmentWriteProblem: Equatable {
    /// Nothing at `save_path` — Mail's save silently did nothing.
    case missing
    /// Something is there, but it is not a regular file (a directory, a FIFO,
    /// a device node, or a symlink resolving to one). Terminal.
    case notRegular(String)
    /// A regular file of zero length. Retryable, and overridable via
    /// `allow_empty` for a genuinely empty attachment.
    case empty
    /// `stat` failed for a reason that is not "nothing is there" — `ELOOP`
    /// (symlink loop), `EACCES`, `EIO`, `ENOTDIR`. Terminal: reporting these as
    /// `.missing` told the caller "no file exists" about a path that does
    /// exist, and made them eligible for a download retry that cannot help
    /// (#347 verify round 1).
    case statFailed(errno: Int32)
}

enum MailError: LocalizedError {
    case scriptCreationFailed
    case scriptFailed(message: String, code: Int)
    case invalidParameter(String)
    /// A handler-level failure whose `errorDescription` is the message verbatim
    /// — used when a raw AppleScript error (e.g. `-10000`) has been re-wrapped
    /// with an actionable, recovery-oriented explanation for the caller (#103).
    case operationFailed(String)
    /// #297: an AppleScript execution did not return within the wall-clock
    /// budget and was abandoned to keep the MCP server responsive. Distinct
    /// from `.scriptFailed(code: -1743)` (a *returned* denial): this is the
    /// *never-returns* mode (TCC prompt pending/not-determined, or Mail stuck).
    case scriptTimedOut(seconds: Int, automationGranted: Bool)

    /// #347 — `save_attachment` claimed success but the on-disk result did not
    /// verify.
    ///
    /// A **distinct case** rather than `operationFailed(String)`, and that is
    /// the whole fix for finding B: #314 threw the general-purpose container,
    /// while both download-retry sites match `scriptFailed`. A 0-byte write
    /// therefore flew straight past the `download_if_missing` recovery its own
    /// error text recommended — the retry contract could only have recognised
    /// it by matching prose, which nobody does. The payload is structured
    /// because the three problems differ in whether *waiting* can fix them.
    case attachmentWriteUnverified(path: String, problem: AttachmentWriteProblem)

    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript"
        case .scriptFailed(let message, let code):
            // #288: -1743 (errAEEventNotPermitted, Automation TCC not granted)
            // used to pass through raw — every session re-diagnosed the same
            // wall from one bare line. Rendered HERE (the single sink every
            // scriptFailed throw site funnels through) so ALL AppleScript-
            // backed tools carry the remediation, mirroring the
            // FullDiskAccessHelp precedent. Matched on the CODE, never the
            // message text (locale-dependent).
            if code == -1743 {
                return "AppleScript error (\(code)): \(message)\n" + AutomationHelp.guidance
            }
            return "AppleScript error (\(code)): \(message)"
        case .invalidParameter(let message):
            return "Invalid parameter: \(message)"
        case .operationFailed(let message):
            return message
        case .scriptTimedOut(let seconds, let automationGranted):
            // #297: the never-returns mode. Named distinctly from the -1743
            // recorded-Deny path so a stuck call surfaces an actionable error
            // within the budget instead of hanging until the MCP client drops
            // the whole server connection.
            //
            // #301: two-branch diagnosis. The old single message blamed TCC
            // ("usually means Automation permission is pending") even when the
            // preflight probe had VERIFIED granted — sending the user down the
            // tccutil dead end while the real cause (a long GUI flow crossing
            // the deadline, or Mail momentarily unresponsive) went unnamed.
            if automationGranted {
                return "AppleScript call did not return within \(seconds)s and was "
                    + "abandoned to keep the MCP server responsive (#297). Automation "
                    + "permission was verified GRANTED before the call, so this is NOT "
                    + "a TCC problem. Likely causes: a long GUI flow (sender popup / "
                    + "display-name fill / attachments on a large mailbox) legitimately "
                    + "needs longer, or Mail is momentarily unresponsive. Note the "
                    + "abandoned script cannot be cancelled and may still be running in "
                    + "Mail — check for a leftover compose window (Mail window) before "
                    + "retrying."
            }
            return "AppleScript call did not return within \(seconds)s and was "
                + "abandoned to keep the MCP server responsive (#297). This usually "
                + "means Automation permission is pending / not-determined (an "
                + "authorization prompt may be waiting but cannot be answered in this "
                + "headless context) or Mail is unresponsive.\n" + AutomationHelp.guidance
        case .attachmentWriteUnverified(let path, let problem):
            switch problem {
            case .missing:
                return "save_attachment reported success but no file exists at \(path) — "
                    + "Mail.app's save silently failed (#314). Try synchronize_account, or open "
                    + "the message in Mail so the attachment downloads, then retry."
            case .notRegular(let kind):
                // Deliberately does NOT suggest retrying: no amount of waiting
                // turns a directory or a FIFO into a regular file (#347).
                return "save_attachment reported success but \(path) is a \(kind), not a "
                    + "regular file (#347). Pass a save_path that names a file — note this "
                    + "is checked through symlinks, so a link pointing at a directory or a "
                    + "FIFO is rejected here too."
            case .statFailed(let e):
                let detail = String(cString: strerror(e))
                return "save_attachment reported success but \(path) could not be examined: "
                    + "\(detail) (errno \(e), #347). The path exists in some form — this is not "
                    + "a missing file and retrying will not change it. Check for a symlink loop, "
                    + "permissions on the containing directory, or an I/O error on the volume."
            case .empty:
                return "save_attachment reported success but wrote a 0-byte file at \(path) — "
                    + "Mail's local attachment cache likely lacks the bytes (#314). The empty "
                    + "file was left in place for inspection; try synchronize_account or "
                    + "save_attachment with download_if_missing, then retry. If the attachment "
                    + "is genuinely empty, pass allow_empty (the success string then says so)."
            }
        }
    }
}

/// #301 — tiny reference box so the pipe-drain threads can hand their data
/// back without capture-semantics friction.
final class PipeDrainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// #301 — lock-protected counter of terminated-but-unreaped osascript children
/// (SIGKILL did not take). Reference type so detached waiter threads can
/// decrement without touching actor state.
final class GuiChildAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count = max(0, count - 1); lock.unlock() }
}

/// #288 — actionable guidance for Automation-TCC denial (-1743), the
/// Automation-axis sibling of `FullDiskAccessHelp`. Centralized so the text
/// cannot drift between tools.
///
/// Attribution model (empirically corrected 2026-07-21, see #288): the signed
/// MCP binary holds its OWN Automation grant — its TCC identity is keyed to
/// the binary's signing identity (the #211 FDA lesson, Automation axis), NOT
/// to the terminal app that spawned it. On the incident machine, shell
/// `osascript` controlled Mail fine (the terminal's grant) while this binary
/// still got -1743 — two separate TCC subjects.
enum AutomationHelp {
    static let guidance = """
        Mail Automation permission is not granted TO THIS BINARY. Note: the MCP \
        binary holds its OWN Automation grant, separate from your terminal's — \
        `osascript` working in your shell does NOT mean this binary is \
        authorized. To fix: System Settings → Privacy & Security → Automation → \
        find the entry for this binary / its host (Claude Desktop extension: \
        under Claude.app) and enable Mail. If NO entry exists, a previous \
        denial is being remembered and macOS will not re-prompt — run \
        `tccutil reset AppleEvents` in Terminal, then retry any Mail tool to \
        retrigger the permission prompt. Grants are per-install and a binary \
        update can invalidate the entry (#211). Zero-TCC fallback available \
        NOW: the open_mailto tool opens a cite-block-free compose window via \
        LaunchServices (no Apple events; attachments must be dragged in \
        manually).
        """
}
