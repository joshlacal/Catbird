//
//  MLSStorage.swift
//  Catbird
//
//  MLS Core Data storage layer with reactive updates
//

import Foundation
import CoreData
import Combine
import os.log

/// MLS Storage Manager providing CRUD operations and reactive updates
@MainActor
public class MLSStorage: ObservableObject {
    
    // MARK: - Properties
    
    public static let shared = MLSStorage()
    
    private let logger = Logger(subsystem: "com.catbird.mls", category: "MLSStorage")
    
    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "MLS")
        
        container.loadPersistentStores { description, error in
            if let error = error {
                self.logger.error("Failed to load Core Data stack: \(error.localizedDescription)")
                fatalError("Failed to load Core Data stack: \(error)")
            }
            self.logger.info("Core Data stack loaded successfully")
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        return container
    }()
    
    public var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    // MARK: - Fetched Results Controllers
    
    private var conversationsFRC: NSFetchedResultsController<MLSConversation>?
    private var conversationsSubject = PassthroughSubject<Void, Never>()
    
    public var conversationsPublisher: AnyPublisher<Void, Never> {
        conversationsSubject.eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Context Management
    
    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    public func saveContext(_ context: NSManagedObjectContext? = nil) throws {
        let contextToSave = context ?? viewContext
        
        guard contextToSave.hasChanges else { return }
        
        do {
            try contextToSave.save()
            logger.debug("Context saved successfully")
        } catch {
            logger.error("Failed to save context: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - MLSConversation CRUD
    
    public func createConversation(
        conversationID: String,
        groupID: Data,
        epoch: Int64 = 0,
        title: String? = nil,
        welcomeMessage: Data? = nil
    ) throws -> MLSConversation {
        let conversation = MLSConversation(context: viewContext)
        conversation.conversationID = conversationID
        conversation.groupID = groupID
        conversation.epoch = epoch
        conversation.createdAt = Date()
        conversation.updatedAt = Date()
        conversation.title = title
        conversation.isActive = true
        conversation.welcomeMessage = welcomeMessage
        conversation.memberCount = 0
        
        try saveContext()
        logger.info("Created conversation: \(conversationID)")
        
        return conversation
    }
    
    public func fetchConversation(byID conversationID: String) throws -> MLSConversation? {
        let request = MLSConversation.fetchRequest()
        request.predicate = NSPredicate(format: "conversationID == %@", conversationID)
        request.fetchLimit = 1
        
        return try viewContext.fetch(request).first
    }
    
    public func fetchAllConversations(activeOnly: Bool = true) throws -> [MLSConversation] {
        let request = MLSConversation.fetchRequest()
        
        if activeOnly {
            request.predicate = NSPredicate(format: "isActive == YES")
        }
        
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSConversation.lastMessageAt, ascending: false),
            NSSortDescriptor(keyPath: \MLSConversation.updatedAt, ascending: false)
        ]
        
        return try viewContext.fetch(request)
    }
    
    public func updateConversation(
        _ conversation: MLSConversation,
        epoch: Int64? = nil,
        title: String? = nil,
        treeHash: Data? = nil,
        memberCount: Int32? = nil
    ) throws {
        if let epoch = epoch {
            conversation.epoch = epoch
        }
        if let title = title {
            conversation.title = title
        }
        if let treeHash = treeHash {
            conversation.treeHash = treeHash
        }
        if let memberCount = memberCount {
            conversation.memberCount = memberCount
        }
        
        conversation.updatedAt = Date()
        
        try saveContext()
        logger.debug("Updated conversation: \(conversation.conversationID ?? "unknown")")
    }
    
    public func deleteConversation(_ conversation: MLSConversation) throws {
        viewContext.delete(conversation)
        try saveContext()
        logger.info("Deleted conversation: \(conversation.conversationID ?? "unknown")")
    }
    
    // MARK: - MLSMessage CRUD
    
    public func createMessage(
        messageID: String,
        conversationID: String,
        senderID: String,
        content: Data,
        plaintext: String? = nil,
        contentType: String = "text",
        epoch: Int64,
        sequenceNumber: Int64,
        wireFormat: Data? = nil
    ) throws -> MLSMessage {
        guard let conversation = try fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }

        let message = MLSMessage(context: viewContext)
        message.messageID = messageID
        message.senderID = senderID
        message.content = content
        message.plaintext = plaintext
        message.contentType = contentType
        message.timestamp = Date()
        message.epoch = epoch
        message.sequenceNumber = sequenceNumber
        message.wireFormat = wireFormat
        message.isDelivered = false
        message.isRead = false
        message.isSent = false
        message.sendAttempts = 0
        message.conversation = conversation
        
        conversation.lastMessageAt = Date()
        conversation.updatedAt = Date()
        
        try saveContext()
        logger.info("Created message: \(messageID)")
        
        return message
    }
    
    public func fetchMessage(byID messageID: String) throws -> MLSMessage? {
        let request = MLSMessage.fetchRequest()
        request.predicate = NSPredicate(format: "messageID == %@", messageID)
        request.fetchLimit = 1
        
        return try viewContext.fetch(request).first
    }
    
    public func fetchMessages(
        forConversationID conversationID: String,
        limit: Int? = nil
    ) throws -> [MLSMessage] {
        let request = MLSMessage.fetchRequest()
        request.predicate = NSPredicate(format: "conversation.conversationID == %@", conversationID)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSMessage.timestamp, ascending: true)
        ]
        
        if let limit = limit {
            request.fetchLimit = limit
        }
        
        return try viewContext.fetch(request)
    }
    
    public func updateMessage(
        _ message: MLSMessage,
        plaintext: String? = nil,
        isDelivered: Bool? = nil,
        isRead: Bool? = nil,
        isSent: Bool? = nil,
        error: String? = nil
    ) throws {
        if let plaintext = plaintext {
            message.plaintext = plaintext
        }
        if let isDelivered = isDelivered {
            message.isDelivered = isDelivered
        }
        if let isRead = isRead {
            message.isRead = isRead
        }
        if let isSent = isSent {
            message.isSent = isSent
        }
        if let error = error {
            message.error = error
        }

        try saveContext()
        logger.debug("Updated message: \(message.messageID ?? "unknown")")
    }
    
    public func deleteMessage(_ message: MLSMessage) throws {
        viewContext.delete(message)
        try saveContext()
        logger.info("Deleted message: \(message.messageID ?? "unknown")")
    }
    
    // MARK: - MLSMember CRUD
    
    public func createMember(
        memberID: String,
        conversationID: String,
        did: String,
        handle: String? = nil,
        displayName: String? = nil,
        leafIndex: Int32,
        credentialData: Data? = nil,
        signaturePublicKey: Data? = nil,
        role: String = "member"
    ) throws -> MLSMember {
        guard let conversation = try fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }
        
        let member = MLSMember(context: viewContext)
        member.memberID = memberID
        member.did = did
        member.handle = handle
        member.displayName = displayName
        member.leafIndex = leafIndex
        member.credentialData = credentialData
        member.signaturePublicKey = signaturePublicKey
        member.addedAt = Date()
        member.updatedAt = Date()
        member.isActive = true
        member.role = role
        member.conversation = conversation
        
        conversation.memberCount = Int32((conversation.members?.count ?? 0) + 1)
        conversation.updatedAt = Date()
        
        try saveContext()
        logger.info("Created member: \(memberID)")
        
        return member
    }
    
    public func fetchMember(byID memberID: String) throws -> MLSMember? {
        let request = MLSMember.fetchRequest()
        request.predicate = NSPredicate(format: "memberID == %@", memberID)
        request.fetchLimit = 1
        
        return try viewContext.fetch(request).first
    }
    
    public func fetchMembers(
        forConversationID conversationID: String,
        activeOnly: Bool = true
    ) throws -> [MLSMember] {
        let request = MLSMember.fetchRequest()
        
        var predicates = [NSPredicate(format: "conversation.conversationID == %@", conversationID)]
        if activeOnly {
            predicates.append(NSPredicate(format: "isActive == YES"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSMember.leafIndex, ascending: true)
        ]
        
        return try viewContext.fetch(request)
    }
    
    public func updateMember(
        _ member: MLSMember,
        handle: String? = nil,
        displayName: String? = nil,
        role: String? = nil,
        isActive: Bool? = nil
    ) throws {
        if let handle = handle {
            member.handle = handle
        }
        if let displayName = displayName {
            member.displayName = displayName
        }
        if let role = role {
            member.role = role
        }
        if let isActive = isActive {
            member.isActive = isActive
            if !isActive {
                member.removedAt = Date()
            }
        }
        
        member.updatedAt = Date()
        
        try saveContext()
        logger.debug("Updated member: \(member.memberID ?? "unknown")")
    }
    
    public func deleteMember(_ member: MLSMember) throws {
        if let conversation = member.conversation {
            conversation.memberCount = Int32(max(0, Int(conversation.memberCount) - 1))
            conversation.updatedAt = Date()
        }
        
        viewContext.delete(member)
        try saveContext()
        logger.info("Deleted member: \(member.memberID ?? "unknown")")
    }
    
    // MARK: - MLSEpochKey CRUD

    public func recordEpochKey(conversationID: String, epoch: Int64) async throws {
        guard let conversation = try fetchConversation(byID: conversationID) else {
            throw MLSStorageError.conversationNotFound(conversationID)
        }

        let epochKey = MLSEpochKey(context: viewContext)
        epochKey.conversationID = conversationID
        epochKey.epoch = epoch
        epochKey.createdAt = Date()
        epochKey.conversation = conversation

        try saveContext()
        logger.info("Recorded epoch key for conversation: \(conversationID), epoch: \(epoch)")
    }

    public func deleteOldEpochKeys(conversationID: String, keepLast: Int) async throws {
        let request = MLSEpochKey.fetchRequest()
        request.predicate = NSPredicate(format: "conversationID == %@ AND deletedAt == nil", conversationID)
        request.sortDescriptors = [NSSortDescriptor(key: "epoch", ascending: false)]

        let allKeys = try viewContext.fetch(request)

        guard allKeys.count > keepLast else {
            logger.debug("No old epoch keys to delete for conversation: \(conversationID)")
            return
        }

        let keysToDelete = allKeys.dropFirst(keepLast)
        let deleteCount = keysToDelete.count

        for key in keysToDelete {
            key.deletedAt = Date()
            logger.debug("Marked epoch key for deletion: epoch \(key.epoch)")
        }

        try saveContext()
        logger.info("Marked \(deleteCount) epoch keys for deletion in conversation: \(conversationID)")
    }

    public func cleanupMessageKeys(olderThan date: Date) async throws {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "MLSMessage")
        request.predicate = NSPredicate(format: "timestamp < %@", date as NSDate)

        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs

        let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult

        if let objectIDs = result?.result as? [NSManagedObjectID] {
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
            logger.info("Cleaned up \(objectIDs.count) message keys older than \(date)")
        }
    }

    public func fetchEpochKeys(forConversationID conversationID: String, activeOnly: Bool = true) throws -> [MLSEpochKey] {
        let request = MLSEpochKey.fetchRequest()

        var predicates = [NSPredicate(format: "conversationID == %@", conversationID)]
        if activeOnly {
            predicates.append(NSPredicate(format: "deletedAt == nil"))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSEpochKey.epoch, ascending: false)
        ]

        return try viewContext.fetch(request)
    }

    public func deleteMarkedEpochKeys() async throws {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "MLSEpochKey")
        request.predicate = NSPredicate(format: "deletedAt != nil")

        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs

        let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult

        if let objectIDs = result?.result as? [NSManagedObjectID] {
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
            logger.info("Permanently deleted \(objectIDs.count) marked epoch keys")
        }
    }

    // MARK: - MLSKeyPackage CRUD

    public func createKeyPackage(
        keyPackageID: String,
        keyPackageData: Data,
        cipherSuite: Int16,
        ownerDID: String,
        expiresAt: Date? = nil,
        conversationID: String? = nil
    ) throws -> MLSKeyPackage {
        let keyPackage = MLSKeyPackage(context: viewContext)
        keyPackage.keyPackageID = keyPackageID
        keyPackage.keyPackageData = keyPackageData
        keyPackage.cipherSuite = cipherSuite
        keyPackage.ownerDID = ownerDID
        keyPackage.createdAt = Date()
        keyPackage.expiresAt = expiresAt
        keyPackage.isUsed = false
        
        if let conversationID = conversationID,
           let conversation = try fetchConversation(byID: conversationID) {
            keyPackage.conversation = conversation
        }
        
        try saveContext()
        logger.info("Created key package: \(keyPackageID)")
        
        return keyPackage
    }
    
    public func fetchKeyPackage(byID keyPackageID: String) throws -> MLSKeyPackage? {
        let request = MLSKeyPackage.fetchRequest()
        request.predicate = NSPredicate(format: "keyPackageID == %@", keyPackageID)
        request.fetchLimit = 1
        
        return try viewContext.fetch(request).first
    }
    
    public func fetchAvailableKeyPackages(
        forOwnerDID ownerDID: String,
        cipherSuite: Int16? = nil
    ) throws -> [MLSKeyPackage] {
        let request = MLSKeyPackage.fetchRequest()
        
        var predicates = [
            NSPredicate(format: "ownerDID == %@", ownerDID),
            NSPredicate(format: "isUsed == NO"),
            NSPredicate(format: "expiresAt == nil OR expiresAt > %@", Date() as NSDate)
        ]
        
        if let cipherSuite = cipherSuite {
            predicates.append(NSPredicate(format: "cipherSuite == %d", cipherSuite))
        }
        
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSKeyPackage.createdAt, ascending: false)
        ]
        
        return try viewContext.fetch(request)
    }
    
    public func markKeyPackageAsUsed(_ keyPackage: MLSKeyPackage, conversationID: String) throws {
        keyPackage.isUsed = true
        keyPackage.usedAt = Date()
        
        if let conversation = try fetchConversation(byID: conversationID) {
            keyPackage.conversation = conversation
        }
        
        try saveContext()
        logger.info("Marked key package as used: \(keyPackage.keyPackageID ?? "unknown")")
    }
    
    public func deleteKeyPackage(_ keyPackage: MLSKeyPackage) throws {
        viewContext.delete(keyPackage)
        try saveContext()
        logger.info("Deleted key package: \(keyPackage.keyPackageID ?? "unknown")")
    }
    
    // MARK: - Fetched Results Controller Setup
    
    public func setupConversationsFRC(delegate: NSFetchedResultsControllerDelegate? = nil) {
        let request = MLSConversation.fetchRequest()
        request.predicate = NSPredicate(format: "isActive == YES")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \MLSConversation.lastMessageAt, ascending: false),
            NSSortDescriptor(keyPath: \MLSConversation.updatedAt, ascending: false)
        ]
        
        conversationsFRC = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: viewContext,
            sectionNameKeyPath: nil,
            cacheName: "MLSConversations"
        )
        
        if let delegate = delegate {
            conversationsFRC?.delegate = delegate
        }
        
        do {
            try conversationsFRC?.performFetch()
            logger.info("Conversations FRC setup complete")
        } catch {
            logger.error("Failed to perform fetch for conversations FRC: \(error.localizedDescription)")
        }
    }
    
    public var conversations: [MLSConversation] {
        conversationsFRC?.fetchedObjects ?? []
    }
    
    // MARK: - Batch Operations
    
    public func deleteAllMessages(forConversationID conversationID: String) throws {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "MLSMessage")
        request.predicate = NSPredicate(format: "conversation.conversationID == %@", conversationID)
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs
        
        let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult
        
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
        }
        
        logger.info("Deleted all messages for conversation: \(conversationID)")
    }
    
    public func deleteExpiredKeyPackages() throws {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "MLSKeyPackage")
        request.predicate = NSPredicate(
            format: "expiresAt != nil AND expiresAt < %@",
            Date() as NSDate
        )
        
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs
        
        let result = try viewContext.execute(deleteRequest) as? NSBatchDeleteResult
        
        if let objectIDs = result?.result as? [NSManagedObjectID] {
            let changes = [NSDeletedObjectsKey: objectIDs]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
        }
        
        logger.info("Deleted expired key packages")
    }
    
    // MARK: - Migration Support

    public func migrateFromLegacyStorage() async throws {
        logger.info("Starting migration from legacy storage")

        // This is a placeholder for actual migration logic
        // Implementation would depend on the existing storage format

        logger.info("Migration from legacy storage completed")
    }

    // MARK: - MLS Storage Blob Persistence

    /// Save the MLS storage blob to Core Data
    ///
    /// Stores the serialized MLS storage state for the given user. Only one blob
    /// per user is maintained (singleton pattern).
    ///
    /// - Parameters:
    ///   - storageData: Serialized storage bytes from Rust FFI
    ///   - userDID: User's DID identifier
    /// - Throws: MLSStorageError if save fails
    public func saveMLSStorageBlob(_ storageData: Data, forUser userDID: String) throws {
        logger.info("Saving MLS storage blob for user: \(userDID), size: \(storageData.count) bytes")

        // Fetch existing blob for this user (singleton)
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "MLSStorageBlob")
        fetchRequest.predicate = NSPredicate(format: "userDID == %@", userDID)
        fetchRequest.fetchLimit = 1

        let existingBlob = try viewContext.fetch(fetchRequest).first

        if let blob = existingBlob {
            // Update existing
            blob.setValue(storageData, forKey: "storageData")
            blob.setValue(Date(), forKey: "updatedAt")
            logger.debug("Updated existing storage blob")
        } else {
            // Create new
            let blob = NSEntityDescription.insertNewObject(forEntityName: "MLSStorageBlob", into: viewContext)
            blob.setValue(storageData, forKey: "storageData")
            blob.setValue(Date(), forKey: "updatedAt")
            blob.setValue(userDID, forKey: "userDID")
            logger.debug("Created new storage blob")
        }

        try saveContext()
        logger.info("MLS storage blob saved successfully")
    }

    /// Load the MLS storage blob from Core Data
    ///
    /// Retrieves the serialized MLS storage state for the given user.
    ///
    /// - Parameter userDID: User's DID identifier
    /// - Returns: Serialized storage bytes, or nil if no blob exists
    /// - Throws: MLSStorageError if fetch fails
    public func loadMLSStorageBlob(forUser userDID: String) throws -> Data? {
        logger.info("Loading MLS storage blob for user: \(userDID)")

        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "MLSStorageBlob")
        fetchRequest.predicate = NSPredicate(format: "userDID == %@", userDID)
        fetchRequest.fetchLimit = 1

        guard let blob = try viewContext.fetch(fetchRequest).first,
              let storageData = blob.value(forKey: "storageData") as? Data else {
            logger.info("No storage blob found for user")
            return nil
        }

        logger.info("Loaded storage blob: \(storageData.count) bytes")
        return storageData
    }

    /// Delete the MLS storage blob for a user
    ///
    /// Used when logging out or clearing user data.
    ///
    /// - Parameter userDID: User's DID identifier
    /// - Throws: MLSStorageError if deletion fails
    public func deleteMLSStorageBlob(forUser userDID: String) throws {
        logger.info("Deleting MLS storage blob for user: \(userDID)")

        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "MLSStorageBlob")
        fetchRequest.predicate = NSPredicate(format: "userDID == %@", userDID)

        let blobs = try viewContext.fetch(fetchRequest)

        for blob in blobs {
            viewContext.delete(blob)
        }

        try saveContext()
        logger.info("Deleted \(blobs.count) storage blob(s)")
    }

    // MARK: - Message Plaintext Helpers

    /// Save plaintext for a sent message (for MLS forward secrecy)
    /// This allows self-sent messages to be displayed even though MLS prevents decryption after sending
    public func savePlaintextForMessage(messageID: String, conversationID: String, plaintext: String, senderID: String) throws {
        logger.info("Saving plaintext for message: \(messageID)")

        // Check if message already exists
        let fetchRequest = MLSMessage.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "messageID == %@", messageID)
        fetchRequest.fetchLimit = 1

        if let existingMessage = try viewContext.fetch(fetchRequest).first {
            // Update existing message with plaintext
            existingMessage.plaintext = plaintext
            logger.debug("Updated existing message with plaintext")
        } else {
            // Create minimal message entry with plaintext
            let message = MLSMessage(context: viewContext)
            message.messageID = messageID
            message.senderID = senderID
            message.plaintext = plaintext
            message.content = Data() // Empty data as placeholder
            message.timestamp = Date()
            message.epoch = 0
            message.sequenceNumber = 0

            // Try to link to conversation if it exists in Core Data
            if let conversation = try? fetchConversation(byID: conversationID) {
                message.conversation = conversation
                logger.debug("Created new message with plaintext and linked to conversation")
            } else {
                // Conversation doesn't exist in Core Data yet - save message without it
                logger.debug("Created new message with plaintext (no conversation link)")
            }
        }

        try saveContext()
        logger.info("Plaintext saved successfully for message: \(messageID)")
    }

    /// Fetch plaintext for a message (returns nil if not found)
    public func fetchPlaintextForMessage(messageID: String) throws -> String? {
        let fetchRequest = MLSMessage.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "messageID == %@", messageID)
        fetchRequest.fetchLimit = 1

        guard let message = try viewContext.fetch(fetchRequest).first else {
            return nil
        }

        return message.plaintext
    }
}

// MARK: - Errors

public enum MLSStorageError: LocalizedError {
    case conversationNotFound(String)
    case memberNotFound(String)
    case messageNotFound(String)
    case keyPackageNotFound(String)
    case saveFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation not found: \(id)"
        case .memberNotFound(let id):
            return "Member not found: \(id)"
        case .messageNotFound(let id):
            return "Message not found: \(id)"
        case .keyPackageNotFound(let id):
            return "Key package not found: \(id)"
        case .saveFailed(let error):
            return "Failed to save: \(error.localizedDescription)"
        }
    }
}
