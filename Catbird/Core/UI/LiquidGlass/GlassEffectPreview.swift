//
//  GlassEffectPreview.swift
//  Catbird
//
//  Created by Claude Code on 8/13/25.
//

import SwiftUI

@available(iOS 26.0, *)
struct GlassEffectPreview: View {
    @State private var showSheet = false
    @State private var showComposer = false
    @State private var selectedTab = 0
    @Namespace private var morphingNamespace
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // FAB Preview
            fabPreviewTab
                .tabItem {
                    Image(systemName: "circle.fill")
                    Text("FAB")
                }
                .tag(0)
            
            // Sheet Preview
            sheetPreviewTab
                .tabItem {
                    Image(systemName: "doc.fill")
                    Text("Sheets")
                }
                .tag(1)
            
            // Toolbar Preview
            toolbarPreviewTab
                .tabItem {
                    Image(systemName: "wrench.fill")
                    Text("Toolbar")
                }
                .tag(2)
            
            // Morphing Preview
            morphingPreviewTab
                .tabItem {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Morphing")
                }
                .tag(3)
        }
    }
    
    private var fabPreviewTab: some View {
        GlassEffectPreviewContainer {
            VStack {
                Spacer()
                
                Text("Floating Action Buttons")
                    .font(.title2)
                    .padding()
                
                HStack(spacing: 20) {
                    // Regular FAB
                    Button("Regular") {}
                        .frame(width: 60, height: 60)
                        .adaptiveGlassEffect(
                            style: .regular,
                            in: Circle(),
                            interactive: true
                        )
                    
                    // Prominent FAB
                    Button("Main") {}
                        .frame(width: 60, height: 60)
                        .adaptiveGlassEffect(
                            style: .tinted(.blue),
                            in: Circle(),
                            interactive: true
                        )
                    
                    // Subtle FAB
                    Button("Subtle") {}
                        .frame(width: 60, height: 60)
                        .adaptiveGlassEffect(
                            style: .subtle,
                            in: Circle(),
                            interactive: true
                        )
                }
                .padding()
                
                Spacer()
            }
        }
    }
    
    private var sheetPreviewTab: some View {
        GlassEffectPreviewContainer {
            VStack(spacing: 20) {
                Text("Sheet Presentations")
                    .font(.title2)
                    .padding(.top, 50)
                
                Button("Show Glass Sheet") {
                    showSheet = true
                }
                .padding()
                .adaptiveGlassEffect(
                    style: .regular,
                    in: Capsule(),
                    interactive: true
                )
                
                Button("Show Post Composer") {
                    showComposer = true
                }
                .padding()
                .adaptiveGlassEffect(
                    style: .tinted(.green),
                    in: Capsule(),
                    interactive: true
                )
                
                Spacer()
            }
        }
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                VStack {
                    Text("Glass Sheet Example")
                        .font(.title)
                        .padding()
                    
                    Text("This sheet uses iOS 26 Liquid Glass effects with partial height presentation.")
                        .padding()
                        .multilineTextAlignment(.center)
                    
                    Spacer()
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showSheet = false
                        }
                        .adaptiveGlassEffect(
                            style: .tinted(.blue),
                            in: Capsule(),
                            interactive: true
                        )
                    }
                }
                .navigationTitle("Glass Sheet")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.thinMaterial)
        }
    }
    
    private var toolbarPreviewTab: some View {
        NavigationStack {
            GlassEffectPreviewContainer {
                VStack {
                    Text("Toolbar Glass Effects")
                        .font(.title2)
                        .padding()
                    
                    Text("Navigation bars and toolbars automatically adopt Liquid Glass when compiled with iOS 26 SDK.")
                        .multilineTextAlignment(.center)
                        .padding()
                    
                    Spacer()
                }
            }
            .navigationTitle("Glass Toolbar")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Action 1") {}
                        .adaptiveGlassEffect(
                            style: .regular,
                            in: Capsule(),
                            interactive: true
                        )
                    
                    Button("Action 2") {}
                        .adaptiveGlassEffect(
                            style: .tinted(.orange),
                            in: Capsule(),
                            interactive: true
                        )
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {}
                        .adaptiveGlassEffect(
                            style: .tinted(.green),
                            in: Capsule(),
                            interactive: true
                        )
                }
            }
        }
    }
    
    private var morphingPreviewTab: some View {
        GlassEffectPreviewContainer {
            VStack(spacing: 40) {
                Text("Glass Morphing Transitions")
                    .font(.title2)
                    .padding()
                
                Text("Tap the elements to see fluid morphing transitions between glass states.")
                    .multilineTextAlignment(.center)
                    .padding()
                
                morphingDemo
                
                Spacer()
            }
        }
    }
    
    @State private var isExpanded = false
    
    private var morphingDemo: some View {
        VStack(spacing: 20) {
            if isExpanded {
                HStack(spacing: 8) {
                    ForEach(["star", "heart", "bookmark", "share"], id: \.self) { icon in
                        Button {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: icon)
                                .frame(width: 50, height: 50)
                        }
                        .adaptiveGlassEffect(style: .regular, interactive: true)
                        .catbirdGlassMorphing(id: icon, namespace: morphingNamespace)
                    }
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 80, height: 80)
                }
                .adaptiveGlassEffect(style: .prominent, interactive: true)
                .catbirdGlassMorphing(id: "plus", namespace: morphingNamespace)
            }
        }
    }
}

#Preview("Glass Effects") {
    if #available(iOS 26.0, *) {
        GlassEffectPreview()
    } else {
        // Fallback on earlier versions
        Text("iOS 26 or later is required to preview Liquid Glass effects.")
            
    }
}

#Preview("FAB Only") {
    GlassEffectPreviewContainer {
        VStack {
            Spacer()
            HStack(spacing: 20) {
                Button("Feed") {}
                    .frame(width: 60, height: 60)
                    .adaptiveGlassEffect(style: .tinted(.secondary), in: Circle(), interactive: true)
                
                Spacer()
                
                Button("Compose") {}
                    .frame(width: 60, height: 60)
                    .adaptiveGlassEffect(style: .tinted(.blue), in: Circle(), interactive: true)
            }
            .padding()
        }
    }
}

#Preview("Sheet Glass") {
    NavigationStack {
        VStack {
            Text("Sheet Content")
                .font(.title)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {}
                    .adaptiveGlassEffect(style: .tinted(.green), in: Capsule(), interactive: true)
            }
        }
        .navigationTitle("Glass Sheet")
        .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.thinMaterial)
}
