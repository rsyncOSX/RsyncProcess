//
//  ProcessHandlers.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//
// swiftlint:disable function_parameter_count
import Foundation

/// Handlers for process execution callbacks
public struct ProcessHandlers {
    /// Called when process terminates with output and hiddenID
    public var processTermination: ([String]?, Int?) -> Void
    /// Called during file processing with count
    public var fileHandler: (Int) -> Void
    /// Returns the path to rsync executable
    public var rsyncPath: () -> String?
    /// Checks a line for errors and throws if found
    public var checkLineForError: (String) throws -> Void
    /// Updates the current process reference
    public var updateProcess: (Process?) -> Void
    /// Propagates errors to error handler
    public var propagateError: (Error) -> Void
    // Async logger
    public var logger: (String, [String]) async -> Void
    /// Flag to enable/disable error checking in rsync output
    public var checkForErrorInRsyncOutput: Bool
    /// Flag for version 3.x of rsync or not
    public var rsyncVersion3: Bool = false
    /// Environment data for rsync
    public var environment: [String: String]?
    /// Print lines in data handler
    public var printLine: ((String) -> Void)?
    /// Initialize ProcessHandlers with all required closures
    public init(
        processTermination: @escaping ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: @escaping () -> String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void,
        checkForErrorInRsyncOutput: Bool,
        rsyncVersion3: Bool,
        environment: [String: String]?,
        printLine: ((String) -> Void)? = nil
    ) {
        self.processTermination = processTermination
        self.fileHandler = fileHandler
        self.rsyncPath = rsyncPath
        self.checkLineForError = checkLineForError
        self.updateProcess = updateProcess
        self.propagateError = propagateError
        self.logger = logger
        self.checkForErrorInRsyncOutput = checkForErrorInRsyncOutput
        self.rsyncVersion3 = rsyncVersion3
        self.environment = environment
        self.printLine = printLine
    }
}

public extension ProcessHandlers {
    /// Create ProcessHandlers with automatic output capture enabled
    static func withOutputCapture(
        processTermination: @escaping ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: @escaping () -> String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void,
        checkForErrorInRsyncOutput: Bool,
        rsyncVersion3: Bool,
        environment: [String: String]?
    ) -> ProcessHandlers {
        ProcessHandlers(
            processTermination: processTermination,
            fileHandler: fileHandler,
            rsyncPath: rsyncPath,
            checkLineForError: checkLineForError,
            updateProcess: updateProcess,
            propagateError: propagateError,
            logger: logger,
            checkForErrorInRsyncOutput: checkForErrorInRsyncOutput,
            rsyncVersion3: rsyncVersion3,
            environment: environment,
            printLine: RsyncOutputCapture.shared.makePrintLinesClosure()
        )
    }
}
// swiftlint:enable function_parameter_count
