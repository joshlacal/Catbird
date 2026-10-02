//
//  UIKitStateObserver.swift
//  Catbird
//
//  Proper @Observable state integration for UIKit components
//

import Observation

@MainActor
final class UIKitStateObserver<T: Observable> {
    
    private var isObserving = false
    private var generation: UInt64 = 0
    
    private let observedObject: T
    private let onChange: @MainActor (T) -> Void
    
    init(observing object: T, onChange: @escaping @MainActor (T) -> Void) {
        self.observedObject = object
        self.onChange = onChange
        startObserving()
    }
    
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        generation &+= 1
        registerObservation(generation: generation)
    }
    
    func stopObserving() {
        isObserving = false
        generation &+= 1
    }
    
    private func registerObservation(generation: UInt64) {
        guard isObserving, self.generation == generation else { return }
        
        withObservationTracking {
            if let stateManager = self.observedObject as? FeedStateManager {
                _ = stateManager.posts
                _ = stateManager.loadingState
                _ = stateManager.hasReachedEnd
                _ = stateManager.isEmpty
            } else if let themeManager = self.observedObject as? ThemeManager {
                _ = themeManager.colorSchemeOverride
                _ = themeManager.darkThemeMode
            } else if let feedback = self.observedObject as? FeedFeedbackManager {
                _ = feedback.isEnabled
                _ = feedback.currentFeedType?.identifier
            } else if let appState = self.observedObject as? AppState {
                _ = appState.tabTappedAgain
                _ = appState.isTransitioningAccounts
            } else {
                // Fallback for types without an explicit branch above. Reading the object
                // reference itself tracks NO properties, so `onChange` never fires for
                // these types. Add an explicit branch that reads the relevant properties
                // before observing a new @Observable type with this class.
                _ = self.observedObject
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving, self.generation == generation else { return }
                self.onChange(self.observedObject)
                self.registerObservation(generation: generation)
            }
        }
    }
}

