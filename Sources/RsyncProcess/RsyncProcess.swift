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
            "Rsync executable not found. Please verify the rsync path."
        case let .invalidExecutablePath(path):
            "Invalid rsync executable path: \(path)"
        case let .processLaunchFailed(error):
            "Failed to launch rsync process: \(error.localizedDescription)"
        case .outputEncodingFailed:
            "Failed to decode rsync output as UTF-8"
        }
    }
}

// ===================================
// Sources/RsyncProcess/ProcessRsyncVer3x.swift
// ===================================

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

    // Tasks
    private var sequenceFileHandlerTask: Task<Void, Never>?
    private var sequenceTerminationTask: Task<Void, Never>?

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
        shouldReportProgress = reportProgress

        let containsDryRun = arguments?.contains("--dry-run") ?? false
        isRealRun = !containsDryRun

        isVersionCheck = (arguments?.count == 1 && arguments?.contains("--version") == true)
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
              !executablePath.isEmpty
        else {
            throw RsyncError.executableNotFound
        }

        guard let executableURL = URL(string: "file://\(executablePath)") else {
            throw RsyncError.invalidExecutablePath(executablePath)
        }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        // Pipe for reading output from Process
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let outHandle = pipe.fileHandleForReading
        outHandle.waitForDataInBackgroundAndNotify()

        // AsyncSequence
        let sequencefilehandler = NotificationCenter.default.notifications(
            named: NSNotification.Name.NSFileHandleDataAvailable,
            object: outHandle
        )

        let sequencetermination = NotificationCenter.default.notifications(
            named: Process.didTerminateNotification,
            object: task
        )

        sequenceFileHandlerTask = Task {
            for await _ in sequencefilehandler {
                if self.isVersionCheck == true {
                    await self.datahandlersyncversion(pipe)
                } else {
                    await self.datahandle(pipe)
                }
            }
        }

        sequenceTerminationTask = Task {
            for await _ in sequencetermination {
                PackageLogger.process.info("ProcessHandlers: Process terminated - starting potensial drain")
                sequenceFileHandlerTask?.cancel()
                try? await Task.sleep(nanoseconds: Constants.drainDelayNanoseconds)
                var totalDrained = 0
                while true {
                    let data: Data = pipe.fileHandleForReading.availableData
                    if data.isEmpty {
                        PackageLogger.process.info("ProcessHandlers: Drain complete - \(totalDrained) bytes total")
                        break
                    }

                    totalDrained += data.count
                    PackageLogger.process.info("ProcessHandlers: Draining \(data.count) bytes")

                    // IMPORTANT: Actually process the drained data
                    if let text = String(data: data, encoding: .utf8) {
                        // PackageLogger.process.info("ProcessRsyncVer3x: Drained text: \(text)")
                        self.output.append(text)
                    }
                }

                await self.termination()
            }
        }

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

    func termination() async {
        delegate?.processDidTerminate(output: output.isEmpty ? nil : output, hiddenID: hiddenID)
        delegate?.updateProcessReference(nil)
        // Cancel Tasks
        sequenceFileHandlerTask?.cancel()
        sequenceTerminationTask?.cancel()
        await sequenceFileHandlerTask?.value
        await sequenceTerminationTask?.value

        PackageLogger.process.info("ProcessHandlers: process = nil and termination discovered \(ThreadUtils.isMain, privacy: .public) but on \(Thread.current, privacy: .public)")
    }

    func datahandlersyncversion(_ pipe: Pipe) async {
        let outHandle = pipe.fileHandleForReading
        let data = outHandle.availableData
        if data.count > 0 {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                str.enumerateLines { line, _ in
                    self.output.append(line)
                }
                outHandle.waitForDataInBackgroundAndNotify()
            }
        }
    }

    func datahandle(_ pipe: Pipe) async {
        let outHandle = pipe.fileHandleForReading
        let data = outHandle.availableData
        if data.count > 0 {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                str.enumerateLines { line, _ in
                    self.output.append(line)

                    // Check for summary start during real runs
                    if self.isRealRun, !self.hasSummaryStarted {
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
                if shouldReportProgress, !hasSummaryStarted, isRealRun {
                    delegate?.processDidUpdateProgress(lineCount: output.count)
                }

                outHandle.waitForDataInBackgroundAndNotify()
            }
        }
    }
}

// ===================================
// Sources/RsyncProcess/Internal/PackageLogger.swift
// ===================================

enum PackageLogger {
    static let process = Logger(subsystem: "com.rsyncprocess", category: "process")
}

// ===================================
// Sources/RsyncProcess/Internal/ThreadUtils.swift
// ===================================

enum ThreadUtils {
    static var isMain: Bool {
        Thread.isMainThread
    }
}

// ===================================
// Sources/RsyncProcess/Legacy/ProcessHandlers.swift
// ===================================

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
