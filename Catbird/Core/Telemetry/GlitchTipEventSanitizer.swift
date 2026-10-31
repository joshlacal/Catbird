import Foundation

#if canImport(Sentry)
import Sentry

/// A deliberately small diagnostic schema. Free-form bridge data is discarded.
enum GlitchTipEventSanitizer {
  static func sanitize(_ event: Event) -> Event {
    let categories = ["Petrel.Authentication", "Petrel.Network", "Petrel.General", "MLS.Chat", "Telemetry.Pilot"]
    var tags: [String: String] = [:]
    if let category = event.tags?["category"], categories.contains(category) {
      tags["category"] = category
    }
    if let fixture = event.tags?["telemetry.fixture"], ["handled", "native-crash"].contains(fixture) {
      tags["telemetry.fixture"] = fixture
    }
    event.tags = tags
    event.message = SentryMessage(formatted: event.exceptions?.isEmpty == false
      ? "Catbird exception" : "Catbird handled diagnostic")
    event.user = nil
    event.request = nil
    event.extra = nil
    event.breadcrumbs = nil
    var context: [String: [String: Any]] = [:]
    if let arch = event.context?["device"]?["arch"] as? String,
      ["arm64", "arm64e", "x86_64", "x86", "i386"].contains(arch) {
      context["device"] = ["arch": arch]
    }
    if let name = event.context?["os"]?["name"] as? String,
      ["iOS", "macOS", "tvOS", "watchOS"].contains(name) {
      context["os"] = ["name": name]
      if let version = event.context?["os"]?["version"] as? String,
        !version.isEmpty, version.count <= 32,
        version.allSatisfy({ $0.isNumber || $0 == "." }) {
        context["os"]?["version"] = version
      }
    }
    event.context = context.isEmpty ? nil : context
    event.fingerprint = nil
    event.transaction = nil
    event.serverName = nil
    event.logger = nil
    event.error = nil
    event.modules = nil
    for exception in event.exceptions ?? [] {
      exception.value = "[Redacted]"
      let nativeTypes = ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_BREAKPOINT", "EXC_CRASH", "SIGABRT", "SIGSEGV", "SIGTRAP", "NSInternalInconsistencyException", "NSInvalidArgumentException"]
      if !nativeTypes.contains(exception.type) { exception.type = "CatbirdException" }
      exception.module = nil
      exception.mechanism?.data = nil
      exception.mechanism?.desc = nil
      exception.mechanism?.helpLink = nil
      sanitize(exception.stacktrace)
    }
    sanitize(event.stacktrace)
    for thread in event.threads ?? [] {
      thread.name = nil
      sanitize(thread.stacktrace)
    }
    for image in event.debugMeta ?? [] {
      image.codeFile = image.codeFile.map { URL(fileURLWithPath: $0).lastPathComponent }
      image.name = image.name.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
    return event
  }

  private static func sanitize(_ stacktrace: SentryStacktrace?) {
    for frame in stacktrace?.frames ?? [] {
      frame.vars = nil
      frame.contextLine = nil
      frame.preContext = nil
      frame.postContext = nil
      frame.fileName = frame.fileName.map { URL(fileURLWithPath: $0).lastPathComponent }
      frame.package = frame.package.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
  }
}
#endif
