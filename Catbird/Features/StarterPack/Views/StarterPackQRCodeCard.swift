//
//  StarterPackQRCodeCard.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G58).
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Petrel

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct StarterPackQRCodeCard: View {
    let starterPack: AppBskyGraphDefs.StarterPackView
    let shareURL: URL
    
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: PlatformImage?
    @State private var renderedCardImage: PlatformImage?
    
    public init(starterPack: AppBskyGraphDefs.StarterPackView, shareURL: URL) {
        self.starterPack = starterPack
        self.shareURL = shareURL
    }
    
    private var packName: String {
        if case .knownType(let recordValue) = starterPack.record,
           let starterpack = recordValue as? AppBskyGraphStarterpack {
            return starterpack.name
        }
        return "Starter Pack"
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Renderable Card
                qrCardContent
                    .padding(24)
                    .background(Color.systemBackground)
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                
                // Export / Share Button
                if let cardImage = renderCardToImage() {
                    #if os(iOS)
                    ShareLink(
                        item: Image(uiImage: cardImage),
                        preview: SharePreview(packName, image: Image(uiImage: cardImage))
                    ) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export QR Card")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundColor(.white)
                    }
                    .padding(.horizontal, 24)
                    #endif
                }
                
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("QR Code")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                generateQR()
            }
        }
    }
    
    // MARK: - Card Content
    
    private var qrCardContent: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                AsyncProfileImage(url: URL(string: starterPack.creator.avatar?.uriString() ?? ""), size: 48)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(packName)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.bold)
                        .lineLimit(1)
                    
                    Text("Starter pack by @\(starterPack.creator.handle)")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            
            Divider()
            
            // QR Code Image
            Group {
                if let qrImage = qrImage {
                    #if os(iOS)
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                    #elseif os(macOS)
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                    #endif
                } else {
                    Rectangle()
                        .fill(Color.systemGray6)
                        .frame(width: 200, height: 200)
                        .overlay(ProgressView())
                }
            }
            .padding(12)
            .background(Color.white)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            
            // Footer Info
            Text("Scan to view and follow on Bluesky")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - QR Code Generation
    
    private func generateQR() {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(shareURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return }
        
        #if os(iOS)
        self.qrImage = UIImage(cgImage: cgImage)
        #elseif os(macOS)
        self.qrImage = NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
        #endif
    }
    
    // MARK: - Image Rendering
    
    @MainActor
    private func renderCardToImage() -> PlatformImage? {
        #if os(iOS)
        let renderer = ImageRenderer(content: qrCardContent.frame(width: 320).padding(20).background(Color.white))
        renderer.scale = 2.0
        return renderer.uiImage
        #else
        return nil
        #endif
    }
}
