import Foundation
import OSLog

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
public final class RsyncProcess {
    // Process handlers
    public private(set) var handlers: ProcessHandlers
    // Arguments to command
    var arguments: [String]?
    // Output
    public private(set) var output = [String]()
    // Use filehandler
    var useFileHandler: Bool = false
    // Check for error
    var errorDiscovered: Bool = false
    // Tasks
    var sequenceFileHandlerTask: Task<Void, Never>?
    var sequenceTerminationTask: Task<Void, Never>?
    // The real run
    // Used to not report the last status from rsync for more precise progress report
    // the not reported lines are appended to output though for logging statistics reporting
    var isRealRun: Bool = false
    // The beginning of summarized status is discovered
    // rsync = "Number of files" at start of last line nr 16
    // openrsync = "Number of files" at start of last line nr 14
    var hasSeenSummaryStart: Bool = false
    // When RsyncUI starts or version of rsync is changed
    // the arguments is only one and contains ["--version"] only
    var isVersionProbe: Bool = false
    // hiddenID
    var hiddenID: Int = -1
    // Summary starter of rsync
    private static let summaryStartMarker = "Number of files"
    // Privat property to mark if real-time output is enabled or not
    private var isRealtimeOutputEnabled: Bool = false

    public func executeProcess() throws {
        guard let executablePath = handlers.rsyncPath() else {
            throw RsyncError.executableNotFound
        }

        let executableURL = URL(fileURLWithPath: executablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RsyncError.invalidExecutablePath(executablePath)
        }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        // If there are any Environmentvariables like
        // SSH_AUTH_SOCK": "/Users/user/.gnupg/S.gpg-agent.ssh"
        if let environment = handlers.environment {
            task.environment = environment
        }
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
            self.isRealtimeOutputEnabled = await RsyncOutputCapture.shared.isCapturing()
            for await _ in sequencefilehandler {
                if self.isVersionProbe == true {
                    await self.handleVersionData(pipe)
                } else {
                    if self.handlers.rsyncVersion3 == true {
                        await self.handleRsync3Data(pipe)
                    } else {
                        await self.handleOpenRsyncData(pipe)
                    }
                }
            }
        }

        sequenceTerminationTask = Task {
            for await _ in sequencetermination {
                sequenceFileHandlerTask?.cancel()
                try? await Task.sleep(nanoseconds: 50_000_000)
                var totalDrained = 0
                while true {
                    let data: Data = pipe.fileHandleForReading.availableData
                    if data.isEmpty {
                        Logger.process.debugmessageonly("RsyncProcess: Drain complete - \(totalDrained) bytes total")
                        break
                    }

                    totalDrained += data.count
                    Logger.process.debugmessageonly("RsyncProcess: Draining \(data.count) bytes")

                    // IMPORTANT: Actually process the drained data
                    if let text = String(data: data, encoding: .utf8) {
                        self.output.append(text)
                    }
                }

                await self.termination()
            }
        }
        // Update current process task
        handlers.updateProcess(task)

        do {
            try task.run()
        } catch let e {
            let error = e
            // SharedReference.shared.errorobject?.alert(error: error)
            handlers.propagateError(error)
        }
        if let launchPath = task.launchPath, let arguments = task.arguments {
            Logger.process.debugmessageonly("RsyncProcess: COMMAND - \(launchPath)")
            Logger.process.debugmessageonly("RsyncProcess: ARGUMENTS - \(arguments.joined(separator: "\n"))")
        }
    }

    public init(arguments: [String]?,
                hiddenID: Int,
                handlers: ProcessHandlers,
                useFileHandler: Bool) {
        self.arguments = arguments
        self.hiddenID = hiddenID
        self.handlers = handlers
        self.useFileHandler = useFileHandler

        let argumentsContainDryRun = arguments?.contains("--dry-run") ?? false
        isRealRun = !argumentsContainDryRun

        if arguments?.count == 1 {
            isVersionProbe = arguments?.contains("--version") ?? false
        }
    }

    public convenience init(arguments: [String]?,
                            handlers: ProcessHandlers,
                            fileHandler: Bool) {
        self.init(arguments: arguments,
                  hiddenID: -1,
                  handlers: handlers,
                  useFileHandler: fileHandler)
    }

    deinit {
        Logger.process.debugmessageonly("RsyncProcess: DEINIT")
    }
}

extension RsyncProcess {
    func handleVersionData(_ pipe: Pipe) async {
        let outHandle = pipe.fileHandleForReading
        let data = outHandle.availableData
        if data.count > 0 {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                str.enumerateLines { line, _ in
                    self.output.append(line)
                    if self.isRealtimeOutputEnabled {
                        if let printLine = self.handlers.printLine {
                            printLine(line)
                        }
                    }
                }
                outHandle.waitForDataInBackgroundAndNotify()
            }
        }
    }

    func handleOpenRsyncData(_ pipe: Pipe) async {
        let outHandle = pipe.fileHandleForReading
        let data = outHandle.availableData
        if data.count > 0 {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                str.enumerateLines { line, _ in
                    self.output.append(line)
                    if self.isRealtimeOutputEnabled {
                        if let printLine = self.handlers.printLine {
                            printLine(line)
                        }
                    }
                    if self.handlers.checkForErrorInRsyncOutput,
                       self.errorDiscovered == false {
                        do {
                            try self.handlers.checkLineForError(line)
                        } catch let e {
                            self.errorDiscovered = true
                            let error = e
                            self.handlers.propagateError(error)
                        }
                    }
                }
                // Send message about files
                if useFileHandler {
                    handlers.fileHandler(output.count)
                }
            }
            outHandle.waitForDataInBackgroundAndNotify()
        }
    }

    func handleRsync3Data(_ pipe: Pipe) async {
        let outHandle = pipe.fileHandleForReading
        let data = outHandle.availableData
        if data.count > 0 {
            if let str = NSString(data: data, encoding: String.Encoding.utf8.rawValue) {
                str.enumerateLines { line, _ in
                    self.output.append(line)
                    if self.isRealtimeOutputEnabled {
                        if let printLine = self.handlers.printLine {
                            printLine(line)
                        }
                    }
                    // isRealRun == true if arguments do not contain --dry-run parameter
                    if self.isRealRun, self.hasSeenSummaryStart == false {
                        if line.contains(RsyncProcess.summaryStartMarker) {
                            self.hasSeenSummaryStart = true
                        }
                    }
                    if self.handlers.checkForErrorInRsyncOutput,
                       self.errorDiscovered == false {
                        do {
                            try self.handlers.checkLineForError(line)
                        } catch let e {
                            self.errorDiscovered = true
                            let error = e
                            self.handlers.propagateError(error)
                        }
                    }
                }
                // Send message about files, do not report the last lines of status from rsync if
                // the real run is ongoing
                if useFileHandler, hasSeenSummaryStart == false, isRealRun == true {
                    handlers.fileHandler(output.count)
                }
            }
            outHandle.waitForDataInBackgroundAndNotify()
        }
    }

    func termination() async {
        Logger.process.debugmessageonly("RsyncProcess: process = nil and termination discovered")
        handlers.processTermination(output, hiddenID)
        // Log error in rsync output to file
        if errorDiscovered {
            Task {
                await handlers.logger(String(hiddenID), output)
            }
        }
        // Set current process to nil
        handlers.updateProcess(nil)
        // Cancel Tasks
        sequenceFileHandlerTask?.cancel()
        sequenceTerminationTask?.cancel()
        sequenceFileHandlerTask = nil
        sequenceTerminationTask = nil
    }
}
