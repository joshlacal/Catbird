//
//  FeedRecommendationAnalytics.swift
//  Catbird
//
//  Created on 6/2/25.
//

import Foundation
import OSLog

/// Analytics service for tracking feed recommendation interactions and improving suggestions
actor FeedRecommendationAnalytics {
    // MARK: - Properties
    private let logger = Logger(subsystem: "blue.catbird", category: "FeedRecommendationAnalytics")
    private var analytics: [AnalyticsEvent] = []
    private let maxEventsBeforeFlush = 50
    private let flushInterval: TimeInterval = 300 // 5 minutes
    private var lastFlush: Date = Date()
    
    // MARK: - Types
    
    struct AnalyticsEvent: Codable {
        let id: UUID
        let timestamp: Date
        let userId: String // DID of user
        let eventType: EventType
        let feedURI: String
        let metadata: [String: String]
        
        enum EventType: String, Codable {
            case recommendationShown = "recommendation_shown"
            case recommendationClicked = "recommendation_clicked"
            case feedSubscribed = "feed_subscribed"
            case feedUnsubscribed = "feed_unsubscribed"
            case previewViewed = "preview_viewed"
            case interestAdded = "interest_added"
            case interestRemoved = "interest_removed"
            case feedShared = "feed_shared"
            case recommendationDismissed = "recommendation_dismissed"
        }
    }
    
    struct RecommendationMetrics {
        let impressions: Int
        let clickThroughRate: Double
        let subscriptionRate: Double
        let averageEngagementTime: TimeInterval
        let topPerformingReasons: [String]
    }
    
    // MARK: - Public Methods
    
    /// Track when a recommendation is shown to the user
    func trackRecommendationShown(
        feedURI: String,
        userId: String,
        reason: String,
        position: Int,
        source: String = "discovery"
    ) {
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .recommendationShown,
            feedURI: feedURI,
            metadata: [
                "reason": reason,
                "position": "\(position)",
                "source": source
            ]
        )
        
        addEvent(event)
        logger.debug("Tracked recommendation shown: \(feedURI) at position \(position)")
    }
    
    /// Track when user clicks on a recommendation
    func trackRecommendationClicked(
        feedURI: String,
        userId: String,
        reason: String,
        position: Int,
        actionType: String = "view_details"
    ) {
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .recommendationClicked,
            feedURI: feedURI,
            metadata: [
                "reason": reason,
                "position": "\(position)",
                "action_type": actionType
            ]
        )
        
        addEvent(event)
        logger.info("Tracked recommendation clicked: \(feedURI) - \(actionType)")
    }
    
    /// Track when user subscribes to a recommended feed
    func trackFeedSubscribed(
        feedURI: String,
        userId: String,
        source: String,
        reason: String? = nil
    ) {
        var metadata = ["source": source]
        if let reason = reason {
            metadata["reason"] = reason
        }
        
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .feedSubscribed,
            feedURI: feedURI,
            metadata: metadata
        )
        
        addEvent(event)
        logger.info("Tracked feed subscription: \(feedURI) from \(source)")
    }
    
    /// Track when user views a feed preview
    func trackPreviewViewed(
        feedURI: String,
        userId: String,
        duration: TimeInterval,
        postsViewed: Int
    ) {
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .previewViewed,
            feedURI: feedURI,
            metadata: [
                "duration": "\(Int(duration))",
                "posts_viewed": "\(postsViewed)"
            ]
        )
        
        addEvent(event)
        logger.debug("Tracked preview viewed: \(feedURI) for \(Int(duration))s")
    }
    
    /// Track when user adds an interest
    func trackInterestAdded(
        userId: String,
        interest: String,
        source: String = "manual"
    ) {
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .interestAdded,
            feedURI: "", // Not applicable for interests
            metadata: [
                "interest": interest,
                "source": source
            ]
        )
        
        addEvent(event)
        logger.info("Tracked interest added: \(interest)")
    }
    
    /// Track when user shares a feed
    func trackFeedShared(
        feedURI: String,
        userId: String,
        method: String
    ) {
        let event = AnalyticsEvent(
            id: UUID(),
            timestamp: Date(),
            userId: userId,
            eventType: .feedShared,
            feedURI: feedURI,
            metadata: [
                "method": method
            ]
        )
        
        addEvent(event)
        logger.info("Tracked feed shared: \(feedURI) via \(method)")
    }
    
    /// Get metrics for recommendation performance
    func getRecommendationMetrics(
        since: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    ) -> RecommendationMetrics {
        let recentEvents = analytics.filter { $0.timestamp >= since }
        let impressions = recentEvents.filter { $0.eventType == .recommendationShown }.count
        let clicks = recentEvents.filter { $0.eventType == .recommendationClicked }.count
        let subscriptions = recentEvents.filter { $0.eventType == .feedSubscribed }.count
        
        let clickThroughRate = impressions > 0 ? Double(clicks) / Double(impressions) : 0.0
        let subscriptionRate = impressions > 0 ? Double(subscriptions) / Double(impressions) : 0.0
        
        // Calculate average engagement time from preview views
        let previewEvents = recentEvents.filter { $0.eventType == .previewViewed }
        let totalEngagementTime = previewEvents.compactMap { event in
            Double(event.metadata["duration"] ?? "0")
        }.reduce(0, +)
        
        let averageEngagementTime = previewEvents.count > 0 ? 
            totalEngagementTime / Double(previewEvents.count) : 0.0
        
        // Find top performing recommendation reasons
        let reasonCounts = Dictionary(
            recentEvents
                .filter { $0.eventType == .recommendationClicked }
                .compactMap { $0.metadata["reason"] }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        
        let topReasons = reasonCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
        
        return RecommendationMetrics(
            impressions: impressions,
            clickThroughRate: clickThroughRate,
            subscriptionRate: subscriptionRate,
            averageEngagementTime: averageEngagementTime,
            topPerformingReasons: Array(topReasons)
        )
    }
    
    /// Get feed performance insights
    func getFeedInsights(feedURI: String) -> FeedInsights {
        let feedEvents = analytics.filter { $0.feedURI == feedURI }
        
        let impressions = feedEvents.filter { $0.eventType == .recommendationShown }.count
        let clicks = feedEvents.filter { $0.eventType == .recommendationClicked }.count
        let subscriptions = feedEvents.filter { $0.eventType == .feedSubscribed }.count
        let previews = feedEvents.filter { $0.eventType == .previewViewed }.count
        
        let clickThroughRate = impressions > 0 ? Double(clicks) / Double(impressions) : 0.0
        let conversionRate = clicks > 0 ? Double(subscriptions) / Double(clicks) : 0.0
        
        // Get most effective recommendation reasons for this feed
        let reasonCounts = Dictionary(
            feedEvents
                .filter { $0.eventType == .recommendationClicked }
                .compactMap { $0.metadata["reason"] }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        
        let topReasons = reasonCounts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }
        
        return FeedInsights(
            feedURI: feedURI,
            impressions: impressions,
            clickThroughRate: clickThroughRate,
            conversionRate: conversionRate,
            previewViews: previews,
            topReasons: Array(topReasons)
        )
    }
    
    /// Clear old analytics data
    func clearOldData(olderThan: Date = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()) {
        let initialCount = analytics.count
        analytics.removeAll { $0.timestamp < olderThan }
        
        let removedCount = initialCount - analytics.count
        if removedCount > 0 {
            logger.info("Cleared \(removedCount) old analytics events")
        }
    }
    
    /// Export analytics data for analysis
    func exportData() -> [AnalyticsEvent] {
        return analytics
    }
    
    // MARK: - Private Methods
    
    private func addEvent(_ event: AnalyticsEvent) {
        analytics.append(event)
        
        // Auto-flush if needed
        if analytics.count >= maxEventsBeforeFlush ||
           Date().timeIntervalSince(lastFlush) > flushInterval {
            Task {
                await flushAnalytics()
            }
        }
    }
    
    private func flushAnalytics() {
        // In a real implementation, you would send analytics to your backend
        // For now, we'll just log the flush and clear old data
        logger.info("Flushing \(self.analytics.count) analytics events")
        
        // Clear old data to prevent memory growth
        clearOldData()
        
        lastFlush = Date()
    }
}

