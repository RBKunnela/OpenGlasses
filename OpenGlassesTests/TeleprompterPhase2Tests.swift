import XCTest
@testable import OpenGlasses

/// Headless tests for Teleprompter Phase 2: the voice-command parser, the HUD screen
/// builder, the saved-script store, and the service's deterministic pacing/control seams.
/// The live `SFSpeechRecognizer` shell is device-pending and not exercised here — the
/// service is driven through `ingestForPacing` / `handleVoiceCommand` / `autoScrollStep`
/// with no audio source wired, so everything stays headless.
@MainActor
final class TeleprompterPhase2Tests: XCTestCase {

    // MARK: - Voice commands

    func testCommandParsesCoreVerbs() {
        XCTAssertEqual(TeleprompterCommand.parse("next"), .next)
        XCTAssertEqual(TeleprompterCommand.parse("go back"), .back)
        XCTAssertEqual(TeleprompterCommand.parse("pause"), .pause)
        XCTAssertEqual(TeleprompterCommand.parse("keep going"), .resume)
        XCTAssertEqual(TeleprompterCommand.parse("start over"), .restart)
        XCTAssertEqual(TeleprompterCommand.parse("stop teleprompter"), .stop)
        XCTAssertEqual(TeleprompterCommand.parse("faster"), .faster)
        XCTAssertEqual(TeleprompterCommand.parse("slow down"), .slower)
    }

    func testCommandToleratesFillerAndPunctuation() {
        XCTAssertEqual(TeleprompterCommand.parse("ok, faster!"), .faster)
        XCTAssertEqual(TeleprompterCommand.parse("um... pause"), .pause)
    }

    func testCommandIgnoresEmbeddedWords() {
        // A control word inside a sentence the reader is speaking must NOT fire.
        XCTAssertNil(TeleprompterCommand.parse("we moved faster than ever before"))
        XCTAssertNil(TeleprompterCommand.parse("the next chapter of our story"))
        XCTAssertNil(TeleprompterCommand.parse("hello everyone"))
    }

    // MARK: - Screen builder

    func testScreenBuilderEmphasizesActiveLineAndShowsProgress() {
        let window = TeleprompterWindow(lines: ["Active line", "Following line"],
                                        activeLineIndex: 0, progress: 0.5)
        let screen = TeleprompterScreen.build(title: "Speech", window: window,
                                              progress: 0.5, wpm: 130, isPaused: false)
        XCTAssertEqual(screen.title, "Speech")
        // First line is the status row (meta) and carries the progress cue.
        XCTAssertEqual(screen.lines.first?.emphasis, .meta)
        XCTAssertTrue(screen.lines.first?.text.contains("50%") ?? false)
        XCTAssertTrue(screen.lines.first?.text.contains("130 wpm") ?? false)
        // The active line is primary; the rest are secondary.
        XCTAssertEqual(screen.lines[1].emphasis, .primary)
        XCTAssertEqual(screen.lines[2].emphasis, .secondary)
        // Four controls with stable ids.
        XCTAssertEqual(screen.items.map(\.id),
                       [TeleprompterScreen.ItemID.pause, TeleprompterScreen.ItemID.slower,
                        TeleprompterScreen.ItemID.faster, TeleprompterScreen.ItemID.stop])
        XCTAssertEqual(screen.items.first?.label, "Pause")
    }

    func testScreenBuilderFlipsPauseLabelAndAnnotatesStatus() {
        let window = TeleprompterWindow(lines: ["x"], activeLineIndex: 0, progress: 0.1)
        let screen = TeleprompterScreen.build(title: "t", window: window,
                                              progress: 0.1, wpm: 130, isPaused: true)
        XCTAssertEqual(screen.items.first?.label, "Resume")
        XCTAssertTrue(screen.lines.first?.text.contains("paused") ?? false)
    }

    func testScreenControlButtonActionsRoute() {
        var stopped = false
        let controls = TeleprompterScreen.Controls(stop: { stopped = true })
        let window = TeleprompterWindow(lines: ["x"], activeLineIndex: 0, progress: 0)
        let screen = TeleprompterScreen.build(title: "t", window: window, progress: 0,
                                              wpm: 130, isPaused: false, controls: controls)
        screen.items.first { $0.id == TeleprompterScreen.ItemID.stop }?.action()
        XCTAssertTrue(stopped)
    }

    // MARK: - Store

    private func makeTempStore() -> (TeleprompterScriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (TeleprompterScriptStore(directory: dir), dir)
    }

