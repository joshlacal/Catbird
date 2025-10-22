# Catbird Storage and Sync Plan

## Goals
- Keep UI smooth by isolating SwiftData writes in a `@ModelActor`
- Sync only user-meaningful data via CloudKit (settings, drafts)
- Keep caches local to avoid CloudKit churn and quota

## Models
- `AppSettings` (sync): appearance + behavior toggles
- `Draft` (sync): text + context
- `DraftAttachment` (sync-small): metadata + optional small thumbnail
- Caches (local): derived content; not added yet

## Container
- Cloud group: `AppSettings`, `Draft`, `DraftAttachment` (optionally with explicit container id)
- Local group: for future cache models, with `cloudKitDatabase: .none`

## Concurrency
- Use `AppDataStore` (`@ModelActor`) for all writes
- Views use `@Query` for reads on main context

## Migration
- Keep CloudKit-compatible schema (avoid unique constraints that don’t map well; keep relationships optional where needed)
- Add schema versions with `SchemaMigrationPlan` only when necessary

## Notes
- NSUbiquitousKeyValueStore is optional for tiny pre-store toggles; otherwise prefer SwiftData for consistency