// MARK: - Supporting Types

struct FeedInsights {
    let feedURI: String
    let impressions: Int
    let clickThroughRate: Double
    let conversionRate: Double
    let previewViews: Int
    let topReasons: [String]
    
    var performanceScore: Double {
        // Weighted score combining CTR and conversion rate
        return (clickThroughRate * 0.6) + (conversionRate * 0.4)
    }
    
    var isHighPerforming: Bool {
        return performanceScore > 0.1 && impressions > 5
    }
}

// MARK: - Usage Example Integration

extension SmartFeedRecommendationEngine {
    /// Enhanced recommendation method with analytics tracking
    func getRecommendationsWithAnalytics(
        limit: Int = 20,
        forceRefresh: Bool = false,
        analytics: FeedRecommendationAnalytics,
        userId: String
    ) async throws -> [FeedRecommendation] {
        let recommendations = try await getRecommendations(limit: limit, forceRefresh: forceRefresh)
        
        // Track impressions for all recommendations
        for (index, recommendation) in recommendations.enumerated() {
            await analytics.trackRecommendationShown(
                feedURI: recommendation.feed.uri.uriString(),
                userId: userId,
                reason: recommendation.displayReason,
                position: index,
                source: "smart_discovery"
            )
        }
        
        return recommendations
    }
}

