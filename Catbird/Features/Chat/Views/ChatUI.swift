// This file now re-exports all the refactored chat UI components
// The original ChatUI.swift has been split into smaller, more manageable files:
//
// - ChatTabView.swift: Main chat tab container
// - ConversationListView.swift: List of conversations
// - ConversationRow.swift: Individual conversation row
// - ConversationView.swift: Chat conversation with messages
// - ChatProfileAvatarView.swift: Avatar component
// - ChatToolbarMenus.swift: All toolbar and menu components
// - EmptyConversationView.swift: Empty state view
// - CustomMessageMenuAction.swift: Message menu actions
// - ReportChatMessageView.swift: Report message view
// - ChatExtensions.swift: Protocol conformances

// Re-export all chat UI components so existing imports continue to work
public typealias ChatTabView = ChatTabView
public typealias ConversationListView = ConversationListView
public typealias ConversationRow = ConversationRow
public typealias LastMessagePreview = LastMessagePreview
public typealias ChatProfileAvatarView = ChatProfileAvatarView
public typealias ConversationView = ConversationView
public typealias ChatToolbarMenu = ChatToolbarMenu
public typealias ConversationToolbarMenu = ConversationToolbarMenu
public typealias ConversationContextMenu = ConversationContextMenu
public typealias MessageRequestsButton = MessageRequestsButton
public typealias EmptyConversationView = EmptyConversationView
public typealias CustomMessageMenuAction = CustomMessageMenuAction
public typealias ReportChatMessageView = ReportChatMessageView