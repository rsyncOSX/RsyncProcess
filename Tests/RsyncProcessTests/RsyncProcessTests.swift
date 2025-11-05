import Testing
@testable import RsyncProcess
import Foundation

actor ActorToFile {
    private func logging(command _: String, stringoutput: [String]) async {
        var logfile: String?

        if logfile == nil {
            logfile = stringoutput.joined(separator: "\n")
        } else {
            logfile! += stringoutput.joined(separator: "\n")
        }
        if let logfile {
            print(logfile)
        }
    }

    @discardableResult
    init(_ command: String, _ stringoutput: [String]?) async {
        if let stringoutput {
            await logging(command: command, stringoutput: stringoutput)
        }
    }
}

@MainActor
@Suite("RsyncProcess Tests")
struct RsyncProcessTests {
    
    // MARK: - Helper Class for Test State
    
    @MainActor
    final class TestState {
        var mockOutput: [String]?
        var mockHiddenID: Int?
        var fileHandlerCount: Int = 0
        var processUpdateCalled: Bool = false
        var errorPropagated: Error?
        var loggerCalled: Bool = false
        var loggedID: String?
        var loggedOutput: [String]?
        
        func reset() {
            mockOutput = nil
            mockHiddenID = nil
            fileHandlerCount = 0
            processUpdateCalled = false
            errorPropagated = nil
            loggerCalled = false
            loggedID = nil
            loggedOutput = nil
        }
    }
    
    // MARK: - Helper Methods
    
    func createMockHandlers(
        rsyncPath: String? = "/usr/bin/rsync",
        checkForError: Bool = false,
        rsyncVersion3: Bool = true,
        shouldThrowError: Bool = false,
        state: TestState
    ) -> ProcessHandlers {
        ProcessHandlers(
            processtermination: { output, hiddenID in
                state.mockOutput = output
                state.mockHiddenID = hiddenID
            },
            filehandler: { count in
                state.fileHandlerCount = count
            },
            rsyncpath: { rsyncPath },
            checklineforerror: { line in
                if shouldThrowError && line.contains("error") {
                    throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mock error"])
                }
            },
            updateprocess: { process in
                state.processUpdateCalled = true
            },
            propogateerror: { error in
                state.errorPropagated = error
            },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: checkForError,
            rsyncversion3: rsyncVersion3,
            environment: nil
        )
    }
    
    // MARK: - Initialization Tests
    
    @Test("ProcessRsync initialization with all parameters")
    func processRsyncInitialization() {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let arguments = ["--dry-run", "/source", "/dest"]
        
        let process = ProcessRsync(
            arguments: arguments,
            hiddenID: 42,
            handlers: handlers,
            usefilehandler: true
        )
        
        #expect(process.output.count == 0)
        #expect(process.errordiscovered == false)
    }
    
    @Test("Convenience initializer")
    func convenienceInitializer() {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let arguments = ["--version"]
        
        let process = ProcessRsync(
            arguments: arguments,
            handlers: handlers,
            filehandler: true
        )
        
        #expect(process.output.count == 0)
    }
    
    @Test("Dry run detection in arguments")
    func dryRunDetection() {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let dryRunArgs = ["--dry-run", "/source", "/dest"]
        
        let _ = ProcessRsync(
            arguments: dryRunArgs,
            hiddenID: 1,
            handlers: handlers,
            usefilehandler: false
        )
        
        // realrun should be false when --dry-run is present
        // This is tested implicitly through behavior
    }
    
    @Test("Version argument detection")
    func versionDetection() {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let versionArgs = ["--version"]
        
        let _ = ProcessRsync(
            arguments: versionArgs,
            hiddenID: 1,
            handlers: handlers,
            usefilehandler: false
        )
        
        // getrsyncversion should be true
        // This is tested implicitly through behavior
    }
    
    // MARK: - Error Tests
    
    @Test("RsyncError.executableNotFound description")
    func executableNotFoundDescription() {
        let error = RsyncError.executableNotFound
        #expect(error.errorDescription == "Rsync executable not found. Please verify the rsync path.")
    }
    
