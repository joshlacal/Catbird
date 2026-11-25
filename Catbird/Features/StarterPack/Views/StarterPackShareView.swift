//
//  StarterPackShareView.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G58).
//

import SwiftUI
import Petrel

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public struct StarterPackShareView: View {
    let starterPack: AppBskyGraphDefs.StarterPackView
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingQRCode = false
    @State private var copiedLink = false
    
    public init(starterPack: AppBskyGraphDefs.StarterPackView) {
        self.starterPack = starterPack
    }
    
    private var packName: String {
        if case .knownType(let recordValue) = starterPack.record,
           let starterpack = recordValue as? AppBskyGraphStarterpack {
            return starterpack.name
        }
        return String(localized: "Starter Pack", comment: "Fallback title when a starter pack has no custom name.")
    }
    
    private var packDescription: String? {
        if case .knownType(let recordValue) = starterPack.record,
           let starterpack = recordValue as? AppBskyGraphStarterpack {
            return starterpack.description
        }
        return nil
    }
    
    /// Canonical share URL: https://bsky.app/start/<creator-handle>/<rkey>
    public var canonicalShareURL: URL {
        let handle = starterPack.creator.handle
        let rkey = starterPack.uri.recordKey ?? "default"
        return URL(string: "https://bsky.app/start/\(handle)/\(rkey)")!
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Starter Pack Card Preview
                packPreviewCard
                    .padding(.horizontal)
                    .padding(.top, 16)
                
                // Actions
                VStack(spacing: 12) {
                    // Native Share Sheet
                    ShareLink(item: canonicalShareURL) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Starter Pack")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))
                    
                    // Copy Link Button
                    Button {
                        copyLink()
                    } label: {
                        HStack {
                            Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                            Text(copiedLink ? "Link Copied!" : "Copy Link")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.catbird(.tonal, size: .lg, fullWidth: true))
                    
                    // QR Code Card Button
                    Button {
                        showingQRCode = true
                    } label: {
                        HStack {
                            Image(systemName: "qrcode")
                            Text("Show QR Code")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.catbird(.tonal, size: .lg, fullWidth: true))
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Share Starter Pack")
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
            .sheet(isPresented: $showingQRCode) {
                StarterPackQRCodeCard(starterPack: starterPack, shareURL: canonicalShareURL)
            }
        }
    }
    
    // MARK: - Preview Card
    
    private var packPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncProfileImage(
                    url: URL(string: starterPack.creator.avatar?.uriString() ?? ""), size: 48,
                    did: starterPack.creator.did.didString(), labels: starterPack.creator.labels)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(packName)
                        .appFont(AppTextRole.headline)
                        .fontWeight(.bold)
                        .lineLimit(1)
                    
                    Text("Created by @\(starterPack.creator.handle.description)", comment: "Creator attribution on starter pack share preview card. Placeholder is the creator's Bluesky handle.")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            
            if let description = packDescription, !description.isEmpty {
                Text(description)
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            
            HStack(spacing: 16) {
                let profileCount = starterPack.list?.listItemCount ?? 0
                Label {
                    Text("\(profileCount) people", comment: "Count of member profiles included in a starter pack.")
                } icon: {
                    Image(systemName: "person.2")
                }
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                
                if let feedsCount = starterPack.feeds?.count, feedsCount > 0 {
                    Label {
                        Text("\(feedsCount) feeds", comment: "Count of custom feeds included in a starter pack.")
                    } icon: {
                        Image(systemName: "rectangle.grid.1x2")
                    }
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color.systemGray6)
        .catbirdClip(.lg)
    }
    
    // MARK: - Copy Action
    
    private func copyLink() {
        #if os(iOS)
        UIPasteboard.general.string = canonicalShareURL.absoluteString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canonicalShareURL.absoluteString, forType: .string)
        #endif
        
        withAnimation {
            copiedLink = true
        }
        
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                copiedLink = false
            }
        }
    }
}
