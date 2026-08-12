import CoreVideo
import Flutter
import Metal
import QuartzCore
import simd

/// Flutter Texture backed by a transparent Metal render target.
final class GlamARMetalTexture: NSObject, FlutterTexture {
  private let lock = NSLock()
  private var latestPixelBuffer: CVPixelBuffer?

  func publish(_ pixelBuffer: CVPixelBuffer) {
    lock.lock()
    latestPixelBuffer = pixelBuffer
    lock.unlock()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    let buffer = latestPixelBuffer
    lock.unlock()
    guard let buffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func clearReference() {
    lock.lock()
    latestPixelBuffer = nil
    lock.unlock()
  }
}

private struct GlamARLipVertex {
  var position: SIMD2<Float>
  var uv: SIMD2<Float>
  var edgeAlpha: Float
  var padding: Float = 0
}

private struct GlamARLipUniforms {
  var baseColor: SIMD4<Float>
  var parameters: SIMD4<Float>
}

private struct GlamARColorMeshUniforms {
  var primaryColor: SIMD4<Float>
  var secondaryColor: SIMD4<Float>
  // x: opacity, y: shimmer, z: vertical gradient bias, w: reserved.
  var parameters: SIMD4<Float>
}

private struct GlamARRenderFrame {
  static let magic: UInt32 = 0x52414C47
  static let version: UInt16 = 1
  static let headerLength = 48
  static let materialHeaderLength = 4
  static let materialLayerStride = 12
  static let lipLayerIndex = 5
  static let blushLayerIndex = 1
  static let eyeshadowLayerIndex = 2
  static let browLayerIndex = 3
  static let eyelinerLayerIndex = 4

  let submissionSequence: UInt64
  let sourceSequence: UInt64
  var landmarks: [Float]
  let material: [Float]
  let face: [Float]

  init?(data: Data) {
    guard data.count >= Self.headerLength,
          data.uint32LE(at: 0) == Self.magic,
          data.uint16LE(at: 4) == Self.version
    else { return nil }

    let landmarkCount = Int(data.uint32LE(at: 40))
    let materialCount = Int(data.uint16LE(at: 44))
    let faceCount = Int(data.uint16LE(at: 46))
    guard landmarkCount >= 468,
          materialCount >= Self.materialHeaderLength + 6 * Self.materialLayerStride,
          faceCount >= 16
    else { return nil }

    let landmarkFloatCount = landmarkCount * 3
    let expectedLength = Self.headerLength +
      (landmarkFloatCount + materialCount + faceCount) * MemoryLayout<Float>.size
    guard data.count == expectedLength else { return nil }

    submissionSequence = data.uint64LE(at: 8)
    sourceSequence = data.uint64LE(at: 16)
    var offset = Self.headerLength
    landmarks = data.float32LEArray(at: offset, count: landmarkFloatCount)
    offset += landmarkFloatCount * MemoryLayout<Float>.size
    material = data.float32LEArray(at: offset, count: materialCount)
    offset += materialCount * MemoryLayout<Float>.size
    face = data.float32LEArray(at: offset, count: faceCount)
  }

  var lipLayerOffset: Int {
    Self.materialHeaderLength + Self.lipLayerIndex * Self.materialLayerStride
  }

  var blushLayerOffset: Int {
    Self.materialHeaderLength + Self.blushLayerIndex * Self.materialLayerStride
  }

  var eyeshadowLayerOffset: Int {
    Self.materialHeaderLength + Self.eyeshadowLayerIndex * Self.materialLayerStride
  }

  var browLayerOffset: Int {
    Self.materialHeaderLength + Self.browLayerIndex * Self.materialLayerStride
  }

  var eyelinerLayerOffset: Int {
    Self.materialHeaderLength + Self.eyelinerLayerIndex * Self.materialLayerStride
  }

  func point(_ landmarkIndex: Int) -> SIMD2<Float> {
    let offset = landmarkIndex * 3
    return SIMD2<Float>(landmarks[offset], landmarks[offset + 1])
  }
}

private extension Data {
  func uint16LE(at offset: Int) -> UInt16 {
    UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  func uint32LE(at offset: Int) -> UInt32 {
    UInt32(self[offset]) |
      UInt32(self[offset + 1]) << 8 |
      UInt32(self[offset + 2]) << 16 |
      UInt32(self[offset + 3]) << 24
  }

  func uint64LE(at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in 0..<8 {
      value |= UInt64(self[offset + byte]) << UInt64(byte * 8)
    }
    return value
  }

  func float32LEArray(at offset: Int, count: Int) -> [Float] {
    var values = [Float](repeating: 0, count: count)
    values.withUnsafeMutableBytes { target in
      copyBytes(to: target, from: offset..<(offset + target.count))
    }
    return values
  }
}

private final class GlamARMetalLipRenderer {
  static let outerLip = [
    61, 185, 40, 39, 37, 0, 267, 269, 270, 409,
    291, 375, 321, 405, 314, 17, 84, 181, 91, 146,
  ]
  static let innerLip = [
    78, 191, 80, 81, 82, 13, 312, 311, 310, 415,
    308, 324, 318, 402, 317, 14, 87, 178, 88, 95,
  ]
  static let sideAEyeUpper = [33, 246, 161, 160, 159, 158, 157, 173, 133]
  static let sideBEyeUpper = [362, 398, 384, 385, 386, 387, 388, 466, 263]
  static let sideABrow = [70, 63, 105, 66, 107]
  static let sideBBrow = [336, 296, 334, 293, 300]
  static let ribbonFractions: [Float] = [-1, -0.42, 0.42, 1]
  static let ribbonAlphas: [Float] = [0, 1, 1, 0]
  static let featherFractions: [Float] = [0, 0.12, 0.72, 1]
  static let featherAlphas: [Float] = [0, 1, 0.56, 0]
  static let cheekFractions: [Float] = [0, 0.46, 0.76, 1]
  static let cheekAlphas: [Float] = [1, 0.78, 0.34, 0]
  static let cheekSegments = 24

