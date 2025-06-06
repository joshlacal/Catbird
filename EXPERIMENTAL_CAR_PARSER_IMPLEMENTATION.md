# 🧪 EXPERIMENTAL CAR File Parser Implementation

**⚠️ WARNING: HIGHLY EXPERIMENTAL FUNCTIONALITY ⚠️**

This document outlines the implementation of experimental CAR (Content Addressable aRchive) file parsing functionality for Catbird. This feature allows users to parse their backup CAR files into structured SwiftData models for browsing and analysis.

## Overview

The CAR parser implementation consists of:

1. **SwiftData Models** for parsed repository data
2. **CARParser** core engine using Petrel's CID infrastructure  
3. **RepositoryParsingService** for background parsing with progress tracking
4. **Experimental UI Components** with clear warnings and fallback options
5. **Comprehensive Error Handling** and debug logging

## Implementation Details

### 1. SwiftData Models (`RepositoryModels.swift`)

**Created Models:**
- `RepositoryRecord` - Main record linking to BackupRecord with parsing metadata
- `ParsedPost` - Individual posts from `app.bsky.feed.post` records
- `ParsedProfile` - Profile data from `app.bsky.actor.profile` records  
- `ParsedMedia` - Media references extracted from posts
- `ParsedConnection` - Social connections from `app.bsky.graph.follow` records
- `ParsedUnknownRecord` - Unknown record types for debugging

**Key Features:**
- All models include raw CBOR data for debugging
- Parsing confidence scores for reliability assessment
- Comprehensive metadata tracking (success rates, error messages, etc.)
- Human-readable formatting helpers

### 2. CAR Parser Core Engine (`CARParser.swift`)

**Capabilities:**
- Parses CAR file structure (header, blocks, CIDs)
- Decodes IPLD DAG-CBOR records using Petrel's CID infrastructure
- Handles standard AT Protocol record types:
  - `app.bsky.feed.post` (posts, replies, quotes)
  - `app.bsky.actor.profile` (user profiles)
  - `app.bsky.graph.follow` (social connections)
- Gracefully handles unknown record types
- Extensive error handling for corrupted/invalid CAR files

**Safety Features:**
- Never modifies original CAR files
- Preserves raw CBOR data alongside parsed data
- Parsing confidence scores for records
- Comprehensive debug logging
- Memory-efficient processing for large files

### 3. Repository Parsing Service (`RepositoryParsingService.swift`)

**Features:**
- Background processing to avoid blocking UI
- Progress tracking with cancellation support
- Automatic error recovery and retry logic
- Parsing status persistence in SwiftData
- Memory management for large CAR files
- Experimental feature toggle for safety

**Operation States:**
- `starting` - Initializing parsing operation
- `readingCarFile` - Loading CAR data from disk
- `parsingStructure` - Parsing CAR blocks and records
- `savingToDatabase` - Storing parsed data in SwiftData
- `completed` - Parsing finished successfully
- `failed` - Parsing encountered errors
- `cancelled` - User cancelled operation

### 4. Experimental UI Components

**Backup Settings Integration:**
- Experimental feature toggle with clear warnings
- Detailed safety information for users
- Option to disable experimental features easily

**Backup Details Enhancement:**
- "Parse Repository (EXPERIMENTAL)" button with warnings
- Real-time parsing progress display
- Parsing status and confidence indicators
- Detailed parsing statistics (posts, connections, media)
- Fallback to raw CAR file info if parsing fails

**User Safety Measures:**
- Clear experimental warnings before parsing
- Detailed information about risks and limitations
- Progress indication with cancellation option
- Comprehensive error reporting

### 5. Integration with App Architecture

**AppState Integration:**
- Added `RepositoryParsingService` to AppState
- Configured with ModelContext during app initialization
- Accessible throughout the app for parsing operations

**SwiftData Integration:**
- Added all experimental models to ModelContainer
- Properly configured relationships between models
- Efficient querying and data management

## Usage Flow

1. **Enable Experimental Features**: User enables repository parsing in backup settings
2. **Select Backup**: User views backup details and chooses to parse repository
3. **Warning Confirmation**: Clear experimental warning with safety information
4. **Background Parsing**: CAR file is parsed in background with progress updates
5. **Results Display**: Parsed data is shown with confidence scores and statistics
6. **Analysis Options**: Users can explore parsed posts, profiles, connections, and media

## Safety Considerations

### Data Integrity
- Original CAR files are never modified
- All parsing operations are read-only
- Raw CBOR data is preserved for debugging
- Parsing can be re-attempted if initial attempt fails

### Error Handling
- Comprehensive error handling for malformed CAR files
- Graceful degradation when parsing fails
- Detailed error messages for troubleshooting
- Fallback to raw CAR file viewing

### Performance
- Background processing prevents UI blocking
- Memory-efficient batch processing
- Progress tracking with cancellation support
- Automatic cleanup of parsing operations

### User Experience
- Clear experimental warnings throughout UI
- Detailed safety information before parsing
- Progress indication during long operations
- Comprehensive error reporting and recovery options

## Limitations and Risks

**Known Limitations:**
- May fail with malformed or corrupted CAR files
- Processing can take several minutes for large repositories
- Parsing confidence varies based on record type and data quality
- Some AT Protocol record types may not be fully supported

**Potential Risks:**
- High memory usage for very large CAR files
- Possible parsing errors with edge cases in AT Protocol data
- Extended processing time could impact app performance
- Experimental nature means limited testing coverage

## Technical Dependencies

**Required Libraries:**
- Petrel (CID and IPLD infrastructure)
- SwiftCBOR (CBOR decoding)
- SwiftData (data persistence)
- OSLog (debug logging)
- CryptoKit (hash verification)

**Architecture Dependencies:**
- AppState for service coordination
- BackupManager for CAR file access
- ModelContext for SwiftData operations

## Future Enhancements

**Potential Improvements:**
- Support for additional AT Protocol record types
- Improved parsing confidence algorithms
- Better memory management for extremely large files
- Export functionality for parsed data
- Advanced search and filtering of parsed content
- Visualization tools for repository analysis

**Migration Path:**
- Feature toggle allows gradual rollout
- Experimental status provides flexibility for changes
- SwiftData models can be evolved with migrations
- Parser engine can be refined based on user feedback

## Conclusion

This experimental CAR parser implementation provides a foundation for advanced backup analysis in Catbird. While marked as experimental due to its cutting-edge nature, it includes comprehensive safety measures and error handling to protect user data and provide valuable insights into their AT Protocol repositories.

The implementation prioritizes safety, user experience, and technical robustness while acknowledging the experimental nature of parsing AT Protocol CAR files. Users are clearly informed about the experimental status and potential limitations throughout the interface.