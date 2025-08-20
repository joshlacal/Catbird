import SwiftUI
import Petrel

#if os(iOS)

// Add Identifiable conformance to ChatBskyConvoDefs.ConvoView if it doesn't have it
extension ChatBskyConvoDefs.ConvoView: @retroactive Identifiable {}

#endif