import Metal
import MetalKit
@testable import SwifttyCore
import Testing

struct RendererFailureTests {
  enum Presentation: CaseIterable { case view, nonblocking, layer }
  enum Fault: CaseIterable {
    case buffer, command, encoder, postTexture, postEncoder
  }

  private func renderer() throws -> MetalRenderer {
    try MetalRenderer(
      device: #require(RendererTests.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(),
    )
  }

  private func texture(
    _ renderer: MetalRenderer,
    width: Int = 32,
  ) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: width,
      mipmapped: false,
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    return try #require(renderer.device.makeTexture(descriptor: descriptor))
  }

  @Test(.enabled(if: RendererTests.device != nil), arguments: Fault.allCases)
  func refusalReturnsPermitAndAllowsCompleteRetry(_ fault: Fault) throws {
    let renderer = try renderer()
    let target = try texture(renderer)
    let snapshot = TerminalSession(columns: 8, rows: 2).snapshot()
    let buffer = renderer.makeInstanceBuffer
    let command = renderer.makeCommandBuffer
    let encoder = renderer.makeRenderEncoder
    let intermediate = renderer.makeIntermediateTexture
    if fault == .postTexture || fault == .postEncoder {
      try renderer.setPostProcessShader(
        """
        float4 postprocess(float2 p, texture2d<float> s, constant PostUniforms &u) {
            return s.read(uint2(p));
        }
        """
      )
    }
    switch fault {
    case .buffer: renderer.makeInstanceBuffer = { _ in nil }
    case .command: renderer.makeCommandBuffer = { nil }
    case .encoder: renderer.makeRenderEncoder = { _, _ in nil }
    case .postTexture: renderer.makeIntermediateTexture = { _ in nil }
    case .postEncoder:
      var count = 0
      renderer.makeRenderEncoder = { command, pass in
        count += 1
        return count == 2 ? nil : encoder(command, pass)
      }
    }
    #expect(throws: RendererError.self) {
      try renderer.render(snapshot, to: target)
    }
    #expect(renderer.waitUntilIdle(timeout: .now() + .milliseconds(100)))
    renderer.makeInstanceBuffer = buffer
    renderer.makeCommandBuffer = command
    renderer.makeRenderEncoder = encoder
    renderer.makeIntermediateTexture = intermediate
    let actual = try RendererTests()
      .render(renderer, snapshot, width: 32, height: 32, )
    let reference = try self.renderer()
    if fault == .postTexture || fault == .postEncoder {
      try reference.setPostProcessShader(
        """
        float4 postprocess(float2 p, texture2d<float> s, constant PostUniforms &u) {
            return s.read(uint2(p));
        }
        """
      )
    }
    let expected = try RendererTests()
      .render(reference, snapshot, width: 32, height: 32, )
    #expect(actual.pixels == expected.pixels)
  }

  @Test(.enabled(if: RendererTests.device != nil), arguments: [false, true])
  func failedGrowthPreservesThePreviousBuffer(_ postProcessing: Bool) throws {
    let renderer = try renderer()
    let target = try texture(renderer)
    if postProcessing {
      try renderer.setPostProcessShader(
        """
        float4 postprocess(float2 p, texture2d<float> s, constant PostUniforms &u) {
            return s.read(uint2(p));
        }
        """
      )
    }
    let small = TerminalSession(columns: 8, rows: 2).snapshot()
    try renderer.render(small, to: target).waitUntilCompleted()
    let allocate = renderer.makeInstanceBuffer
    let allocateTexture = renderer.makeIntermediateTexture
    if postProcessing {
      renderer.makeIntermediateTexture = { _ in nil }
    } else {
      renderer.makeInstanceBuffer = { _ in nil }
    }
    let large = TerminalSession(columns: 16, rows: 4).snapshot()
    let largeTarget = try texture(renderer, width: 64)
    #expect(throws: RendererError.self) {
      try renderer.render(large, to: largeTarget)
    }
    #expect(renderer.waitUntilIdle(timeout: .now() + .milliseconds(100)))
    // The prior allocation remains usable even while growth is refused.
    let command = try renderer.render(small, to: target)
    command.waitUntilCompleted()
    #expect(command.status == .completed)
    renderer.makeInstanceBuffer = allocate
    renderer.makeIntermediateTexture = allocateTexture
    let retry = try renderer.render(large, to: largeTarget)
    retry.waitUntilCompleted()
    #expect(retry.status == .completed)
  }

  @Test
  func invalidOrUnrepresentableBufferSizesAreRefusedBeforeAllocation() throws {
    for dimensions in [(0, 1), (1, -1), (Int.max, 2), (65536, 65536)] {
      #expect(throws: RendererError.self) {
        try MetalRenderer.instanceBufferLength(
          columns: dimensions.0,
          rows: dimensions.1,
          maximum: Int.max,
        )
      }
    }
    #expect(throws: RendererError.self) {
      try MetalRenderer.instanceBufferLength(columns: 8, rows: 2, maximum: 1)
    }
  }

  @MainActor
  @Test(
    .enabled(if: RendererTests.device != nil),
    arguments: Presentation.allCases,
  )
  func presentationRefusesUnallocatedFramesAndCanRetry(
    _ path: Presentation,
  ) throws {
    let renderer = try renderer()
    let view = MTKView(
      frame: CGRect(x: 0, y: 0, width: 32, height: 32),
      device: renderer.device,
    )
    view.isPaused = true
    try #require(view.currentDrawable != nil)
    let layer = try #require(view.layer as? CAMetalLayer)
    let snapshot = TerminalSession(columns: 8, rows: 2).snapshot()
    let allocate = renderer.makeInstanceBuffer
    renderer.makeInstanceBuffer = { _ in nil }
    switch path {
    case .view: #expect(!renderer.draw(snapshot, in: view))
    case .nonblocking:
      #expect(renderer.tryDraw(snapshot, in: view) == .resourceUnavailable)
    case .layer:
      #expect(!renderer.draw(snapshot, options: RenderOptions(), layer: layer, )
      )
    }
    #expect(renderer.waitUntilIdle(timeout: .now() + .milliseconds(100)))
    renderer.makeInstanceBuffer = allocate
    switch path {
    case .view: #expect(renderer.draw(snapshot, in: view))
    case .nonblocking:
      #expect(renderer.tryDraw(snapshot, in: view) == .submitted)
    case .layer:
      #expect(renderer.draw(snapshot, options: RenderOptions(), layer: layer, ))
    }
    #expect(renderer.waitUntilIdle(timeout: .now() + .seconds(2)))
  }
}