// MARK: - Analytics Dashboard Data

struct AnalyticsDashboardData {
    let totalImpressions: Int
    let totalClicks: Int
    let totalSubscriptions: Int
    let overallCTR: Double
    let overallConversionRate: Double
    let topRecommendationReasons: [(reason: String, performance: Double)]
    let feedPerformanceRanking: [FeedInsights]
    let dailyMetrics: [DailyMetric]
    
    struct DailyMetric {
        let date: Date
        let impressions: Int
        let clicks: Int
        let subscriptions: Int
    }
}

extension FeedRecommendationAnalytics {
    /// Generate dashboard data for analytics visualization
    func generateDashboardData(
        since: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    ) -> AnalyticsDashboardData {
        let recentEvents = analytics.filter { $0.timestamp >= since }
        
        let impressions = recentEvents.filter { $0.eventType == .recommendationShown }.count
        let clicks = recentEvents.filter { $0.eventType == .recommendationClicked }.count
        let subscriptions = recentEvents.filter { $0.eventType == .feedSubscribed }.count
        
        let overallCTR = impressions > 0 ? Double(clicks) / Double(impressions) : 0.0
        let overallConversionRate = clicks > 0 ? Double(subscriptions) / Double(clicks) : 0.0
        
        // Analyze recommendation reason performance
        let reasonPerformance = analyzeReasonPerformance(events: recentEvents)
        
        // Get feed performance ranking
        let feedPerformance = generateFeedPerformanceRanking(events: recentEvents)
        
        // Generate daily metrics
        let dailyMetrics = generateDailyMetrics(events: recentEvents, since: since)
        
        return AnalyticsDashboardData(
            totalImpressions: impressions,
            totalClicks: clicks,
            totalSubscriptions: subscriptions,
            overallCTR: overallCTR,
            overallConversionRate: overallConversionRate,
            topRecommendationReasons: reasonPerformance,
            feedPerformanceRanking: feedPerformance,
            dailyMetrics: dailyMetrics
        )
    }
    
    private func analyzeReasonPerformance(events: [AnalyticsEvent]) -> [(reason: String, performance: Double)] {
        let reasonImpressions = Dictionary(
            events
                .filter { $0.eventType == .recommendationShown }
                .compactMap { $0.metadata["reason"] }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        
        let reasonClicks = Dictionary(
            events
                .filter { $0.eventType == .recommendationClicked }
                .compactMap { $0.metadata["reason"] }
                .map { ($0, 1) },
            uniquingKeysWith: +
        )
        
        return reasonImpressions.compactMap { reason, impressionCount in
            let clickCount = reasonClicks[reason] ?? 0
            let performance = impressionCount > 0 ? Double(clickCount) / Double(impressionCount) : 0.0
            return (reason: reason, performance: performance)
        }
        .sorted { $0.performance > $1.performance }
        .prefix(10)
        .map { $0 }
    }
    
    private func generateFeedPerformanceRanking(events: [AnalyticsEvent]) -> [FeedInsights] {
        let feedURIs = Set(events.map { $0.feedURI }).filter { !$0.isEmpty }
        
        return feedURIs.map { getFeedInsights(feedURI: $0) }
            .sorted { $0.performanceScore > $1.performanceScore }
            .prefix(20)
            .map { $0 }
    }
    
    private func generateDailyMetrics(events: [AnalyticsEvent], since: Date) -> [AnalyticsDashboardData.DailyMetric] {
        let calendar = Calendar.current
        let today = Date()
        let daysBetween = calendar.dateComponents([.day], from: since, to: today).day ?? 0
        
        var dailyMetrics: [AnalyticsDashboardData.DailyMetric] = []
        
        for dayOffset in 0...daysBetween {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            
            let startOfDay = calendar.startOfDay(for: date)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date
            
            let dayEvents = events.filter { event in
                event.timestamp >= startOfDay && event.timestamp < endOfDay
            }
            
            let dayImpressions = dayEvents.filter { $0.eventType == .recommendationShown }.count
            let dayClicks = dayEvents.filter { $0.eventType == .recommendationClicked }.count
            let daySubscriptions = dayEvents.filter { $0.eventType == .feedSubscribed }.count
            
            dailyMetrics.append(AnalyticsDashboardData.DailyMetric(
                date: startOfDay,
                impressions: dayImpressions,
                clicks: dayClicks,
                subscriptions: daySubscriptions
            ))
        }
        
        return dailyMetrics.reversed() // Most recent first
    }
}