  let pixelWidth: Int
  let pixelHeight: Int
  let flutterTexture = GlamARMetalTexture()

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let colorMeshPipeline: MTLRenderPipelineState
  private let foundationVertexBuffer: MTLBuffer
  private let foundationIndexBuffer: MTLBuffer
  private let foundationIndexCount: Int
  private let lipIndexBuffer: MTLBuffer
  private let lipIndexCount: Int
  private let eyeshadowIndexBuffer: MTLBuffer
  private let eyeshadowIndexCount: Int
  private let cheekIndexBuffer: MTLBuffer
  private let cheekIndexCount: Int
  private let browIndexBuffer: MTLBuffer
  private let browIndexCount: Int
  private let eyelinerIndexBuffer: MTLBuffer
  private let eyelinerIndexCount: Int
  private let renderQueue = DispatchQueue(
    label: "com.glamar.metal.makeup",
    qos: .userInteractive
  )
  private var textureCache: CVMetalTextureCache?
  private var pixelBufferPool: CVPixelBufferPool?
  private var lastSubmissionSequence: UInt64 = 0
  private var lastSourceSequence: UInt64 = 0
  private var stabilizedLandmarks = [Float]()
  private var foundationVertices = [GlamARLipVertex](
    repeating: GlamARLipVertex(position: .zero, uv: .zero, edgeAlpha: 0),
    count: 468
  )

  init?(pixelWidth: Int, pixelHeight: Int, foundationIndices: [UInt16]) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue()
    else { return nil }
    self.device = device
    self.commandQueue = commandQueue
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight

    do {
      let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
      guard let vertex = library.makeFunction(name: "glamarLipVertex"),
            let fragment = library.makeFunction(name: "glamarLipFragment"),
            let colorFragment = library.makeFunction(name: "glamarColorMeshFragment")
      else { return nil }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.label = "GlamAR native lip material"
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
      descriptor.label = "GlamAR native color mesh material"
      descriptor.fragmentFunction = colorFragment
      colorMeshPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      return nil
    }
    let lipIndices = Self.makeLipIndices()
    guard !foundationIndices.isEmpty,
          let foundationVertexBuffer = device.makeBuffer(
            length: 468 * MemoryLayout<GlamARLipVertex>.stride,
            options: .storageModeShared
          ),
          let foundationIndexBuffer = device.makeBuffer(
            bytes: foundationIndices,
            length: foundationIndices.count * MemoryLayout<UInt16>.stride
          ), let lipIndexBuffer = device.makeBuffer(
      bytes: lipIndices,
      length: lipIndices.count * MemoryLayout<UInt16>.stride
    ) else { return nil }
    self.foundationVertexBuffer = foundationVertexBuffer
    self.foundationIndexBuffer = foundationIndexBuffer
    foundationIndexCount = foundationIndices.count
    self.lipIndexBuffer = lipIndexBuffer
    lipIndexCount = lipIndices.count
    let eyeshadowIndices = Self.makeStripIndices(
      ringCount: Self.featherFractions.count,
      pointCount: Self.sideAEyeUpper.count,
      closed: false
    )
    let cheekIndices = Self.makeStripIndices(
      ringCount: Self.cheekFractions.count,
      pointCount: Self.cheekSegments,
      closed: true
    )
    let browIndices = Self.makeStripIndices(
      ringCount: Self.ribbonFractions.count,
      pointCount: Self.sideABrow.count,
      closed: false
    )
    let eyelinerIndices = Self.makeStripIndices(
      ringCount: Self.ribbonFractions.count,
      pointCount: Self.sideAEyeUpper.count + 2,
      closed: false
    )
    guard let eyeshadowIndexBuffer = device.makeBuffer(
      bytes: eyeshadowIndices,
      length: eyeshadowIndices.count * MemoryLayout<UInt16>.stride
    ), let cheekIndexBuffer = device.makeBuffer(
      bytes: cheekIndices,
      length: cheekIndices.count * MemoryLayout<UInt16>.stride
    ), let browIndexBuffer = device.makeBuffer(
      bytes: browIndices,
      length: browIndices.count * MemoryLayout<UInt16>.stride
    ), let eyelinerIndexBuffer = device.makeBuffer(
      bytes: eyelinerIndices,
      length: eyelinerIndices.count * MemoryLayout<UInt16>.stride
    ) else { return nil }
    self.eyeshadowIndexBuffer = eyeshadowIndexBuffer
    eyeshadowIndexCount = eyeshadowIndices.count
    self.cheekIndexBuffer = cheekIndexBuffer
    cheekIndexCount = cheekIndices.count
    self.browIndexBuffer = browIndexBuffer
    browIndexCount = browIndices.count
    self.eyelinerIndexBuffer = eyelinerIndexBuffer
    eyelinerIndexCount = eyelinerIndices.count

    CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    let poolAttributes: [CFString: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey: 3,
    ]
    let pixelAttributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: pixelWidth,
      kCVPixelBufferHeightKey: pixelHeight,
      kCVPixelBufferMetalCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    CVPixelBufferPoolCreate(
      nil,
      poolAttributes as CFDictionary,
      pixelAttributes as CFDictionary,
      &pixelBufferPool
    )
    guard pixelBufferPool != nil, textureCache != nil,
          let initialBuffer = makePixelBuffer()
    else { return nil }
    CVPixelBufferLockBaseAddress(initialBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(initialBuffer) {
      memset(baseAddress, 0, CVPixelBufferGetDataSize(initialBuffer))
    }
    CVPixelBufferUnlockBaseAddress(initialBuffer, [])
    flutterTexture.publish(initialBuffer)
  }

