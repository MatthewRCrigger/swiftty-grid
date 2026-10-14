#if os(macOS)
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RecorderReadinessTests {
  @Test
  func missingMarkerThrowsBeforeTheCaptureCanContinue() throws {
    let recorder = try SessionRecorder.Recorder(["/bin/sleep", "5"])
    defer { recorder.session.stop() }
    var continued = false
    let started = ContinuousClock.now
    do {
      try recorder.wait(for: "missing", timeout: .milliseconds(50))
      continued = true
    } catch let error as SessionRecorder.Recorder.ReadinessFailure {
      #expect(error == .timedOut("missing"))
    }
    #expect(!continued)
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(recorder.session.isRunning)
  }

  @Test
  func finalMarkerSurvivesExitAndMissingMarkersFailPromptly() async throws {
    let recorder = try SessionRecorder.Recorder([
      "/bin/sh", "-c", "printf FINAL",
    ])
    defer { recorder.session.stop() }
    let deadline = ContinuousClock.now + .seconds(4)
    while recorder.session.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!recorder.session.isRunning)
    try recorder.wait(for: "FINAL")
    #expect(recorder.capture().text.contains("FINAL"))
    let started = ContinuousClock.now
    do {
      try recorder.wait(for: "missing")
      Issue.record("Missing marker was accepted after exit")
    } catch let error as SessionRecorder.Recorder.ReadinessFailure {
      #expect(error == .exited("missing"))
    }
    #expect(ContinuousClock.now - started < .seconds(1))
  }
}
#endif
