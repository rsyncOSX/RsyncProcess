import Foundation
import OSLog

/// Delegate protocol for handling rsync process events
@MainActor
public protocol ProcessHandlerDelegate: AnyObject {
    /// Called when the process terminates
    /// - Parameters:
    ///   - output: Array of output lines from the process, or nil if no output
    ///   - hiddenID: Optional identifier for the process
    func processDidTerminate(output: [String]?, hiddenID: Int?)
    
    /// Called periodically during file processing to report progress
    /// - Parameter count: Current number of lines processed
    func processDidUpdateProgress(lineCount: Int)
    
    /// Returns the path to the rsync executable
    /// - Returns: Full path to rsync binary, or nil if not found
    func rsyncExecutablePath() -> String?
    
    /// Checks a line of output for errors
    /// - Parameter line: Single line of rsync output
    /// - Throws: Error if the line contains an error condition
    func checkOutputLineForError(_ line: String) throws
    
    /// Called when the process reference is updated
    /// - Parameter process: The current Process instance, or nil when cleared
    func updateProcessReference(_ process: Process?)
    
    /// Called when an error is discovered
    /// - Parameter error: The error that occurred
    func handleError(_ error: Error)
    
    /// Whether to check rsync output for errors
    var shouldCheckForErrors: Bool { get }
}

/// Errors that can occur during rsync process execution
public enum RsyncError: LocalizedError {
    case executableNotFound
    case invalidExecutablePath(String)
    case processLaunchFailed(Error)
    case outputEncodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Rsync executable not found. Please verify the rsync path."
        case .invalidExecutablePath(let path):
            return "Invalid rsync executable path: \(path)"
        case .processLaunchFailed(let error):
            return "Failed to launch rsync process: \(error.localizedDescription)"
        case .outputEncodingFailed:
            return "Failed to decode rsync output as UTF-8"
        }
    }
}

// ===================================
// Sources/RsyncProcess/ProcessRsyncVer3x.swift
// ===================================

import Foundation
import OSLog

/// Manages execution of rsync version 3.x processes with real-time output handling
@MainActor
public final class ProcessRsyncVer3x {
    // MARK: - Constants
    
    private enum Constants {
        static let summaryStartMarker = "Number of files"
        static let drainDelayNanoseconds: UInt64 = 100_000_000 // 100ms
        static let maxOutputLines = 100_000 // Prevent unbounded growth
    }
    
    // MARK: - Properties
    
    /// Delegate for handling process events
    private weak var delegate: ProcessHandlerDelegate?
    
    /// Arguments to pass to rsync command
    private let arguments: [String]?
    
    /// Accumulated output from the process
    private(set) var output = [String]()
    
    /// Whether to call the progress handler
    private let shouldReportProgress: Bool
    
    /// Whether an error has been discovered in output
    private var hasDiscoveredError: Bool = false
    
    /// Tasks for async sequence monitoring
    private var fileHandlerTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    
    /// Whether this is a real run (not a dry-run)
    private let isRealRun: Bool
    
    /// Whether the summary section has started
    private var hasSummaryStarted: Bool = false
    
    /// Whether this is a version check operation
    private let isVersionCheck: Bool
    
    /// Optional identifier for the process
    private let hiddenID: Int
    
    // MARK: - Initialization
    
    /// Initialize a new rsync process executor
    /// - Parameters:
    ///   - arguments: Command-line arguments for rsync
    ///   - hiddenID: Optional identifier for tracking this process
    ///   - delegate: Delegate to handle process events
    ///   - reportProgress: Whether to report progress during execution
    public init(
        arguments: [String]?,
        hiddenID: Int = -1,
        delegate: ProcessHandlerDelegate,
        reportProgress: Bool = false
    ) {
        self.arguments = arguments
        self.hiddenID = hiddenID
        self.delegate = delegate
        self.shouldReportProgress = reportProgress
        
        let containsDryRun = arguments?.contains("--dry-run") ?? false
        self.isRealRun = !containsDryRun
        
        self.isVersionCheck = (arguments?.count == 1 && arguments?.contains("--version") == true)
    }
    
    deinit {
        PackageLogger.process.info("ProcessRsyncVer3x: DEINIT")
        fileHandlerTask?.cancel()
        terminationTask?.cancel()
    }
    
    // MARK: - Public Methods
    