  func render(data: Data, completion: @escaping (Bool) -> Void) {
    renderQueue.async { [weak self] in
      guard let self, var frame = GlamARRenderFrame(data: data) else {
        completion(false)
        return
      }
      guard frame.submissionSequence > self.lastSubmissionSequence else {
        completion(false)
        return
      }
      self.lastSubmissionSequence = frame.submissionSequence
      self.stabilizeResidualNoise(&frame)
      self.render(frame: frame, completion: completion)
    }
  }

  func clear(completion: @escaping (Bool) -> Void) {
    renderQueue.async { [weak self] in
      self?.stabilizedLandmarks.removeAll(keepingCapacity: true)
      self?.lastSourceSequence = 0
      self?.render(frame: nil, completion: completion)
    }
  }

  private func stabilizeResidualNoise(_ frame: inout GlamARRenderFrame) {
    guard stabilizedLandmarks.count == frame.landmarks.count else {
      stabilizedLandmarks = frame.landmarks
      lastSourceSequence = frame.sourceSequence
      return
    }
    let predictionTick = frame.sourceSequence == lastSourceSequence
    for index in stride(from: 0, to: frame.landmarks.count, by: 3) {
      let deltaX = frame.landmarks[index] - stabilizedLandmarks[index]
      let deltaY = frame.landmarks[index + 1] - stabilizedLandmarks[index + 1]
      let pixelMotion = sqrt(
        deltaX * deltaX * Float(pixelWidth * pixelWidth) +
          deltaY * deltaY * Float(pixelHeight * pixelHeight)
      )
      let alpha: Float
      if pixelMotion < (predictionTick ? 0.1 : 0.14) {
        alpha = 0
      } else if pixelMotion < 0.42 {
        alpha = predictionTick ? 0.78 : 0.68
      } else {
        alpha = 1
      }
      stabilizedLandmarks[index] += deltaX * alpha
      stabilizedLandmarks[index + 1] += deltaY * alpha
      let depthAlpha: Float = pixelMotion < 0.42 ? 0.68 : 1
      stabilizedLandmarks[index + 2] +=
        (frame.landmarks[index + 2] - stabilizedLandmarks[index + 2]) * depthAlpha
      frame.landmarks[index] = stabilizedLandmarks[index]
      frame.landmarks[index + 1] = stabilizedLandmarks[index + 1]
      frame.landmarks[index + 2] = stabilizedLandmarks[index + 2]
    }
    lastSourceSequence = frame.sourceSequence
  }

