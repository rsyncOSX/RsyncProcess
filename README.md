## Hi there 👋

This package is code for monitoring the rsync process in RsyncUI.

# RsyncProcess

A Swift package for executing and monitoring rsync processes with real-time output capture, error handling, and progress tracking.

## Features

- **Process Execution**: Execute rsync commands with custom arguments and environment variables
- **Real-time Output Capture**: Monitor rsync output as it happens with observable models
- **Error Detection**: Automatic error detection in rsync output with custom error handling
- **Version Support**: Compatible with both rsync 3.x and openrsync
- **Progress Tracking**: Track file synchronization progress with file handler callbacks
- **Thread-Safe**: Actor-based output capture for safe concurrent access
- **Logging**: Built-in logging support with OSLog integration

## Requirements

- Swift 5.9+
- macOS 13.0+ / iOS 16.0+
- Rsync binary installed on the system

## Usage

### Basic Example

```swift
import RsyncProcess

// Create process handlers
let handlers = ProcessHandlers(
    processTermination: { output, hiddenID in
        print("Process completed with \(output?.count ?? 0) lines")
    },
    fileHandler: { count in
        print("Processed \(count) files")
    },
    rsyncPath: { "/usr/bin/rsync" },
    checkLineForError: { line in
        if line.contains("error") {
            throw NSError(domain: "rsync", code: 1)
        }
    },
    updateProcess: { process in
        // Store or update process reference
    },
    propagateError: { error in
        print("Error: \(error)")
    },
    logger: { id, output in
        // Log output asynchronously
    },
    checkForErrorInRsyncOutput: true,
    rsyncVersion3: true,
    environment: nil
)

// Create and execute rsync process
let rsyncProcess = RsyncProcess(
    arguments: ["-av", "/source/", "/destination/"],
    handlers: handlers,
    fileHandler: true
)

try await rsyncProcess.executeProcess()
```

### With Real-time Output Capture

```swift
// Enable output capture
await RsyncOutputCapture.shared.enable()

// Create handlers with automatic output capture
let handlers = ProcessHandlers.withOutputCapture(
    processTermination: { output, hiddenID in
        print("Completed")
    },
    fileHandler: { count in },
    rsyncPath: { "/usr/bin/rsync" },
    checkLineForError: { _ in },
    updateProcess: { _ in },
    propagateError: { error in },
    logger: { _, _ in },
    checkForErrorInRsyncOutput: true,
    rsyncVersion3: true,
    environment: nil
)

// Execute process
let rsyncProcess = RsyncProcess(
    arguments: ["-av", "/source/", "/destination/"],
    handlers: handlers,
    fileHandler: true
)

try await rsyncProcess.executeProcess()

// Access captured output
let output = await RsyncOutputCapture.shared.getAllLines()
```

### Observing Output in SwiftUI

```swift
import SwiftUI
import RsyncProcess

struct RsyncOutputView: View {
    @State private var printLines = PrintLines.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                ForEach(printLines.output, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
        .onAppear {
            Task {
                await RsyncOutputCapture.shared.enable()
            }
        }
    }
}
```

## Core Components

### RsyncProcess

Main class for executing rsync commands. Handles process lifecycle, output streaming, and error detection.

**Key Methods:**
- `executeProcess()`: Launches the rsync process with configured arguments
- `init(arguments:hiddenID:handlers:usefilehandler:)`: Initialize with full configuration
- `init(arguments:handlers:filehandler:)`: Convenience initializer

### ProcessHandlers

Configuration struct containing all callback handlers for process events.

**Properties:**
- `processtermination`: Called when process completes
- `filehandler`: Called during file processing
- `rsyncpath`: Returns path to rsync executable
- `checklineforerror`: Validates output lines for errors
- `updateprocess`: Updates process reference
- `propogateerror`: Error propagation handler
- `logger`: Async logging handler
- `printlines`: Optional real-time output handler

### RsyncOutputCapture

Thread-safe actor for capturing and managing rsync output across the application.

**Key Methods:**
- `enable(writeToFile:)`: Enable output capture with optional file logging
- `disable()`: Disable output capture
- `captureLine(_:)`: Capture a single line
- `getAllLines()`: Retrieve all captured lines
- `getRecentLines(count:)`: Get the most recent N lines
- `clear()`: Clear captured output

### PrintLines

Observable model for SwiftUI integration, automatically updated by the output capture system.

## Error Handling

The package defines custom errors through `RsyncError`:

- `executableNotFound`: Rsync binary not found
- `invalidExecutablePath`: Invalid path to rsync
- `processLaunchFailed`: Failed to launch process
- `outputEncodingFailed`: UTF-8 decoding failed

## Advanced Features

### Dry Run Detection

The package automatically detects `--dry-run` arguments and adjusts progress reporting accordingly.

### Version Detection

Supports both rsync 3.x and openrsync with different output parsing strategies.

### Summary Detection

Automatically identifies the beginning of rsync's summary output to provide accurate progress reporting during real runs.

### File Output

Optionally write captured output to a file for debugging or audit purposes:

```swift
let logURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("rsync-output.log")
await RsyncOutputCapture.shared.enable(writeToFile: logURL)
```

## License

MIT

## Author

Thomas Evensen