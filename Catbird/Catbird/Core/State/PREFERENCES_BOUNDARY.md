# Preferences Boundary

This document defines which preferences are server-owned (Bluesky) versus client-owned (Catbird) and how they are stored/synced.

## Server-owned (source of truth: Bluesky API)
- Feed algorithm choices that are backed by the server
- Muted users / lists and content filters managed server-side
- Notification delivery prefs managed by the service

These should be fetched and updated via the API. Local storage is a cache only.

## Client-owned (source of truth: device + iCloud)
Stored in SwiftData `AppSettings` and synced via CloudKit:
- Theme (system/light/dark)
- Font scale / readability
- Autoplay videos, haptics, reduce motion
- Language / locale overrides
- UI layout choices not represented on server

## Drafts
- Stored in SwiftData (`Draft`, `DraftAttachment`) and synced via CloudKit so you can continue a post on another device.
- Only small thumbnails are synced; original media must be reattached locally.

## Not Synced
- Timeline/feed caches and media caches
- Ephemeral UI state and scroll offsets
- Authentication/session (Keychain only)

## Concurrency
- Reads for UI via SwiftUI `@Query` on the main context
- All writes/imports go through a shared `AppDataStore` `@ModelActor` to avoid main-actor contention
