# Memory Optimization Fixes for CAR Parser

## Immediate Critical Fixes

### 1. Lower Memory Thresholds
In `CARParser.swift`, update the MemoryMonitor thresholds:

```swift
private class MemoryMonitor {
    // iOS apps typically get killed around 1-2GB
    private let warningThreshold: UInt64 = 500_000_000   // 500MB warning
    private let criticalThreshold: UInt64 = 800_000_000  // 800MB critical
    
    // Add progressive memory pressure levels
    private let lightPressure: UInt64 = 300_000_000      // 300MB light
    private let moderatePressure: UInt64 = 500_000_000  // 500MB moderate
}
```

### 2. Reduce Batch Sizes
In `RepositoryParsingService.swift`:

```swift
// Reduce default batch size
batchSize: Int = 25  // Was 100 - reduce to 25 for memory safety
```

### 3. Always Use Streaming for Large Files
Lower the threshold for streaming parser:

```swift
// Use streaming for files >5MB (was 10MB)
let shouldUseStreaming = fileSize > 5_000_000 || recordDensity > 2500
```

### 4. Implement Progressive Memory Management

Add this to `CARParser.swift`:

```swift
private func performMemoryManagedParsing() async throws {
    // Force memory cleanup periodically
    if recordsProcessed % 10 == 0 {
        // Explicitly trigger autorelease pool drain
        autoreleasepool {
            // Process records
        }
        
        // Give system time to reclaim memory
        if memoryMonitor.getCurrentMemoryUsage().isWarning {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
    }
}
```

### 5. Stream Processing Improvements
Update streaming frequency in `RepositoryParsingService.swift`:

```swift
// Save and clear memory every 5 records (was 10)
if recordsProcessed % 5 == 0 {
    try modelContext.save()
    modelContext.processPendingChanges()
    
    // Force memory cleanup
    autoreleasepool {
        // Clear any temporary objects
    }
}
```

### 6. Implement Memory-Mapped File Reading
Instead of loading entire file:

```swift
private func readFileWithMemoryMapping(at url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    
    // Use memory mapping for large files
    if let mappedData = try? Data(contentsOf: url, options: .mappedIfSafe) {
        return mappedData
    }
    
    // Fallback to regular reading for small files
    return try Data(contentsOf: url)
}
```

### 7. Add Memory Pressure Response
Implement iOS memory warning handler:

```swift
// In your main app or view controller
override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    
    // Cancel any ongoing parsing
    Task {
        await repositoryParsingService.cancelAllParsing()
    }
    
    // Clear caches
    URLCache.shared.removeAllCachedResponses()
}
```

## Testing Memory Optimizations

### 1. Test with Instruments
```bash
# Profile with Instruments from command line
xcrun xctrace record --template "Allocations" --launch "YourApp.app"
```

### 2. Simulate Memory Pressure
In Simulator: Debug → Simulate Memory Warning

### 3. Monitor in Real-Time
Add this debug view to your app:

```swift
struct MemoryDebugView: View {
    @State private var memoryUsage: String = "0 MB"
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Text("Memory: \(memoryUsage)")
            .onReceive(timer) { _ in
                updateMemoryUsage()
            }
    }
    
    func updateMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usage = info.resident_size
            memoryUsage = ByteCountFormatter.string(fromByteCount: Int64(usage), countStyle: .memory)
        }
    }
}
```

## Recommended Parsing Strategy

1. **Always use streaming** for CAR files >5MB
2. **Process in micro-batches** of 5-10 records
3. **Save frequently** to release memory
4. **Monitor continuously** and pause/cancel if needed
5. **Use autoreleasepool** blocks for temporary objects
6. **Implement progressive backoff** when memory increases

## Emergency Memory Recovery

If memory issues persist, implement this emergency recovery:

```swift
func emergencyMemoryRecovery() {
    // 1. Cancel all parsing
    activeOperations.removeAll()
    
    // 2. Clear all caches
    URLCache.shared.removeAllCachedResponses()
    logBuffer.clear()
    
    // 3. Force garbage collection
    autoreleasepool {
        // Force autorelease pool drain
    }
    
    // 4. Save and reset context
    try? modelContext?.save()
    modelContext?.processPendingChanges()
}
```

## Long-term Solutions

1. **Implement chunked file reading** - Read CAR file in chunks rather than all at once
2. **Use background processing** with `BGProcessingTask` for large files
3. **Implement on-disk caching** instead of in-memory storage
4. **Consider using SQLite directly** for temporary storage during parsing
5. **Add user-configurable memory limits** in settings

## Monitoring Best Practices

1. Log memory usage at key points:
   - Before parsing starts
   - After each batch
   - When saving to database
   - After completion

2. Set up analytics to track:
   - Peak memory usage
   - Parsing duration
   - Success/failure rates
   - Device model (different iOS devices have different memory limits)

3. Add user-facing warnings:
   - "Large file detected - parsing may take time"
   - "Low memory - some features may be limited"
   - "Parsing paused due to memory constraints"

## Testing Checklist

- [ ] Test with smallest CAR file (baseline)
- [ ] Test with 10MB CAR file
- [ ] Test with 50MB CAR file  
- [ ] Test with 100MB+ CAR file
- [ ] Test on older devices (iPhone 12 or earlier)
- [ ] Test with other apps running (memory pressure)
- [ ] Test after device has been running for days
- [ ] Monitor with Instruments during all tests

Remember: iOS devices have strict memory limits. iPhone 15 Pro has ~6GB RAM but apps typically get only 1-2GB before termination!