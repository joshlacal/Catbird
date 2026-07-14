//
//  IntentRecordWriteSupport.swift
//  Catbird
//
//  Hand-written support for generated recordWrite intents (Generated/Intents/
//  Like/Unlike/Repost/Follow/Block…). Kept out of the template so the rkey
//  parsing is unit-testable and the generated perform() bodies stay thin.
//

import Foundation
import Petrel

enum IntentRecordWriteSupport {
  /// Extracts the record key from a viewer-state record URI (e.g. the
  /// `viewer.like` at-uri on a hydrated postView) for a deleteRecord call.
  static func recordKey(fromViewerURI uri: ATProtocolURI) throws -> RecordKey {
    guard let rkey = uri.recordKey, !rkey.isEmpty else {
      throw IntentError.invalidParameter(
        "Catbird couldn't parse the existing record reference (\(uri.uriString())).")
    }
    return try RecordKey(keyString: rkey)
  }
}

