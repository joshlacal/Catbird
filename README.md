# Catbird - A Modern Bluesky Client

Catbird is a native iOS client for [Bluesky](https://bsky.app), built with SwiftUI and modern Swift features.

## Architecture

Catbird follows a modern SwiftUI architecture with Observable state management:

```
AppState (Observable)
   │
   ├── Authentication & User Session
   │
   ├── PostShadowManager (Actor)
   │    └── Post Interaction State
   │
   └── Feed Management
        └── Loading & Pagination
```

### Core Components

1. **AppState**: Central state container using the `@Observable` macro for SwiftUI integration
2. **PostShadowManager**: Actor for thread-safe management of post interaction state
3. **FeedModel**: Observable model for managing feed data with pagination
4. **PostViewModel**: Handles individual post interactions (likes, reposts, etc.)

### Features

- Timeline feed with optimized scrolling
- Post interaction (like, repost, reply, quote)
- Image and video embedding
- Thread views
- Profile browsing

## Technologies

- SwiftUI for UI
- Swift 6 Observation & Structured Concurrency
- Actor model for thread safety
- Image & video caching and prefetching
- SwiftData for local caching

## Building the Project

1. Clone the repository
2. Open `Catbird.xcodeproj` in Xcode 15 or later
3. Build and run the `Catbird` scheme

## Project Structure

- `/Catbird`: Main app code
  - `/Core`: Core architecture components
    - `/State`: State management
    - `/Models`: Data models
    - `/Navigation`: Navigation handling
  - `/Features`: Feature modules
    - `/Auth`: Authentication
    - `/Feed`: Feed display
    - `/Video`: Video handling
  - `/Extensions`: Swift extensions

## Development Status

This project is under active development. See [project_status.md](project_status.md) for current status.

## License

[MIT License](LICENSE.md)
