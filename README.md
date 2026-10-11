# Catbird

A modern iOS client for [Bluesky](https://bsky.app), built with SwiftUI and the AT Protocol.

![iOS 18+](https://img.shields.io/badge/iOS-18%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0-blue)

## Features

- 🚀 **Fast & Native**: Built entirely in SwiftUI for optimal iOS performance
- 📱 **Modern Design**: Clean interface following iOS design guidelines
- 🔄 **Real-time Updates**: Live timeline updates and notifications
- 🖼️ **Rich Media**: Full support for images, videos, and embeds
- 💬 **Direct Messaging**: Full chat functionality with emoji reactions
- 🎨 **Themes**: Light, dark, and dim theme options
- ♿ **Accessibility**: Full Dynamic Type and VoiceOver support
- 🔐 **Secure**: Biometric authentication and secure credential storage

## Requirements

- iOS 18.0+
- Xcode 16.0+
- Swift 6.0+

## Installation

1. Clone the repository:
```bash
git clone https://github.com/joshlacal/Catbird.git
cd Catbird
```

2. Open the project in Xcode:
```bash
open Catbird.xcodeproj
```

3. Build and run the project (⌘R)

## Architecture

Catbird uses modern Swift patterns and SwiftUI best practices:

- **State Management**: `@Observable` macro for reactive state
- **Concurrency**: Swift 6 structured concurrency with actors
- **Networking**: [Petrel](https://github.com/joshlacal/Petrel) AT Protocol library
- **Navigation**: Type-safe navigation with SwiftUI's navigation APIs
- **Secondary post lists**: A shared UIKit collection controller recycles iOS rows, forwards the scene environment, and restores normalized scroll offsets per profile tab. macOS uses a native `List` with the same refresh, pagination, and bookmark-removal callbacks.

## Project Structure

```
Catbird/
├── App/                    # App entry point and configuration
├── Core/                   # Core infrastructure
│   ├── Extensions/         # Swift and SwiftUI extensions
│   ├── Models/            # Data models
│   ├── Navigation/        # Navigation system
│   ├── State/             # State management
│   └── UI/                # Reusable UI components
├── Features/              # Feature modules
│   ├── Auth/              # Authentication
│   ├── Chat/              # Direct messaging
│   ├── Feed/              # Timeline and feeds
│   ├── Profile/           # User profiles
│   └── Settings/          # App settings
└── Resources/             # Assets and resources
```

## Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

## Dependencies

- [Petrel](https://github.com/joshlacal/Petrel) - Swift library for the AT Protocol

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with [Petrel](https://github.com/joshlacal/Petrel), a Swift implementation of the AT Protocol
- Thanks to the Bluesky team for creating an open social protocol

## Contact

- Bluesky: [@josh.uno](https://bsky.app/profile/josh.uno)
- GitHub: [@joshlacal](https://github.com/joshlacal)