    /// Executes the rsync process with configured arguments
    /// - Important: Must be called from the main actor
    /// - Throws: RsyncError if the process cannot be started
    public func executeProcess() throws {
        guard let executablePath = delegate?.rsyncExecutablePath(),
              !executablePath.isEmpty else {
            throw RsyncError.executableNotFound
        }
        
        guard let executableURL = URL(string: "file://\(executablePath)") else {
            throw RsyncError.invalidExecutablePath(executablePath)
        }
        
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments
        
        // Set up pipe for output
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        let fileHandle = pipe.fileHandleForReading
        
        // Set up async monitoring
        setupFileHandlerMonitoring(pipe: pipe, fileHandle: fileHandle)
        setupTerminationMonitoring(task: task, pipe: pipe)
        
        // Update process reference
        delegate?.updateProcessReference(task)
        
        // Launch process
        do {
            try task.run()
            PackageLogger.process.info("ProcessRsyncVer3x: Launched - \(executablePath, privacy: .public)")
            if let args = arguments {
                PackageLogger.process.info("ProcessRsyncVer3x: Arguments - \(args.joined(separator: " "), privacy: .public)")
            }
        } catch {
            delegate?.updateProcessReference(nil)
            throw RsyncError.processLaunchFailed(error)
        }
    }
    
    // MARK: - Private Methods
    
    private func setupFileHandlerMonitoring(pipe: Pipe, fileHandle: FileHandle) {
        fileHandle.waitForDataInBackgroundAndNotify()
        
        let notifications = NotificationCenter.default.notifications(
            named: .NSFileHandleDataAvailable,
            object: fileHandle
        )
        
        fileHandlerTask = Task { [weak self] in
            guard let self = self else { return }
            
            for await _ in notifications {
                if Task.isCancelled { break }
                
                if self.isVersionCheck {
                    await self.handleVersionOutput(fileHandle: fileHandle)
                } else {
                    await self.handleStandardOutput(fileHandle: fileHandle)
                }
            }
        }
    }
    
    private func setupTerminationMonitoring(task: Process, pipe: Pipe) {
        let notifications = NotificationCenter.default.notifications(
            named: Process.didTerminateNotification,
            object: task
        )
        
        terminationTask = Task { [weak self] in
            guard let self = self else { return }
            
            for await _ in notifications {
                if Task.isCancelled { break }
                
                PackageLogger.process.info("ProcessRsyncVer3x: Process terminated, draining remaining output")
                
                // Cancel file handler to stop new notifications
                self.fileHandlerTask?.cancel()
                
                // Wait a bit for any final data
                try? await Task.sleep(nanoseconds: Constants.drainDelayNanoseconds)
                
                // Drain any remaining data
                await self.drainRemainingOutput(from: pipe)
                
                // Perform cleanup
                await self.handleTermination()
            }
        }
    }
    
    private func handleVersionOutput(fileHandle: FileHandle) async {
        let data = fileHandle.availableData
        guard data.count > 0 else { return }
        
        guard let string = String(data: data, encoding: .utf8) else {
            PackageLogger.process.warning("ProcessRsyncVer3x: Failed to decode version output")
            return
        }
        
        string.enumerateLines { [weak self] line, _ in
            self?.output.append(line)
        }
        
        fileHandle.waitForDataInBackgroundAndNotify()
    }
    
    private func handleStandardOutput(fileHandle: FileHandle) async {
        let data = fileHandle.availableData
        guard data.count > 0 else { return }
        
        guard let string = String(data: data, encoding: .utf8) else {
            PackageLogger.process.warning("ProcessRsyncVer3x: Failed to decode output")
            if let delegate = delegate {
                delegate.handleError(RsyncError.outputEncodingFailed)
            }
            return
        }
        
        string.enumerateLines { [weak self] line, _ in
            guard let self = self else { return }
            
            // Prevent unbounded memory growth
            guard self.output.count < Constants.maxOutputLines else {
                PackageLogger.process.warning("ProcessRsyncVer3x: Output limit reached, discarding old lines")
                self.output.removeFirst(1000) // Remove oldest 1000 lines
                return
            }
            
            self.output.append(line)
            
            // Check for summary start during real runs
            if self.isRealRun && !self.hasSummaryStarted {
                if line.contains(Constants.summaryStartMarker) {
                    self.hasSummaryStarted = true
                    PackageLogger.process.info("ProcessRsyncVer3x: Summary section started")
                }
            }
            
            // Check for errors if enabled
            if let delegate = self.delegate,
               delegate.shouldCheckForErrors,
               !self.hasDiscoveredError {
                do {
                    try delegate.checkOutputLineForError(line)
                } catch {
                    self.hasDiscoveredError = true
                    delegate.handleError(error)
                }
            }
        }
        
        // Report progress if enabled and not in summary section
        if shouldReportProgress && !hasSummaryStarted && isRealRun {
            delegate?.processDidUpdateProgress(lineCount: output.count)
        }
        
        fileHandle.waitForDataInBackgroundAndNotify()
    }
    
