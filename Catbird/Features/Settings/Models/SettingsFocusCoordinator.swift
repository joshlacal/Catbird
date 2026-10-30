import Foundation
import Observation

struct SettingsFocusRequest: Hashable, Sendable {
    let target: SettingsControlID?
    let isReady: Bool
}

/// Consumes initial search focus once, including when lazy Form rows remount.
@MainActor @Observable
final class SettingsFocusCoordinator {
    private var currentRequest: SettingsFocusRequest?
    private var scrolledTargets: Set<SettingsControlID> = []
    private var deliveredTargets: Set<SettingsControlID> = []
    private(set) var requestedFocus: SettingsControlID?

    func begin(_ request: SettingsFocusRequest) {
        currentRequest = request
        if !request.isReady || requestedFocus != request.target { requestedFocus = nil }
    }

    func canScroll(_ request: SettingsFocusRequest) -> Bool {
        guard currentRequest == request, request.isReady, let target = request.target else { return false }
        return !scrolledTargets.contains(target)
    }

    func markScrolled(_ request: SettingsFocusRequest) -> Bool {
        guard canScroll(request), let target = request.target else { return false }
        scrolledTargets.insert(target)
        return true
    }

    func scheduleVoiceOver(_ request: SettingsFocusRequest) {
        guard currentRequest == request, request.isReady, let target = request.target,
              scrolledTargets.contains(target), !deliveredTargets.contains(target) else { return }
        requestedFocus = target
    }

    func consumeVoiceOver(for control: SettingsControlID) -> Bool {
        guard currentRequest?.isReady == true, currentRequest?.target == control,
              requestedFocus == control, !deliveredTargets.contains(control) else { return false }
        deliveredTargets.insert(control)
        requestedFocus = nil
        return true
    }
}
