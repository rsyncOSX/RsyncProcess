//
//  ProcessHandlers.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation

/// Handlers for process execution callbacks
public struct ProcessHandlers {
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
    // Async logger
    public var logger: (String, [String]) async -> Void
    /// Flag to enable/disable error checking in rsync output
    public var checkforerrorinrsyncoutput: Bool
    /// Flag for version 3.x of rsync or not
    public var rsyncversion3: Bool = false
    /// Environment data for rsync
    public var environment: [String: String]?
    /// Print lines i datahandler
    public var printlines: ((String) -> Void)?
    /// Initialize ProcessHandlers with all required closures
    public init(
        processtermination: @escaping ([String]?, Int?) -> Void,
        filehandler: @escaping (Int) -> Void,
        rsyncpath: @escaping () -> String?,
        checklineforerror: @escaping (String) throws -> Void,
        updateprocess: @escaping (Process?) -> Void,
        propogateerror: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void,
        checkforerrorinrsyncoutput: Bool,
        rsyncversion3: Bool,
        environment: [String: String]?,
        printlines: ((String) -> Void)? = nil
    ) {
        self.processtermination = processtermination
        self.filehandler = filehandler
        self.rsyncpath = rsyncpath
        self.checklineforerror = checklineforerror
        self.updateprocess = updateprocess
        self.propogateerror = propogateerror
        self.logger = logger
        self.checkforerrorinrsyncoutput = checkforerrorinrsyncoutput
        self.rsyncversion3 = rsyncversion3
        self.environment = environment
        self.printlines = printlines
    }
}

extension ProcessHandlers {
    /// Create ProcessHandlers with automatic output capture enabled
    public static func withOutputCapture(
        processtermination: @escaping ([String]?, Int?) -> Void,
        filehandler: @escaping (Int) -> Void,
        rsyncpath: @escaping () -> String?,
        checklineforerror: @escaping (String) throws -> Void,
        updateprocess: @escaping (Process?) -> Void,
        propogateerror: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void,
        checkforerrorinrsyncoutput: Bool,
        rsyncversion3: Bool,
        environment: [String: String]?
    ) -> ProcessHandlers {
        return ProcessHandlers(
            processtermination: processtermination,
            filehandler: filehandler,
            rsyncpath: rsyncpath,
            checklineforerror: checklineforerror,
            updateprocess: updateprocess,
            propogateerror: propogateerror,
            logger: logger,
            checkforerrorinrsyncoutput: checkforerrorinrsyncoutput,
            rsyncversion3: rsyncversion3,
            environment: environment,
            printlines: RsyncOutputCapture.shared.makePrintLinesClosure()
        )
    }
}