    func testStoreAddsNewestFirstAndPersists() {
        let (store, dir) = makeTempStore()
        store.add(title: "First", text: "one")
        store.add(title: "Second", text: "two")
        XCTAssertEqual(store.scripts.map(\.title), ["Second", "First"])

        // A fresh store over the same directory loads what was saved.
        let reloaded = TeleprompterScriptStore(directory: dir)
        XCTAssertEqual(reloaded.scripts.map(\.title), ["Second", "First"])
    }

    func testStoreDeriveTitleAndLookup() {
        let (store, _) = makeTempStore()
        let saved = store.add(title: "", text: "Opening remarks\nthen the body")
        XCTAssertEqual(saved.title, "Opening remarks")
        XCTAssertEqual(store.script(named: "opening REMARKS")?.id, saved.id)
        XCTAssertEqual(store.script(withID: saved.id)?.id, saved.id)

        store.delete(id: saved.id)
        XCTAssertTrue(store.scripts.isEmpty)
    }

    // MARK: - Service: audio pacing

    private func makeService() -> TeleprompterService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeleprompterService(store: TeleprompterScriptStore(directory: dir))
    }

    func testServiceStartsAndMirrorsScreenDeviceLess() {
        let service = makeService()
        let script = TeleprompterScript.parse(title: "Demo", text: "the quick brown fox")
        service.start(script, mode: .audioPaced)
        XCTAssertTrue(service.isActive)
        XCTAssertFalse(service.isPaused)
        XCTAssertEqual(service.cursor, 0)
        // currentScreen updates even with no glasses wired — that's the on-phone mirror.
        XCTAssertNotNil(service.currentScreen)
        XCTAssertEqual(service.currentScreen?.title, "Demo")
    }

    func testServiceAdvancesCursorFromSpeech() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "the quick brown fox jumps over"),
                      mode: .audioPaced)
        service.ingestForPacing("the quick brown")
        XCTAssertEqual(service.cursor, 3)
        service.ingestForPacing("brown fox jumps")
        XCTAssertEqual(service.cursor, 5)
    }

    func testServicePauseHoldsAndResumeContinues() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "the quick brown fox jumps over"),
                      mode: .audioPaced)
        service.ingestForPacing("the quick")
        let held = service.cursor
        service.pause()
        service.ingestForPacing("brown fox")     // ignored while paused
        XCTAssertEqual(service.cursor, held)
        XCTAssertTrue(service.isPaused)
        service.resume()
        XCTAssertFalse(service.isPaused)
        service.ingestForPacing("brown fox")
        XCTAssertGreaterThan(service.cursor, held)
    }

    func testServiceReachingEndFinishes() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "alpha beta gamma"), mode: .audioPaced)
        service.ingestForPacing("alpha beta gamma")
        XCTAssertFalse(service.isActive)         // ran to the end → session ends
        XCTAssertNil(service.currentScreen)
    }

    // MARK: - Service: voice control

    func testVoiceCommandFasterSlowerNudgesPace() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "a b c d e"), mode: .audioPaced)
        service.setWPM(130)
        XCTAssertTrue(service.handleVoiceCommand("faster"))
        XCTAssertGreaterThan(service.pacing.wpm, 130)
        let fast = service.pacing.wpm
        XCTAssertTrue(service.handleVoiceCommand("slower"))
        XCTAssertLessThan(service.pacing.wpm, fast)
    }

    func testVoiceCommandNextBackMoveByLine() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "line one\nline two\nline three"),
                      mode: .voice)
        XCTAssertEqual(service.cursor, 0)
        XCTAssertTrue(service.handleVoiceCommand("next"))
        XCTAssertEqual(service.cursor, 2)        // first token of line "line two"
        XCTAssertTrue(service.handleVoiceCommand("back"))
        XCTAssertEqual(service.cursor, 0)
    }

    func testVoiceCommandStopEndsSession() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "a b c"), mode: .voice)
        XCTAssertTrue(service.handleVoiceCommand("stop teleprompter"))
        XCTAssertFalse(service.isActive)
    }

    func testVoiceCommandIgnoredWhenInactive() {
        let service = makeService()
        XCTAssertFalse(service.handleVoiceCommand("faster"))
    }

    // MARK: - Service: auto-scroll

    func testAutoScrollStepAdvancesOneWord() {
        let service = makeService()
        service.start(TeleprompterScript.parse(title: "t", text: "a b c d"), mode: .autoScroll)
        XCTAssertEqual(service.cursor, 0)
        service.autoScrollStep()
        XCTAssertEqual(service.cursor, 1)
        service.autoScrollStep()
        XCTAssertEqual(service.cursor, 2)
    }
}