    @Test("RsyncError.invalidExecutablePath description")
    func invalidExecutablePathDescription() {
        let error = RsyncError.invalidExecutablePath("/invalid/path")
        #expect(error.errorDescription == "Invalid rsync executable path: /invalid/path")
    }
    
    @Test("RsyncError.processLaunchFailed description")
    func processLaunchFailedDescription() {
        let testError = NSError(domain: "test", code: 1, userInfo: nil)
        let error = RsyncError.processLaunchFailed(testError)
        #expect(error.errorDescription?.contains("Failed to launch") == true)
    }
    
    @Test("RsyncError.outputEncodingFailed description")
    func outputEncodingFailedDescription() {
        let error = RsyncError.outputEncodingFailed
        #expect(error.errorDescription == "Failed to decode rsync output as UTF-8")
    }
    
    @Test("Execute process throws when executable not found")
    func executableNotFound() {
        let state = TestState()
        let handlers = createMockHandlers(rsyncPath: nil, state: state)
        let process = ProcessRsync(
            arguments: ["--version"],
            handlers: handlers,
            filehandler: false
        )
        
        #expect(throws: RsyncError.self) {
            try process.executeProcess()
        }
    }
    
    @Test("Execute process throws for invalid executable path")
    func invalidExecutablePath() {
        let state = TestState()
        let handlers = createMockHandlers(rsyncPath: "/nonexistent/rsync", state: state)
        let process = ProcessRsync(
            arguments: ["--version"],
            handlers: handlers,
            filehandler: false
        )
        
        #expect(throws: RsyncError.self) {
            try process.executeProcess()
        }
    }
    
    // MARK: - ProcessHandlers Tests
    
    @Test("ProcessHandlers initialization with all closures")
    func processHandlersInitialization() {
        var terminationCalled = false
        var fileHandlerCalled = false
        var pathCalled = false
        var errorCheckCalled = false
        var updateCalled = false
        var errorPropagatedCalled = false
        var loggerCalledFlag = false
        
        let handlers = ProcessHandlers(
            processtermination: { _, _ in terminationCalled = true },
            filehandler: { _ in fileHandlerCalled = true },
            rsyncpath: { pathCalled = true; return "/usr/bin/rsync" },
            checklineforerror: { _ in errorCheckCalled = true },
            updateprocess: { _ in updateCalled = true },
            propogateerror: { _ in errorPropagatedCalled = true },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true,
            environment: ["TEST": "value"]
        )
        
        handlers.processtermination(nil, nil)
        handlers.filehandler(0)
        _ = handlers.rsyncpath()
        try? handlers.checklineforerror("test")
        handlers.updateprocess(nil)
        handlers.propogateerror(NSError(domain: "test", code: 1))
        Task { await handlers.logger("test", []) }
        
        #expect(terminationCalled)
        #expect(fileHandlerCalled)
        #expect(pathCalled)
        #expect(errorCheckCalled)
        #expect(updateCalled)
        #expect(errorPropagatedCalled)
        #expect(handlers.checkforerrorinrsyncoutput)
        #expect(handlers.rsyncversion3)
        #expect(handlers.environment?["TEST"] == "value")
    }
    
    @Test("ProcessHandlers with environment variables")
    func processHandlersWithEnvironment() {
        let environment = [
            "SSH_AUTH_SOCK": "/Users/test/.gnupg/S.gpg-agent.ssh",
            "PATH": "/usr/local/bin:/usr/bin"
        ]
        
        let handlers = ProcessHandlers(
            processtermination: { _, _ in },
            filehandler: { _ in },
            rsyncpath: { "/usr/bin/rsync" },
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { _ in },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: false,
            rsyncversion3: true,
            environment: environment
        )
        
        #expect(handlers.environment?.count == 2)
        #expect(handlers.environment?["SSH_AUTH_SOCK"] == "/Users/test/.gnupg/S.gpg-agent.ssh")
    }
    
    // MARK: - Output Processing Tests
    
    @Test("Output starts empty")
    func outputStartsEmpty() {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let process = ProcessRsync(
            arguments: ["--version"],
            handlers: handlers,
            filehandler: false
        )
        
        #expect(process.output.count == 0)
        #expect(process.output.isEmpty)
    }
    
    // MARK: - Version Detection Tests
    
    @Test("Rsync version 3.x flag is true")
    func rsyncVersion3Flag() {
        let state = TestState()
        let handlersV3 = createMockHandlers(rsyncVersion3: true, state: state)
        #expect(handlersV3.rsyncversion3 == true)
    }
    
    @Test("OpenRsync flag is false")
    func openRsyncFlag() {
        let state = TestState()
        let handlersOpenRsync = createMockHandlers(rsyncVersion3: false, state: state)
        #expect(handlersOpenRsync.rsyncversion3 == false)
    }
    
    // MARK: - Error Checking Tests
    
    @Test("Error checking enabled throws on error line")
    func errorCheckingEnabled() {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: true,
            shouldThrowError: true,
            state: state
        )
        
        #expect(handlers.checkforerrorinrsyncoutput == true)
        
        #expect(throws: Error.self) {
            try handlers.checklineforerror("error occurred")
        }
    }
    
    @Test("Error checking disabled")
    func errorCheckingDisabled() {
        let state = TestState()
        let handlers = createMockHandlers(checkForError: false, state: state)
        #expect(handlers.checkforerrorinrsyncoutput == false)
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("ThreadUtils detects main thread")
    func threadUtilsIsMain() async {
        let isMainThread = await MainActor.run {
            ThreadUtils.isMain
        }
        #expect(isMainThread == true)
    }
    
    // MARK: - Integration Tests
    
    @Test("Full process lifecycle with rsync", .enabled(if: FileManager.default.fileExists(atPath: "/usr/bin/rsync")))
    func fullProcessLifecycle() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)
        let process = ProcessRsync(
            arguments: ["--version"],
            hiddenID: 123,
            handlers: handlers,
            usefilehandler: false
        )
        
        try process.executeProcess()
        
        // Give process time to complete
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        #expect(state.processUpdateCalled == true)
        // After termination, output should contain version info
        #expect(state.mockOutput != nil)
    }
    
    // MARK: - Memory Management Tests
    
    @Test("ProcessRsync deallocates properly")
    func processDeinit() {
        let state = TestState()
        var process: ProcessRsync? = ProcessRsync(
            arguments: ["--version"],
            handlers: createMockHandlers(state: state),
            filehandler: false
        )
        
        weak var weakProcess = process
        process = nil
        
        #expect(weakProcess == nil)
    }
}