  private func render(
    frame: GlamARRenderFrame?,
    completion: @escaping (Bool) -> Void
  ) {
    guard let pixelBuffer = makePixelBuffer(),
          let cache = textureCache
    else {
      completion(false)
      return
    }
    var cvTexture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil,
      cache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      pixelWidth,
      pixelHeight,
      0,
      &cvTexture
    )
    guard status == kCVReturnSuccess,
          let cvTexture,
          let target = CVMetalTextureGetTexture(cvTexture),
          let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      completion(false)
      return
    }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      completion(false)
      return
    }
    encoder.label = "GlamAR makeup mesh pass"
    if let frame {
      drawFoundation(frame, encoder: encoder)
      drawBlush(frame, encoder: encoder)
      drawEyeshadow(frame, encoder: encoder)
      drawBrows(frame, encoder: encoder)
      drawEyeliner(frame, encoder: encoder)
      if let geometry = makeLipGeometry(frame) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(
          geometry.vertices,
          length: geometry.vertices.count * MemoryLayout<GlamARLipVertex>.stride,
          index: 0
        )
        var uniforms = geometry.uniforms
        encoder.setFragmentBytes(
          &uniforms,
          length: MemoryLayout<GlamARLipUniforms>.stride,
          index: 0
        )
        encoder.drawIndexedPrimitives(
          type: .triangle,
          indexCount: lipIndexCount,
          indexType: .uint16,
          indexBuffer: lipIndexBuffer,
          indexBufferOffset: 0
        )
      }
    }
    encoder.endEncoding()

    commandBuffer.addCompletedHandler { [weak self] buffer in
      guard let self, buffer.status == .completed else {
        completion(false)
        return
      }
      self.flutterTexture.publish(pixelBuffer)
      completion(true)
    }
    commandBuffer.commit()
  }

  private func makePixelBuffer() -> CVPixelBuffer? {
    guard let pool = pixelBufferPool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    return pixelBuffer
  }

  private func drawFoundation(
    _ frame: GlamARRenderFrame,
    encoder: MTLRenderCommandEncoder
  ) {
    let layer = GlamARRenderFrame.materialHeaderLength
    guard frame.material[layer] > 0.5 else { return }
    let faceWidth = max(simd_length(frame.point(454) - frame.point(234)), 0.0001)
    let center = frame.point(1)
    let runtimeQuality = frame.face[13]
    let detail = frame.material[layer + 2]
    for index in 0..<468 {
      let point = frame.point(index)
      let normalizedX = (point.x - center.x) / faceWidth
      let normalizedY = (point.y - center.y) / faceWidth
      let radial = sqrt(normalizedX * normalizedX * 1.18 + normalizedY * normalizedY * 0.68)
      let contour = Self.smoothStep(0.18, 0.68, radial)
      let centerHighlight = 1 - Self.smoothStep(0.08, 0.46, radial)
      let depth = frame.landmarks[index * 3 + 2]
      let depthShade = min(max((-depth - 0.015) * 2.6, -0.12), 0.14)
      let tone = min(max(
        0.52 + centerHighlight * (0.12 + detail * 0.11) - contour * detail * 0.19 +
          depthShade * detail * runtimeQuality,
        0.22
      ), 0.82)
      foundationVertices[index] = GlamARLipVertex(
        position: SIMD2<Float>(point.x * 2 - 1, 1 - point.y * 2),
        uv: SIMD2<Float>(tone, radial),
        edgeAlpha: 1
      )
    }
    var uniforms = colorMeshUniforms(
      frame,
      layerOffset: layer,
      opacity: frame.material[layer + 1] * frame.face[7] * frame.face[12] *
        (frame.face[15] > 0.5 ? 0.045 : 0.105),
      shimmer: detail * runtimeQuality,
      verticalBias: 2
    )
    foundationVertices.withUnsafeBytes { source in
      guard let baseAddress = source.baseAddress else { return }
      memcpy(foundationVertexBuffer.contents(), baseAddress, source.count)
    }
    encoder.setRenderPipelineState(colorMeshPipeline)
    encoder.setVertexBuffer(foundationVertexBuffer, offset: 0, index: 0)
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<GlamARColorMeshUniforms>.stride,
      index: 0
    )
    encoder.drawIndexedPrimitives(
      type: .triangle,
      indexCount: foundationIndexCount,
      indexType: .uint16,
      indexBuffer: foundationIndexBuffer,
      indexBufferOffset: 0
    )
  }

  private func drawEyeshadow(
    _ frame: GlamARRenderFrame,
    encoder: MTLRenderCommandEncoder
  ) {
    let layer = frame.eyeshadowLayerOffset
    guard frame.material[layer] > 0.5 else { return }
    let sides: [([Int], Bool)] = [
      (Self.sideAEyeUpper, true),
      (Self.sideBEyeUpper, false),
    ]
    for (indices, sideA) in sides {
      guard let vertices = makeEyeshadowGeometry(frame, indices: indices, sideA: sideA)
      else { continue }
      let visibility = sideA ? frame.face[5] : frame.face[6]
      let sideExposure = sideA ? frame.face[2] : frame.face[3]
      let openness = sideA ? frame.face[9] : frame.face[10]
      let sideOpacity = min(max((0.76 + sideExposure * 0.46) * visibility, 0.1), 1.12)
      let opacity = min(max(
        frame.material[layer + 1] * sideOpacity * frame.face[12] *
          (frame.face[15] > 0.5 ? 0.15 : 0.34),
        0
      ), 0.42)
      var uniforms = colorMeshUniforms(
        frame,
        layerOffset: layer,
        opacity: opacity,
        shimmer: frame.material[layer + 2] * frame.face[8] * (0.68 + openness * 0.32),
        verticalBias: 1
      )
      encoder.setRenderPipelineState(colorMeshPipeline)
      encoder.setVertexBytes(
        vertices,
        length: vertices.count * MemoryLayout<GlamARLipVertex>.stride,
        index: 0
      )
      encoder.setFragmentBytes(
        &uniforms,
        length: MemoryLayout<GlamARColorMeshUniforms>.stride,
        index: 0
      )
      encoder.drawIndexedPrimitives(
        type: .triangle,
        indexCount: eyeshadowIndexCount,
        indexType: .uint16,
        indexBuffer: eyeshadowIndexBuffer,
        indexBufferOffset: 0
      )
    }
  }

  private func makeEyeshadowGeometry(
    _ frame: GlamARRenderFrame,
    indices: [Int],
    sideA: Bool
  ) -> [GlamARLipVertex]? {
    let points = indices.map(frame.point)
    guard let first = points.first, let last = points.last else { return nil }
    let axis = last - first
    let eyeWidth = simd_length(axis)
    guard eyeWidth > 0.0001 else { return nil }
    var normal = SIMD2<Float>(-axis.y, axis.x) / eyeWidth
    if normal.y > 0 { normal = -normal }
    let layer = frame.eyeshadowLayerOffset
    let openness = sideA ? frame.face[9] : frame.face[10]
    let blinkStability = 0.62 + openness * 0.38
    let lift = eyeWidth * (0.2 + frame.material[layer + 2] * 0.14) * blinkStability
    var vertices: [GlamARLipVertex] = []
    vertices.reserveCapacity(Self.featherFractions.count * points.count)
    for ring in Self.featherFractions.indices {
      let fraction = Self.featherFractions[ring]
      for pointIndex in points.indices {
        let taper = sin(Float(pointIndex) / Float(points.count - 1) * .pi)
        let point = points[pointIndex] + normal * lift * fraction * (0.58 + taper * 0.42)
        vertices.append(GlamARLipVertex(
          position: SIMD2<Float>(point.x * 2 - 1, 1 - point.y * 2),
          uv: SIMD2<Float>(Float(pointIndex) / Float(points.count - 1), fraction),
          edgeAlpha: Self.featherAlphas[ring]
        ))
      }
    }
    return vertices
  }

  private func drawBlush(
    _ frame: GlamARRenderFrame,
    encoder: MTLRenderCommandEncoder
  ) {
    let layer = frame.blushLayerOffset
    guard frame.material[layer] > 0.5 else { return }
    let faceWidth = simd_length(frame.point(454) - frame.point(234))
    guard faceWidth > 0.0001 else { return }
    let faceAxis = simd_normalize(frame.point(454) - frame.point(234))
    let normal = SIMD2<Float>(-faceAxis.y, faceAxis.x)
    let sides: [(Int, Int, Int, Bool)] = [
      (117, 234, 50, true),
      (346, 454, 280, false),
    ]
    for (anchorIndex, edgeIndex, highIndex, sideA) in sides {
      let anchor = frame.point(anchorIndex)
      let edge = frame.point(edgeIndex)
      let highTarget = frame.point(highIndex)
      let highMix = 0.12 + frame.material[layer + 2] * 0.2
      let center = simd_mix(anchor, highTarget, SIMD2<Float>(repeating: highMix))
      let pulled = simd_mix(center, frame.point(1), SIMD2<Float>(repeating: 0.05))
      let localSpan = simd_length(anchor - edge)
      let perspective = min(max(localSpan / (faceWidth * 0.2), 0.72), 1.06)
      let halfWidth = localSpan * (1.35 + frame.material[layer + 2] * 0.34) * 0.5
      let halfHeight = localSpan * (0.84 + (1 - frame.material[layer + 2]) * 0.26) * 0.5
      var vertices: [GlamARLipVertex] = []
      vertices.reserveCapacity(Self.cheekFractions.count * Self.cheekSegments)
      for ring in Self.cheekFractions.indices {
        let radius = Self.cheekFractions[ring]
        for segment in 0..<Self.cheekSegments {
          let angle = Float(segment) / Float(Self.cheekSegments) * 2 * .pi
          let point = pulled + faceAxis * cos(angle) * halfWidth * radius +
            normal * sin(angle) * halfHeight * radius
          vertices.append(GlamARLipVertex(
            position: SIMD2<Float>(point.x * 2 - 1, 1 - point.y * 2),
            uv: SIMD2<Float>(0.5 + cos(angle) * radius * 0.5,
                             0.5 + sin(angle) * radius * 0.5),
            edgeAlpha: Self.cheekAlphas[ring]
          ))
        }
      }
      let visibility = sideA ? frame.face[5] : frame.face[6]
      let sideExposure = sideA ? frame.face[2] : frame.face[3]
      let sideOpacity = min(max((0.76 + sideExposure * 0.46) * visibility, 0.1), 1.12)
      var uniforms = colorMeshUniforms(
        frame,
        layerOffset: layer,
        opacity: frame.material[layer + 1] * perspective * sideOpacity * frame.face[12] *
          (frame.face[15] > 0.5 ? 0.13 : 0.31),
        shimmer: 0,
        verticalBias: 0
      )
      encoder.setRenderPipelineState(colorMeshPipeline)
      encoder.setVertexBytes(
        vertices,
        length: vertices.count * MemoryLayout<GlamARLipVertex>.stride,
        index: 0
      )
      encoder.setFragmentBytes(
        &uniforms,
        length: MemoryLayout<GlamARColorMeshUniforms>.stride,
        index: 0
      )
      encoder.drawIndexedPrimitives(
        type: .triangle,
        indexCount: cheekIndexCount,
        indexType: .uint16,
        indexBuffer: cheekIndexBuffer,
        indexBufferOffset: 0
      )
    }
  }

  private func colorMeshUniforms(
    _ frame: GlamARRenderFrame,
    layerOffset: Int,
    opacity: Float,
    shimmer: Float,
    verticalBias: Float
  ) -> GlamARColorMeshUniforms {
    var primary = SIMD3<Float>(
      frame.material[layerOffset + 3],
      frame.material[layerOffset + 4],
      frame.material[layerOffset + 5]
    )
    var secondary = SIMD3<Float>(
      frame.material[layerOffset + 8],
      frame.material[layerOffset + 9],
      frame.material[layerOffset + 10]
    )
    let warmth = frame.face[4]
    let target = warmth >= 0
      ? SIMD3<Float>(1, 0.698, 0.561)
      : SIMD3<Float>(0.624, 0.737, 0.91)
    let amount = SIMD3<Float>(repeating: abs(warmth) * 0.075)
    primary = simd_mix(primary, target, amount)
    secondary = simd_mix(secondary, target, amount)
    return GlamARColorMeshUniforms(
      primaryColor: SIMD4<Float>(primary.x, primary.y, primary.z, 1),
      secondaryColor: SIMD4<Float>(secondary.x, secondary.y, secondary.z, 1),
      parameters: SIMD4<Float>(min(max(opacity, 0), 0.46), shimmer, verticalBias, 0)
    )
  }

  private func drawBrows(
    _ frame: GlamARRenderFrame,
    encoder: MTLRenderCommandEncoder
  ) {
    let layer = frame.browLayerOffset
    guard frame.material[layer] > 0.5 else { return }
    let sides: [([Int], Bool)] = [
      (Self.sideABrow, true),
      (Self.sideBBrow, false),
    ]
    for (indices, sideA) in sides {
      let points = indices.map(frame.point)
      guard let first = points.first, let last = points.last else { continue }
      let span = simd_length(last - first)
      guard span > 0.0001 else { continue }
      let width = span * (0.05 + frame.material[layer + 2] * 0.035)
      let vertices = makeRibbonGeometry(points, halfWidth: width * 0.5, taper: true)
      let visibility = sideA ? frame.face[5] : frame.face[6]
      let sideExposure = sideA ? frame.face[2] : frame.face[3]
      let sideOpacity = min(max((0.76 + sideExposure * 0.46) * visibility, 0.1), 1.12)
      var uniforms = colorMeshUniforms(
        frame,
        layerOffset: layer,
        opacity: frame.material[layer + 1] * sideOpacity * frame.face[12] * 0.62,
        shimmer: frame.material[layer + 2] * frame.face[8],
        verticalBias: 3
      )
      drawColorMesh(
        vertices: vertices,
        uniforms: &uniforms,
        indexBuffer: browIndexBuffer,
        indexCount: browIndexCount,
        encoder: encoder
      )
    }
  }

  private func drawEyeliner(
    _ frame: GlamARRenderFrame,
    encoder: MTLRenderCommandEncoder
  ) {
    let layer = frame.eyelinerLayerOffset
    guard frame.material[layer] > 0.5 else { return }
    let sides: [([Int], Bool, Bool)] = [
      (Self.sideAEyeUpper, true, true),
      (Self.sideBEyeUpper, false, false),
    ]
    for (indices, sideA, tailAtStart) in sides {
      var points = indices.map(frame.point)
      guard let first = points.first, let last = points.last else { continue }
      let eyeWidth = simd_length(last - first)
      guard eyeWidth > 0.0001 else { continue }
      let outer = tailAtStart ? first : last
      let direction: Float = outer.x < frame.point(1).x ? -1 : 1
      let tailLength = eyeWidth * (0.1 + frame.material[layer + 2] * 0.24)
      let control = SIMD2<Float>(
        outer.x + direction * tailLength * 0.55,
        outer.y - tailLength * 0.08
      )
      let tail = SIMD2<Float>(
        outer.x + direction * tailLength,
        outer.y - tailLength * (0.16 + frame.material[layer + 2] * 0.22)
      )
      if tailAtStart {
        points.insert(control, at: 0)
        points.insert(tail, at: 0)
      } else {
        points.append(control)
        points.append(tail)
      }
      let openness = sideA ? frame.face[9] : frame.face[10]
      let lineWidth = eyeWidth * (0.02 + frame.material[layer + 2] * 0.02) *
        (0.78 + openness * 0.22)
      let vertices = makeRibbonGeometry(points, halfWidth: lineWidth * 0.5, taper: true)
      let visibility = sideA ? frame.face[5] : frame.face[6]
      let sideExposure = sideA ? frame.face[2] : frame.face[3]
      let detailOpacity = min(max(
        (0.76 + sideExposure * 0.46) * visibility * frame.face[8],
        0.06
      ), 1.12)
      var uniforms = colorMeshUniforms(
        frame,
        layerOffset: layer,
        opacity: frame.material[layer + 1] * detailOpacity * frame.face[12] * 0.9,
        shimmer: frame.material[layer + 2] * frame.face[8],
        verticalBias: 4
      )
      drawColorMesh(
        vertices: vertices,
        uniforms: &uniforms,
        indexBuffer: eyelinerIndexBuffer,
        indexCount: eyelinerIndexCount,
        encoder: encoder
      )
    }
  }

  private func makeRibbonGeometry(
    _ points: [SIMD2<Float>],
    halfWidth: Float,
    taper: Bool
  ) -> [GlamARLipVertex] {
    var vertices: [GlamARLipVertex] = []
    vertices.reserveCapacity(Self.ribbonFractions.count * points.count)
    for ribbon in Self.ribbonFractions.indices {
      for pointIndex in points.indices {
        let previous = points[max(0, pointIndex - 1)]
        let next = points[min(points.count - 1, pointIndex + 1)]
        let tangent = next - previous
        let length = max(simd_length(tangent), 0.0001)
        let normal = SIMD2<Float>(-tangent.y, tangent.x) / length
        let progress = Float(pointIndex) / Float(max(points.count - 1, 1))
        let endpointFade = taper ? (0.48 + sin(progress * .pi) * 0.52) : 1
        let point = points[pointIndex] + normal * halfWidth *
          Self.ribbonFractions[ribbon] * endpointFade
        let longitudinalFade = taper ? min(min(progress / 0.16, (1 - progress) / 0.16), 1) : 1
        vertices.append(GlamARLipVertex(
          position: SIMD2<Float>(point.x * 2 - 1, 1 - point.y * 2),
          uv: SIMD2<Float>(progress, (Self.ribbonFractions[ribbon] + 1) * 0.5),
          edgeAlpha: Self.ribbonAlphas[ribbon] * max(longitudinalFade, 0)
        ))
      }
    }
    return vertices
  }

  private func drawColorMesh(
    vertices: [GlamARLipVertex],
    uniforms: inout GlamARColorMeshUniforms,
    indexBuffer: MTLBuffer,
    indexCount: Int,
    encoder: MTLRenderCommandEncoder
  ) {
    encoder.setRenderPipelineState(colorMeshPipeline)
    encoder.setVertexBytes(
      vertices,
      length: vertices.count * MemoryLayout<GlamARLipVertex>.stride,
      index: 0
    )
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<GlamARColorMeshUniforms>.stride,
      index: 0
    )
    encoder.drawIndexedPrimitives(
      type: .triangle,
      indexCount: indexCount,
      indexType: .uint16,
      indexBuffer: indexBuffer,
      indexBufferOffset: 0
    )
  }

  private func makeLipGeometry(
    _ frame: GlamARRenderFrame
  ) -> (vertices: [GlamARLipVertex], uniforms: GlamARLipUniforms)? {
    let lip = frame.lipLayerOffset
    guard frame.material[lip] > 0.5 else { return nil }

    let outer = Self.outerLip.map(frame.point)
    var inner = Self.innerLip.map(frame.point)
    let mouthCutout = Self.smoothStep(0.03, 0.34, frame.face[11])
    let lipSeamY = (frame.point(13).y + frame.point(14).y) * 0.5
    for index in inner.indices {
      inner[index].y = lipSeamY + (inner[index].y - lipSeamY) * mouthCutout
    }
    let all = outer + inner
    let minX = all.map(\.x).min() ?? 0
    let maxX = all.map(\.x).max() ?? 1
    let minY = all.map(\.y).min() ?? 0
    let maxY = all.map(\.y).max() ?? 1
    let width = max(maxX - minX, 0.0001)
    let height = max(maxY - minY, 0.0001)
    let ringFractions: [Float] = [0, 0.09, 0.79, 1]
    let ringAlphas: [Float] = [0, 1, 1, 0]
    var vertices: [GlamARLipVertex] = []
    vertices.reserveCapacity(ringFractions.count * outer.count)
    for ring in 0..<ringFractions.count {
      for pointIndex in 0..<outer.count {
        let point = simd_mix(outer[pointIndex], inner[pointIndex],
                             SIMD2<Float>(repeating: ringFractions[ring]))
        vertices.append(
          GlamARLipVertex(
            position: SIMD2<Float>(point.x * 2 - 1, 1 - point.y * 2),
            uv: SIMD2<Float>((point.x - minX) / width, (point.y - minY) / height),
            edgeAlpha: ringAlphas[ring]
          )
        )
      }
    }

    var color = SIMD3<Float>(
      frame.material[lip + 3],
      frame.material[lip + 4],
      frame.material[lip + 5]
    )
    let warmth = frame.face[4]
    let warmthTarget = warmth >= 0
      ? SIMD3<Float>(1, 0.698, 0.561)
      : SIMD3<Float>(0.624, 0.737, 0.91)
    color = simd_mix(color, warmthTarget, SIMD3<Float>(repeating: abs(warmth) * 0.075))
    let centralOpacity = min(max((0.78 + frame.face[1] * 0.42) * frame.face[7], 0.64), 1.1)
    let materialMix: Float = frame.face[15] > 0.5 ? 0.34 : 1
    let alpha = min(max(
      frame.material[lip + 1] * centralOpacity * frame.face[12] * materialMix,
      0
    ), 1)
    let finish = frame.material[2]
    let glossStability = 1 - frame.face[11] * 0.34
    return (
      vertices,
      GlamARLipUniforms(
        baseColor: SIMD4<Float>(color.x, color.y, color.z, 1),
        parameters: SIMD4<Float>(alpha, finish, glossStability, frame.face[8])
      )
    )
  }

  private static func makeLipIndices() -> [UInt16] {
    let ringCount = 4
    let pointCount = outerLip.count
    var indices: [UInt16] = []
    indices.reserveCapacity((ringCount - 1) * pointCount * 6)
    for ring in 0..<(ringCount - 1) {
      for pointIndex in 0..<pointCount {
        let next = (pointIndex + 1) % pointCount
        let a = UInt16(ring * pointCount + pointIndex)
        let b = UInt16(ring * pointCount + next)
        let c = UInt16((ring + 1) * pointCount + pointIndex)
        let d = UInt16((ring + 1) * pointCount + next)
        indices.append(contentsOf: [a, b, c, b, d, c])
      }
    }
    return indices
  }

  private static func makeStripIndices(
    ringCount: Int,
    pointCount: Int,
    closed: Bool
  ) -> [UInt16] {
    let segmentCount = closed ? pointCount : pointCount - 1
    var indices: [UInt16] = []
    indices.reserveCapacity((ringCount - 1) * segmentCount * 6)
    for ring in 0..<(ringCount - 1) {
      for pointIndex in 0..<segmentCount {
        let next = closed ? (pointIndex + 1) % pointCount : pointIndex + 1
        let a = UInt16(ring * pointCount + pointIndex)
        let b = UInt16(ring * pointCount + next)
        let c = UInt16((ring + 1) * pointCount + pointIndex)
        let d = UInt16((ring + 1) * pointCount + next)
        indices.append(contentsOf: [a, b, c, b, d, c])
      }
    }
    return indices
  }

  private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    let t = min(max((value - edge0) / max(edge1 - edge0, 0.0001), 0), 1)
    return t * t * (3 - 2 * t)
  }

  static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct LipVertex {
    float2 position;
    float2 uv;
    float edgeAlpha;
    float padding;
  };
  struct LipRaster {
    float4 position [[position]];
    float2 uv;
    float edgeAlpha;
  };
  struct LipUniforms {
    float4 baseColor;
    float4 parameters;
  };
  struct ColorMeshUniforms {
    float4 primaryColor;
    float4 secondaryColor;
    float4 parameters;
  };

  vertex LipRaster glamarLipVertex(
    const device LipVertex *vertices [[buffer(0)]],
    uint vertexId [[vertex_id]]) {
    LipRaster out;
    out.position = float4(vertices[vertexId].position, 0.0, 1.0);
    out.uv = vertices[vertexId].uv;
    out.edgeAlpha = vertices[vertexId].edgeAlpha;
    return out;
  }

  fragment float4 glamarLipFragment(
    LipRaster in [[stage_in]],
    constant LipUniforms &uniforms [[buffer(0)]]) {
    float alpha = saturate(in.edgeAlpha * uniforms.parameters.x * 0.72);
    float verticalTone = mix(0.88, 1.035, smoothstep(0.08, 0.94, in.uv.y));
    float3 color = uniforms.baseColor.rgb * verticalTone;
    float2 glossDelta = (in.uv - float2(0.5, 0.68)) / float2(0.34, 0.115);
    float gloss = exp(-dot(glossDelta, glossDelta) * 2.2) *
      uniforms.parameters.y * uniforms.parameters.z * uniforms.parameters.w * 0.24;
    color = mix(color, float3(1.0), gloss);
    return float4(color * alpha, alpha);
  }

  fragment float4 glamarColorMeshFragment(
    LipRaster in [[stage_in]],
    constant ColorMeshUniforms &uniforms [[buffer(0)]]) {
    float alpha = saturate(in.edgeAlpha * uniforms.parameters.x);
    if (uniforms.parameters.z > 2.5) {
      if (uniforms.parameters.z > 3.5) {
        float rootDensity = 1.0 - smoothstep(0.56, 1.0, in.uv.y);
        float directionTaper = 0.7 + 0.3 * sin(in.uv.x * 3.1415927);
        float body = mix(0.34, 1.0, rootDensity) * directionTaper;
        float3 liner = mix(
          uniforms.primaryColor.rgb * 0.72,
          uniforms.secondaryColor.rgb,
          saturate(uniforms.parameters.y) * 0.18
        );
        return float4(liner * alpha * body, alpha * body);
      }
      float density = mix(9.0, 18.0, saturate(uniforms.parameters.y));
      float strandCoordinate = fract(in.uv.x * density - in.uv.y * 0.82);
      float strand = 1.0 - smoothstep(0.08, 0.31, abs(strandCoordinate - 0.5));
      float body = 0.42 + strand * 0.58;
      float3 brow = mix(
        uniforms.primaryColor.rgb * 0.78,
        uniforms.secondaryColor.rgb,
        strand * 0.28
      );
      return float4(brow * alpha * body, alpha * body);
    }
    if (uniforms.parameters.z > 1.5) {
      float luminance = mix(0.93, 1.07, saturate(in.uv.x));
      float contourFalloff = 1.0 - smoothstep(0.76, 1.08, in.uv.y);
      float3 foundation = uniforms.primaryColor.rgb * luminance;
      return float4(foundation * alpha * contourFalloff, alpha * contourFalloff);
    }
    float eyeGradient = smoothstep(0.06, 0.9, in.uv.y);
    float cheekGradient = saturate(length(in.uv - float2(0.5)) * 1.45);
    float gradient = mix(cheekGradient, eyeGradient, uniforms.parameters.z);
    float3 color = mix(
      uniforms.primaryColor.rgb,
      uniforms.secondaryColor.rgb,
      gradient * 0.62
    );
    float2 shimmerDelta = (in.uv - float2(0.52, 0.43)) / float2(0.34, 0.28);
    float shimmer = exp(-dot(shimmerDelta, shimmerDelta) * 2.0) *
      uniforms.parameters.y * uniforms.parameters.z * 0.18;
    color = mix(color, float3(1.0), shimmer);
    return float4(color * alpha, alpha);
  }
  """
}

/// Owns the iOS application-level channels and texture registration.
final class MetalMakeupBridge: NSObject {
  private let registrar: FlutterApplicationRegistrar
  private let controlChannel: FlutterMethodChannel
  private let frameChannel: FlutterBasicMessageChannel
  private var renderer: GlamARMetalLipRenderer?
  private var textureId: Int64?

  init(registrar: FlutterApplicationRegistrar) {
    self.registrar = registrar
    controlChannel = FlutterMethodChannel(
      name: "glamar/ar_metal/control",
      binaryMessenger: registrar.messenger()
    )
    frameChannel = FlutterBasicMessageChannel(
      name: "glamar/ar_metal/frames",
      binaryMessenger: registrar.messenger(),
      codec: FlutterBinaryCodec.sharedInstance()
    )
    super.init()
    controlChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    frameChannel.setMessageHandler { [weak self] message, reply in
      guard let self,
            let renderer = self.renderer,
            let data = message as? Data
      else {
        reply(nil)
        return
      }
      let startedAt = CACurrentMediaTime()
      renderer.render(data: data) { [weak self] rendered in
        DispatchQueue.main.async {
          if rendered, let self, let textureId = self.textureId {
            self.registrar.textures().textureFrameAvailable(textureId)
          }
          let elapsedMs = Float((CACurrentMediaTime() - startedAt) * 1_000)
          var response = Data([rendered ? 1 : 0])
          withUnsafeBytes(of: elapsedMs.bitPattern.littleEndian) {
            response.append(contentsOf: $0)
          }
          let thermalLevel: UInt8 = switch ProcessInfo.processInfo.thermalState {
          case .nominal: 0
          case .fair: 1
          case .serious: 3
          case .critical: 4
          @unknown default: 2
          }
          response.append(thermalLevel)
          reply(response)
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      if let renderer, let textureId {
        result(surfaceResult(renderer: renderer, textureId: textureId))
        return
      }
      let arguments = call.arguments as? [String: Any]
      let requestedWidth = arguments?["pixelWidth"] as? Int ?? 720
      let requestedHeight = arguments?["pixelHeight"] as? Int ?? 1280
      guard let topology = arguments?["faceMeshIndices"] as? FlutterStandardTypedData,
            topology.data.count >= 6,
            topology.data.count % 2 == 0
      else {
        result(FlutterError(
          code: "invalid_face_topology",
          message: "Dense face mesh topology is missing or invalid.",
          details: nil
        ))
        return
      }
      let foundationIndices = stride(from: 0, to: topology.data.count, by: 2).map {
        topology.data.uint16LE(at: $0)
      }
      let width = min(max(requestedWidth, 360), 1080)
      let height = min(max(requestedHeight, 640), 1920)
      guard let renderer = GlamARMetalLipRenderer(
        pixelWidth: width,
        pixelHeight: height,
        foundationIndices: foundationIndices
      ) else {
        result(FlutterError(
          code: "metal_unavailable",
          message: "Metal makeup renderer is unavailable on this device.",
          details: nil
        ))
        return
      }
      let textureId = registrar.textures().register(renderer.flutterTexture)
      guard textureId != 0 else {
        result(FlutterError(
          code: "texture_registration_failed",
          message: "Unable to register Metal makeup texture.",
          details: nil
        ))
        return
      }
      self.renderer = renderer
      self.textureId = textureId
      registrar.textures().textureFrameAvailable(textureId)
      result(surfaceResult(renderer: renderer, textureId: textureId))
    case "clear":
      guard let renderer else {
        result(nil)
        return
      }
      renderer.clear { [weak self] cleared in
        DispatchQueue.main.async {
          if cleared, let self, let textureId = self.textureId {
            self.registrar.textures().textureFrameAvailable(textureId)
          }
          result(nil)
        }
      }
    case "dispose":
      disposeRenderer()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func surfaceResult(
    renderer: GlamARMetalLipRenderer,
    textureId: Int64
  ) -> [String: Any] {
    [
      "textureId": textureId,
      "pixelWidth": renderer.pixelWidth,
      "pixelHeight": renderer.pixelHeight,
    ]
  }

  private func disposeRenderer() {
    if let textureId {
      registrar.textures().unregisterTexture(textureId)
    }
    renderer?.flutterTexture.clearReference()
    renderer = nil
    textureId = nil
  }

  deinit {
    controlChannel.setMethodCallHandler(nil)
    frameChannel.setMessageHandler(nil)
    disposeRenderer()
  }
}
