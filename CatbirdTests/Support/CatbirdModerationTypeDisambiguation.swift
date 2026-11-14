#if os(iOS)
import Petrel
@testable import Catbird

// Petrel 2.0 exports public moderation types with the same names as Catbird's
// internal moderation engine. Shadow them at module scope in CatbirdTests just
// as Catbird's own module scope shadows them.
typealias ModerationOptions = Catbird.ModerationOptions
typealias ModerationCauseSource = Catbird.ModerationCauseSource
typealias ModerationCause = Catbird.ModerationCause
typealias ModerationUI = Catbird.ModerationUI
typealias ModerationDecision = Catbird.ModerationDecision
typealias LabelPreference = Catbird.LabelPreference
typealias ModerationPrefs = Catbird.ModerationPrefs
typealias ModerationBehavior = Catbird.ModerationBehavior
typealias LabelTarget = Catbird.LabelTarget
#endif