    private func drainRemainingOutput(from pipe: Pipe) async {
        var totalDrained = 0
        let fileHandle = pipe.fileHandleForReading
        
        while true {
            let data = fileHandle.availableData
            
            if data.isEmpty {
                PackageLogger.process.info("ProcessRsyncVer3x: Drain complete - \(totalDrained) bytes")
                break
            }
            
            totalDrained += data.count
            PackageLogger.process.debug("ProcessRsyncVer3x: Draining \(data.count) bytes")
            
            // Process the drained data
            if let string = String(data: data, encoding: .utf8) {
                string.enumerateLines { [weak self] line, _ in
                    guard let self = self,
                          self.output.count < Constants.maxOutputLines else { return }
                    self.output.append(line)
                }
            }
            
            // Small delay to allow more data to arrive
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }
    
    private func handleTermination() async {
        delegate?.processDidTerminate(output: output.isEmpty ? nil : output, hiddenID: hiddenID)
        delegate?.updateProcessReference(nil)
        
        // Cancel and wait for tasks to complete
        fileHandlerTask?.cancel()
        terminationTask?.cancel()
        
        _ = await fileHandlerTask?.result
        _ = await terminationTask?.result
        
        PackageLogger.process.info("ProcessRsyncVer3x: Cleanup complete on \(ThreadUtils.isMain ? "main" : "background") thread")
    }
}

// ===================================
// Sources/RsyncProcess/Internal/PackageLogger.swift
// ===================================

import OSLog

/// Internal logger for the RsyncProcess package
internal enum PackageLogger {
    static let process = Logger(subsystem: "com.rsyncprocess", category: "process")
}

// ===================================
// Sources/RsyncProcess/Internal/ThreadUtils.swift
// ===================================

import Foundation

/// Internal thread utilities for the RsyncProcess package
internal enum ThreadUtils {
    static var isMain: Bool {
        return Thread.isMainThread
    }
}

// ===================================
// Sources/RsyncProcess/Legacy/ProcessHandlers.swift
// ===================================

import Foundation

/// Legacy closure-based handlers for process execution
/// - Note: Consider using ProcessHandlerDelegate protocol for new code
public class ProcessHandlers {
    /// Called when process terminates with output and hiddenID
    public var processtermination: ([String]?, Int?) -> Void
    
    /// Called during file processing with count
    public var filehandler: (Int) -> Void
    
    /// Returns the path to rsync executable
    public var rsyncpath: () -> String?
    
    /// Checks a line for errors and throws if found
    public var checklineforerror: (String) throws -> Void
    
    /// Updates the current process reference
    public var updateprocess: (Process?) -> Void
    
    /// Propagates errors to error handler
    public var propogateerror: (Error) -> Void
    
    /// Flag to enable/disable error checking in rsync output
    public var checkforerrorinrsyncoutput: Bool
    
    /// Initialize ProcessHandlers with all required closures
    public init(
        processtermination: @escaping ([String]?, Int?) -> Void,
        filehandler: @escaping (Int) -> Void,
        rsyncpath: @escaping () -> String?,
        checklineforerror: @escaping (String) throws -> Void,
        updateprocess: @escaping (Process?) -> Void,
        propogateerror: @escaping (Error) -> Void,
        checkforerrorinrsyncoutput: Bool
    ) {
        self.processtermination = processtermination
        self.filehandler = filehandler
        self.rsyncpath = rsyncpath
        self.checklineforerror = checklineforerror
        self.updateprocess = updateprocess
        self.propogateerror = propogateerror
        self.checkforerrorinrsyncoutput = checkforerrorinrsyncoutput
    }
}

// MARK: - Adapter for legacy code

extension ProcessHandlers: ProcessHandlerDelegate {
    public func processDidTerminate(output: [String]?, hiddenID: Int?) {
        processtermination(output, hiddenID)
    }
    
    public func processDidUpdateProgress(lineCount: Int) {
        filehandler(lineCount)
    }
    
    public func rsyncExecutablePath() -> String? {
        rsyncpath()
    }
    
    public func checkOutputLineForError(_ line: String) throws {
        try checklineforerror(line)
    }
    
    public func updateProcessReference(_ process: Process?) {
        updateprocess(process)
    }
    
    public func handleError(_ error: Error) {
        propogateerror(error)
    }
    
    public var shouldCheckForErrors: Bool {
        checkforerrorinrsyncoutput
    }
}
