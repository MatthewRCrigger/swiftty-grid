import AppKit
import MuxNavigation
import SwiftMuxProtocol
@testable import Swiftty
import Testing

private actor RouterService: AttentionService {
  let epoch = ServerInstanceID()
  var items: [OccurrenceID: AttentionItem] = [:]
  private(set) var seen: [OccurrenceID] = []
  private(set) var opened: [PaneTarget] = []
  private var holdSeen = false
  private var seenGate: CheckedContinuation<Void, Never>?

  func holdNextSeen() { holdSeen = true }
  var waitingForSeen: Bool { seenGate != nil }
  func releaseSeen() {
    seenGate?.resume()
    seenGate = nil
  }

  func add(_ item: AttentionItem) { items[item.occurrence] = item }
  func serviceEpoch() async throws(AttentionServiceError) -> ServerInstanceID {
    epoch
  }
  func locate(
    _ ref: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation {
    guard let item = items[ref.occurrence] else {
      return .init(availability: .missing)
    }
    return .init(
      availability: .available,
      item: item,
      workspace: item.workspace,
      pane: item.source.pane
    )
  }
  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState {
    .init(generation: 1, holder: nil)
  }
  func open(
    _ target: PaneTarget,
    takeover: UInt64?
  ) async throws(AttentionServiceError) { opened.append(target) }
  func markSeen(_ ref: AttentionReference) async throws(AttentionServiceError) {
    seen.append(ref.occurrence)
    if holdSeen {
      holdSeen = false
      await withCheckedContinuation { seenGate = $0 }
    }
  }
  func close() async {}
}

private struct RouterConnector: AttentionServiceConnector {
  let service: RouterService
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService { service }
}

@MainActor
private final class RouterPrompts {
  var pending: [CheckedContinuation<NSApplication.ModalResponse, Never>] = []
  var returned = 0
  func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    let result = await withCheckedContinuation { pending.append($0) }
    returned += 1
    return result
  }
  func answerFirst(_ response: NSApplication.ModalResponse) {
    pending.removeFirst().resume(returning: response)
  }
  func finish() {
    let waiting = pending
    pending = []
    for continuation in waiting {
      continuation.resume(returning: .alertSecondButtonReturn)
    }
  }
}

@MainActor
@Suite(.serialized)
struct AttentionRouterTests {
  @Test(
    arguments: [
      NSApplication.ModalResponse.alertFirstButtonReturn,
      .alertSecondButtonReturn,
    ],
    [false, true]
  )
  func oldPromptCannotOpenOrCancelANewerLink(
    response: NSApplication.ModalResponse,
    sameItem: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = RouterService()
    let host = NavigationHost(id: UUID(), name: "Test")
    func item(_ name: String) -> AttentionItem {
      let source = AttentionSource(
        serviceEpoch: service.epoch,
        pane: PaneID(),
        terminalEpoch: TerminalEpochID(),
        recordPath: "",
        recordIncarnation: 1
      )
      return AttentionItem(
        occurrence: OccurrenceID(),
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: .open,
        status: .init(
          source: source,
          state: .blocked,
          app: name,
          updatedAt: Date()
        ),
        createdAt: Date(),
        updatedAt: Date(),
        revision: 1
      )
    }
    let first = item("first")
    let second = sameItem ? first : item("second")
    await service.add(first)
    await service.add(second)
    let navigator = AttentionNavigator(
      configuration: .init(),
      hosts: StaticHostDirectory([host]),
      connector: RouterConnector(service: service)
    )
    let prompts = RouterPrompts()
    let router = AttentionLinkRouter(
      navigator: navigator,
      ownsWorkspace: { _ in false },
      present: prompts.present
    )
    defer {
      navigator.cancel();
      prompts.finish()
    }
    router.handle(
      AttentionLink.customURL(
        for: AttentionDestination(hostProfileID: host.id, item: first)
      )
    )
    #expect(await until { prompts.pending.count == 1 })
    router.handle(
      AttentionLink.customURL(
        for: AttentionDestination(hostProfileID: host.id, item: second)
      )
    )
    #expect(await until { prompts.pending.count == 2 })
    prompts.answerFirst(response)
    #expect(await until { prompts.returned == 1 })
    // Synchronize with the old render task's service calls, if any.
    for _ in 0 ..< 10 { await Task.yield() }
    #expect(await service.opened.isEmpty)
    #expect(await service.seen.isEmpty)
    guard case let .ready(preview) = navigator.state else {
      Issue.record("Old alert changed the newer navigation: \(navigator.state)")
      return
    }
    #expect(preview.item.occurrence == second.occurrence)
  }

  @Test
  func oldSeenReplyCannotActivateTheNewerNavigation() async throws {
    _ = NSApplication.shared
    let service = RouterService()
    let host = NavigationHost(id: UUID(), name: "Test")
    let source = AttentionSource(
      serviceEpoch: service.epoch,
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    let first = AttentionItem(
      occurrence: OccurrenceID(),
      source: source,
      workspace: WorkspaceID(),
      tab: nil,
      category: .needsYou,
      resolution: .open,
      status: .init(source: source, state: .blocked, updatedAt: Date()),
      createdAt: Date(),
      updatedAt: Date(),
      revision: 1
    )
    var second = first
    second.occurrence = OccurrenceID()
    await service.add(first)
    await service.add(second)
    await service.holdNextSeen()
    let navigator = AttentionNavigator(
      configuration: .init(),
      hosts: StaticHostDirectory([host]),
      connector: RouterConnector(service: service)
    )
    let prompts = RouterPrompts()
    let router = AttentionLinkRouter(
      navigator: navigator,
      ownsWorkspace: { _ in false },
      present: prompts.present
    )
    defer {
      navigator.cancel();
      prompts.finish()
    }
    router.handle(
      AttentionLink.customURL(
        for: AttentionDestination(hostProfileID: host.id, item: first)
      )
    )
    #expect(await until { prompts.pending.count == 1 })
    prompts.answerFirst(.alertFirstButtonReturn)
    #expect(await until { await service.waitingForSeen })
    router.handle(
      AttentionLink.customURL(
        for: AttentionDestination(hostProfileID: host.id, item: second)
      )
    )
    #expect(await until { prompts.pending.count == 1 })
    await service.releaseSeen()
    for _ in 0 ..< 10 { await Task.yield() }
    #expect(await service.opened.isEmpty)
    #expect(await service.seen == [first.occurrence])
    guard case let .ready(preview) = navigator.state else {
      Issue.record(
        "Delayed seen reply changed the newer navigation: \(navigator.state)"
      )
      return
    }
    #expect(preview.item.occurrence == second.occurrence)
  }

  private func until(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
      if await predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
  }
}
