# Memory Optimization Summary for CAR File Parsing

## Problem
The app was experiencing Out of Memory (OOM) crashes when parsing large Bluesky backup CAR files, with memory usage spiking from 100MB to 1.9GB.

## Implemented Solutions

### 1. Forced Streaming Parser for ALL Files
- **Location**: `RepositoryParsingService.swift`
- **Change**: Always use streaming parser regardless of file size
- **Impact**: Prevents loading entire CAR file into memory

### 2. Aggressive Memory Limits
- **CBOR max object size**: Reduced from 100MB to 2MB
- **Memory budget per decode**: Reduced from 100MB to 10MB  
- **Memory warning threshold**: 250MB (iOS safe limit)
- **Memory critical threshold**: 400MB (before iOS kill at ~1.4GB)

### 3. Batch Processing Optimizations
- **Batch size**: Reduced from 100 to 5 records
- **Save frequency**: Every 2 records instead of 10
- **Context management**: Clear SwiftData context features that retain objects
  - `autosaveEnabled = false`
  - `undoManager = nil`

### 4. Memory Management During Parsing
- **Autoreleasepool usage**: Wrap CBOR parsing operations
- **Minimal data extraction**: Only keep essential fields per record type
- **Clear raw data immediately**: Set block data to empty after processing
- **Memory checks**: Every 10 blocks with pause if high usage
- **Pre-parse checks**: Abort if memory > 250MB before starting

### 5. Removed Features That Increase Memory
- **No concurrent processing**: Process blocks sequentially
- **No regular parsing fallback**: Always use streaming
- **No full data retention**: Extract minimal fields only

### 6. Timeline View Pagination
- **Page size**: 100 posts per page
- **Infinite scrolling**: Load more as user scrolls
- **Prevents loading entire dataset into memory**

## Memory Usage Targets
- **Normal operation**: < 200MB
- **Warning threshold**: 250MB (pause and check)
- **Critical threshold**: 400MB (abort parsing)
- **iOS kill threshold**: ~1.4GB (must never reach)

## Key Files Modified
1. `StreamingCARParser.swift` - Core streaming parser with memory limits
2. `RepositoryParsingService.swift` - Service layer forcing streaming mode
3. `TimelineView.swift` - Paginated UI to prevent loading all posts
4. `StringSanitization.swift` - Text sanitization to prevent CoreText crashes

## Testing Recommendations
1. Monitor memory usage with Instruments during CAR parsing
2. Test with large CAR files (>100MB)
3. Verify memory stays under 400MB during entire parsing process
4. Ensure UI remains responsive during parsing
5. Check that parsed data is correctly saved despite aggressive memory management

## Future Improvements
- Consider using memory-mapped file I/O for even better efficiency
- Implement adaptive throttling based on current memory pressure
- Add telemetry to track memory usage patterns in production
- Consider processing in smaller chunks with progress persistence