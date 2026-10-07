import Testing
@testable import Catbird

@Suite("Network path restoration")
@MainActor
struct NetworkMonitorTests {
  @Test("The first available path and interface changes do not mean restoration")
  func firstAvailablePath() {
    let monitor = NetworkMonitor(startMonitoring: false)
    monitor.apply(.init(isConnected: true, connectionType: .wifi))
    #expect(monitor.isConnected)
    #expect(monitor.restorationGeneration == 0)
    monitor.apply(.init(isConnected: true, connectionType: .cellular))
    #expect(monitor.connectionType == .cellular)
    #expect(monitor.restorationGeneration == 0)
  }

  @Test("An initially unavailable path becoming available emits one restoration")
  func initiallyUnavailable() {
    let monitor = NetworkMonitor(startMonitoring: false)
    monitor.apply(.init(isConnected: false, connectionType: .unknown))
    #expect(!monitor.isConnected)
    #expect(monitor.connectionType == .none)
    #expect(monitor.restorationGeneration == 0)
    monitor.apply(.init(isConnected: true, connectionType: .wifi))
    #expect(monitor.restorationGeneration == 1)
    monitor.apply(.init(isConnected: true, connectionType: .wifi))
    #expect(monitor.restorationGeneration == 1)
  }

  @Test("Repeated unavailable callbacks coalesce while later outages remain distinct")
  func repeatedPathUpdates() {
    let monitor = NetworkMonitor(startMonitoring: false)
    monitor.apply(.init(isConnected: true, connectionType: .wifi))
    for _ in 0..<3 {
      monitor.apply(.init(isConnected: false, connectionType: .none))
    }
    #expect(monitor.restorationGeneration == 0)
    monitor.apply(.init(isConnected: true, connectionType: .wifi))
    #expect(monitor.restorationGeneration == 1)
    monitor.apply(.init(isConnected: false, connectionType: .none))
    monitor.apply(.init(isConnected: true, connectionType: .ethernet))
    #expect(monitor.restorationGeneration == 2)
    #expect(monitor.connectionType == .ethernet)
  }
}
