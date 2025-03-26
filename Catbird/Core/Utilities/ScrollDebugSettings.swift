import Foundation

/// Global settings for scroll debugging and behavior
public enum CatbirdScrollDebugSettings {
    /// Controls whether the scroll view should attempt to stabilize content shifts
    public static var stabilizeContentShifts = true
    
    /// Minimum time between parent post loading attempts
    public static var loadCooldownSeconds: TimeInterval = 0.5
    
    /// Number of parents to load per batch
    public static var parentsPerBatch = 10
    
    /// Debug logging enabled state
    public static var debugLoggingEnabled = true
}