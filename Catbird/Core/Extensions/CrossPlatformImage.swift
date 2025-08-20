//
//  CrossPlatformImage.swift
//  Catbird
//
//  Created by Claude on 8/19/25.
//

#if os(iOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformBezierPath = UIBezierPath
#elseif os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformBezierPath = NSBezierPath
#endif

import CoreGraphics
import SwiftUI
import OSLog

private let crossPlatformImageLogger = Logger(subsystem: "blue.catbird", category: "CrossPlatformImage")

// MARK: - Cross-platform Image Extensions

extension PlatformImage {
    
    #if os(macOS)
    /// Create a JPEG data representation with compression quality (macOS only)
    func jpegImageData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
    
    /// Create a PNG data representation (macOS only)
    func pngImageData() -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
    #endif
    
    /// Get the size of the image
    var imageSize: CGSize {
        return size
    }
    
    /// Get the scale factor of the image
    var imageScale: CGFloat {
        #if os(iOS)
        return scale
        #elseif os(macOS)
        // NSImage doesn't have a scale property, assume 2.0 for Retina displays
        return 2.0
        #endif
    }
    
    /// Create an image from CGImage
    static func image(from cgImage: CGImage) -> PlatformImage? {
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #elseif os(macOS)
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
    
    /// Draw the image in a given rectangle (cross-platform method)
    func drawInRect(_ rect: CGRect) {
        #if os(iOS)
        draw(in: rect)
        #elseif os(macOS)
        draw(in: rect)
        #endif
    }
}

// MARK: - Cross-platform Graphics Context

struct CrossPlatformImageRenderer {
    let size: CGSize
    
    init(size: CGSize) {
        self.size = size
    }
    
    func image(actions: @escaping (CGContext) -> Void) -> PlatformImage? {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            actions(context.cgContext)
        }
        #elseif os(macOS)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                crossPlatformImageLogger.error("Failed to get current graphics context")
                return false
            }
            actions(context)
            return true
        }
        #endif
    }
}

// MARK: - Legacy Graphics Context Support

struct CrossPlatformGraphicsContext {
    
    /// Begin an image context with the specified size and scale
    static func beginImageContext(size: CGSize, opaque: Bool = false, scale: CGFloat = 0.0) {
        #if os(iOS)
        UIGraphicsBeginImageContextWithOptions(size, opaque, scale)
        #elseif os(macOS)
        // macOS uses NSGraphicsContext, we'll create a bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * Int(size.width)
        let bitsPerComponent = 8
        
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            crossPlatformImageLogger.error("Failed to create CGContext for macOS image context")
            return
        }
        
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        #endif
    }
    
    /// Get the image from the current context
    static func getImageFromCurrentContext() -> PlatformImage? {
        #if os(iOS)
        return UIGraphicsGetImageFromCurrentImageContext()
        #elseif os(macOS)
        guard let context = NSGraphicsContext.current?.cgContext,
              let cgImage = context.makeImage() else {
            crossPlatformImageLogger.error("Failed to create image from current context")
            return nil
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
    
    /// End the current image context
    static func endImageContext() {
        #if os(iOS)
        UIGraphicsEndImageContext()
        #elseif os(macOS)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }
}

// MARK: - Bezier Path Extensions

extension PlatformBezierPath {
    
    /// Create an oval path in the specified rectangle
    static func ovalPath(in rect: CGRect) -> PlatformBezierPath {
        #if os(iOS)
        return UIBezierPath(ovalIn: rect)
        #elseif os(macOS)
        let path = NSBezierPath()
        path.appendOval(in: rect)
        return path
        #endif
    }
    
    /// Add clipping to the current path (cross-platform method)
    func addClipPath() {
        #if os(iOS)
        addClip()
        #elseif os(macOS)
        addClip()
        #endif
    }
}

// MARK: - System Image Support

extension PlatformImage {
    
    /// Create a system image with the specified name
    static func systemImage(named systemName: String) -> PlatformImage? {
        #if os(iOS)
        return UIImage(systemName: systemName)
        #elseif os(macOS)
        // macOS uses SF Symbols through NSImage(systemSymbolName:)
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        } else {
            // Fallback for older macOS versions
            return NSImage(named: systemName)
        }
        #endif
    }
}

// MARK: - Image Compression Utilities

extension PlatformImage {
    
    /// Compress image to target size in bytes
    func compressed(maxSizeInBytes: Int = 900_000) -> Data? {
        var compression: CGFloat = 1.0
        
        #if os(iOS)
        var imageData = jpegData(compressionQuality: compression)
        
        // Gradually lower quality until we get under target size
        while let data = imageData, data.count > maxSizeInBytes && compression > 0.1 {
            compression -= 0.1
            imageData = jpegData(compressionQuality: compression)
        }
        
        // If we still exceed the size limit, resize the image
        if let bestData = imageData, bestData.count > maxSizeInBytes {
            let scale = sqrt(CGFloat(maxSizeInBytes) / CGFloat(bestData.count))
            let newSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            if let resizedImage = resized(to: newSize) {
                return resizedImage.jpegData(compressionQuality: 0.7)
            }
        }
        
        return imageData
        #elseif os(macOS)
        var imageData = jpegImageData(compressionQuality: compression)
        
        // Gradually lower quality until we get under target size
        while let data = imageData, data.count > maxSizeInBytes && compression > 0.1 {
            compression -= 0.1
            imageData = jpegImageData(compressionQuality: compression)
        }
        
        // If we still exceed the size limit, resize the image
        if let bestData = imageData, bestData.count > maxSizeInBytes {
            let scale = sqrt(CGFloat(maxSizeInBytes) / CGFloat(bestData.count))
            let newSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            if let resizedImage = resized(to: newSize) {
                return resizedImage.jpegImageData(compressionQuality: 0.7)
            }
        }
        
        return imageData
        #endif
    }
    
    /// Resize image to specified size
    func resized(to newSize: CGSize) -> PlatformImage? {
        let renderer = CrossPlatformImageRenderer(size: newSize)
        return renderer.image { context in
            // Set high quality interpolation
            context.interpolationQuality = .high
            
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    /// Create a circular cropped version of the image
    func circularCroppedImage(to size: CGSize) -> PlatformImage? {
        let renderer = CrossPlatformImageRenderer(size: size)
        return renderer.image { context in
            // Create circular clipping path
            let path = PlatformBezierPath.ovalPath(in: CGRect(origin: .zero, size: size))
            
            path.addClipPath()
            
            // Calculate scaling to fill the circle
            let aspectWidth = size.width / self.imageSize.width
            let aspectHeight = size.height / self.imageSize.height
            let aspectRatio = max(aspectWidth, aspectHeight)
            
            let scaledWidth = self.imageSize.width * aspectRatio
            let scaledHeight = self.imageSize.height * aspectRatio
            let drawingRect = CGRect(
                x: (size.width - scaledWidth) / 2,
                y: (size.height - scaledHeight) / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            
            self.draw(in: drawingRect)
        }
    }
}