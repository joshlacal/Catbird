//
//  TopicSummaryService.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Service for warming up and orchestrating topic summarization with on-device foundation models.
public final class TopicSummaryService: @unchecked Sendable {
    public static let shared = TopicSummaryService()

    private init() {}

    /// Performs early background model warmup if foundation models are available.
    public func prepareModelWarmupIfNeeded() async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel(useCase: .general)
            _ = model.availability
        }
        #endif
    }

    /// Performs background launch warmup for topic summarization using the authenticated AppState.
    func prepareLaunchWarmup(appState: AppState) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            await prepareModelWarmupIfNeeded()
        }
        #endif
    }
}