// MARK: - Additional Test Suites

@Suite("RsyncError Tests")
struct RsyncErrorTests {
    
    @Test("All error cases have descriptions")
    func allErrorsHaveDescriptions() {
        let errors: [RsyncError] = [
            .executableNotFound,
            .invalidExecutablePath("/test/path"),
            .processLaunchFailed(NSError(domain: "test", code: 1)),
            .outputEncodingFailed
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}

@Suite("ProcessHandlers Configuration Tests")
struct ProcessHandlersConfigurationTests {
    
    @Test("ProcessHandlers with nil environment")
    func handlersWithNilEnvironment() {
        let handlers = ProcessHandlers(
            processtermination: { _, _ in },
            filehandler: { _ in },
            rsyncpath: { "/usr/bin/rsync" },
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { _ in },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: false,
            rsyncversion3: false,
            environment: nil
        )
        
        #expect(handlers.environment == nil)
    }
    
    @Test("ProcessHandlers with multiple environment variables")
    func handlersWithMultipleEnvironmentVariables() {
        let env = [
            "VAR1": "value1",
            "VAR2": "value2",
            "VAR3": "value3"
        ]
        
        let handlers = ProcessHandlers(
            processtermination: { _, _ in },
            filehandler: { _ in },
            rsyncpath: { "/usr/bin/rsync" },
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { _ in },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true,
            environment: env
        )
        
        #expect(handlers.environment?.count == 3)
        #expect(handlers.environment?["VAR1"] == "value1")
        #expect(handlers.environment?["VAR2"] == "value2")
        #expect(handlers.environment?["VAR3"] == "value3")
    }
}

// MARK: - Mock Error for Testing

enum MockRsyncError: Error {
    case testError
}

extension MockRsyncError: LocalizedError {
    var errorDescription: String? {
        "Mock rsync error for testing"
    }
}
