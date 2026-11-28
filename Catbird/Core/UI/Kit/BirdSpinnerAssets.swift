//
//  BirdSpinnerAssets.swift
//  Catbird
//
//  Loads the 3D mascot (`Resources/Models/Catbird.usdz`) once and hands every
//  BirdSpinner a cheap clone: clones share mesh, texture and material
//  resources, so N spinners cost one model in memory. Also builds the cool
//  image-based fill light the spinners share.
//

import CoreGraphics
import Foundation
import RealityKit

@MainActor
enum BirdSpinnerAssets {
  /// Emissive strength of the eye gradient. The exported 1.0 reads as a
  /// glowing LED under real-time lighting; ~0.3 keeps a subtle inner sheen.
  static let eyeGlowIntensity: Float = 0.3

  private static var templateTask: Task<Entity, Error>?
  private static var environmentTask: Task<EnvironmentResource, Error>?

  /// A fresh clone of the bird, normalised to 1 unit tall, centred on the
  /// origin, Y up, beak toward +Z.
  static func makeBird() async throws -> Entity {
    let task = templateTask ?? Task { try await loadTemplate() }
    templateTask = task
    do {
      return try await task.value.clone(recursive: true)
    } catch {
      templateTask = nil  // allow a retry on the next appearance
      throw error
    }
  }

  /// Cool sky-over-floor gradient used as image-based fill so the matte head
  /// keeps soft shading on the side away from the warm key light.
  static func fillEnvironment() async throws -> EnvironmentResource {
    let task = environmentTask ?? Task { try await makeFillEnvironment() }
    environmentTask = task
    return try await task.value
  }

  private static func loadTemplate() async throws -> Entity {
    guard let url = Bundle.main.url(forResource: "Catbird", withExtension: "usdz") else {
      throw CocoaError(.fileNoSuchFile)
    }
    let model = try await Entity(contentsOf: url)
    softenEyeGlow(in: model)

    let root = Entity()
    root.name = "BirdSpinnerRoot"
    root.addChild(model)
    // Size by the whole bird, but pivot on the centre of the head (the
    // gumdrop), so turning reads as the bird looking around rather than the
    // protruding beak dragging the whole model around a shifted axis.
    let bounds = model.visualBounds(relativeTo: root)
    let height = max(bounds.extents.y, .ulpOfOne)
    let scale = 1 / height
    let pivot = model.findEntity(named: "Head")?.visualBounds(relativeTo: root).center ?? bounds.center
    model.scale *= SIMD3(repeating: scale)
    model.position = -pivot * scale
    return root
  }

  private static func softenEyeGlow(in entity: Entity) {
    let name = entity.name
    if name.hasPrefix("Eye"), !name.contains("Glint"),
      var model = entity.components[ModelComponent.self] {
      model.materials = model.materials.map { material in
        guard var pbr = material as? PhysicallyBasedMaterial else { return material }
        pbr.emissiveIntensity = eyeGlowIntensity
        return pbr
      }
      entity.components.set(model)
    }
    for child in entity.children { softenEyeGlow(in: child) }
  }

  private static func makeFillEnvironment() async throws -> EnvironmentResource {
    let width = 64
    let height = 32
    guard
      let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
      let gradient = CGGradient(
        colorSpace: sRGB,
        colorComponents: [
          0.66, 0.76, 0.98, 1,  // cool sky (top)
          0.46, 0.53, 0.68, 1,  // horizon
          0.18, 0.22, 0.32, 1  // dim floor (bottom)
        ],
        locations: [0, 0.5, 1], count: 3)
    else { throw CocoaError(.featureUnsupported) }
    // CGContext origin is bottom-left; equirect row 0 is the zenith.
    context.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
    guard let image = context.makeImage() else { throw CocoaError(.featureUnsupported) }
    return try await EnvironmentResource(equirectangular: image, withName: "BirdSpinnerFill")
  }
}
