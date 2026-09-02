//
//  MLSGroupAvatarImageTests.swift
//  CatbirdTests
//
//  Tests for MLSGroupAvatarView asynchronous ImageIO thumbnail decoding.
//

import Foundation
import CoreGraphics
import Testing
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import Catbird

@Suite("MLSGroupAvatarView Image Decoding Tests", .serialized)
struct MLSGroupAvatarImageTests {

    private func createTestImageData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return Data()
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            return Data()
        }
        #if os(iOS)
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData() ?? Data()
        #elseif os(macOS)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data()
        #endif
    }

    @Test("decodeThumbnail returns downsampled image at requested pixel size")
    func decodeThumbnailDownsampled() {
        let originalData = createTestImageData(width: 200, height: 200)
        #expect(!originalData.isEmpty)

        let targetPixelSize: CGFloat = 50
        let decoded = MLSGroupAvatarView.decodeThumbnail(from: originalData, pixelSize: targetPixelSize)
        #expect(decoded != nil)

        if let image = decoded {
            #if os(iOS)
            if let cgImage = image.cgImage {
                #expect(cgImage.width <= Int(targetPixelSize))
                #expect(cgImage.height <= Int(targetPixelSize))
            } else {
                #expect(image.size.width <= targetPixelSize)
                #expect(image.size.height <= targetPixelSize)
            }
            #elseif os(macOS)
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #expect(cgImage != nil)
            if let cgImage {
                #expect(cgImage.width <= Int(targetPixelSize))
                #expect(cgImage.height <= Int(targetPixelSize))
            }
            #endif
        }
    }

    @Test("decodeThumbnail returns nil for empty or invalid data")
    func decodeThumbnailInvalidData() {
        let emptyResult = MLSGroupAvatarView.decodeThumbnail(from: Data(), pixelSize: 50)
        #expect(emptyResult == nil)

        let garbageData = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        let garbageResult = MLSGroupAvatarView.decodeThumbnail(from: garbageData, pixelSize: 50)
        #expect(garbageResult == nil)
    }

    @Test("decodeThumbnail preserves aspect ratio within max pixel size constraint")
    func decodeThumbnailPreservesAspectRatio() {
        let rectangularData = createTestImageData(width: 300, height: 150)
        #expect(!rectangularData.isEmpty)

        let targetPixelSize: CGFloat = 60
        let decoded = MLSGroupAvatarView.decodeThumbnail(from: rectangularData, pixelSize: targetPixelSize)
        #expect(decoded != nil)

        if let image = decoded {
            #if os(iOS)
            if let cgImage = image.cgImage {
                #expect(cgImage.width <= Int(targetPixelSize))
                #expect(cgImage.height <= Int(targetPixelSize / 2) + 1)
            }
            #elseif os(macOS)
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                #expect(cgImage.width <= Int(targetPixelSize))
                #expect(cgImage.height <= Int(targetPixelSize / 2) + 1)
            }
            #endif
        }
    }

    @Test("decodeThumbnailAsync returns nil when task is cancelled")
    func decodeThumbnailAsyncCancelled() async {
        let originalData = createTestImageData(width: 200, height: 200)
        #expect(!originalData.isEmpty)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await MLSGroupAvatarView.decodeThumbnailAsync(from: originalData, pixelSize: 50)
        }
        let result = await task.value
        #expect(result == nil)
    }
}
