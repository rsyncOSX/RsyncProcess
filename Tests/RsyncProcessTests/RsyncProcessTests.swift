@testable import RsyncProcess
import Testing
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

// The TestState actor manages its own state and does not need a global actor.
actor TestState {
    var capturedError: Error?
    var capturedOutput: [String]?
    var fileHandlerCount = 0

    private var terminationContinuation: CheckedContinuation<Void, Never>?
    private var errorContinuation: CheckedContinuation<Void, Never>?

    func expectTermination() async {
        await withCheckedContinuation { continuation in
            terminationContinuation = continuation
        }
    }

    func expectError() async {
        await withCheckedContinuation { continuation in
            errorContinuation = continuation
        }
    }

    func processTerminated(output: [String]?) {
        capturedOutput = output
        terminationContinuation?.resume()
    }

    func errorPropagated(error: Error) {
        capturedError = error
        errorContinuation?.resume()
    }
    
    func fileHandled(count: Int) {
        self.fileHandlerCount = count
    }
}

// The test functions are marked with @MainActor because they interact
// with ProcessRsync, which is a @MainActor class.
@MainActor
struct RsyncProcessTests {
    @Test("Successful execution should complete and capture output")
    func successfulExecution() async throws {
        let state = TestState()
        
        let handlers = ProcessHandlers(
            processtermination: { output, _ in Task { await state.processTerminated(output: output) } },
            filehandler: { count in Task { await state.fileHandled(count: count) } },
            rsyncpath: { "/bin/echo" },
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { error in Task { await state.errorPropagated(error: error) } },
            logger: <#(String, [String]) async -> Void#>,
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true
        )
        
        // Pass arguments during initialization and call executeProcess() without arguments
        let process = ProcessRsync(arguments: ["Hello, rsync!"], handlers: handlers, filehandler: false)
        
        async let termination: () = await state.expectTermination()
        
        try process.executeProcess()
        
        await termination
        
        let capturedOutput = await state.capturedOutput
        let capturedError = await state.capturedError

        #expect(capturedError == nil, "No error should be propagated on successful execution")
        // The output from `echo` will include a newline, which can result in an empty string
        #expect(capturedOutput?.contains("Hello, rsync!") == true)
    }

    @Test("Execution should fail when rsync executable is not found")
    func executableNotFound() async throws {
        let state = TestState()
        
        let handlers = ProcessHandlers(
            processtermination: { output, _ in Task { await state.processTerminated(output: output) } },
            filehandler: { count in Task { await state.fileHandled(count: count) } },
            rsyncpath: { nil }, // Simulate executable not found
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { error in Task { await state.errorPropagated(error: error) } },
            logger: { command, output in
                _  = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true
        )
        
        let process = ProcessRsync(arguments: [], handlers: handlers, filehandler: false)
        
        // The error is thrown synchronously by executeProcess()
        // so we catch it directly.
        do {
            try process.executeProcess()
            Issue.record("Expected an error to be thrown, but it was not.")
        } catch {
            #expect(error is RsyncError)
            if let rsyncError = error as? RsyncError {
                #expect(rsyncError.localizedDescription == RsyncError.executableNotFound.localizedDescription)
            }
        }
    }

    @Test("Execution should fail for an invalid executable path")
    func invalidExecutablePath() async throws {
        let state = TestState()
        let invalidPath = "/invalid/path/to/rsync"

        let handlers = ProcessHandlers(
            processtermination: { output, _ in Task { await state.processTerminated(output: output) } },
            filehandler: { _ in },
            rsyncpath: { invalidPath },
            checklineforerror: { _ in },
            updateprocess: { _ in },
            propogateerror: { error in Task { await state.errorPropagated(error: error) } },
            logger: { command, output in
                _  = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true
        )

        let process = ProcessRsync(arguments: [], handlers: handlers, filehandler: false)

        do {
            try process.executeProcess()
            Issue.record("Expected an error to be thrown, but it was not.")
        } catch {
            #expect(error is RsyncError)
            if let rsyncError = error as? RsyncError {
                 #expect(rsyncError.localizedDescription == RsyncError.invalidExecutablePath(invalidPath).localizedDescription)
            }
        }
    }

    @Test("An error in the output should be propagated")
    func errorInOutput() async throws {
        let state = TestState()
        
        let handlers = ProcessHandlers(
            processtermination: { output, _ in Task { await state.processTerminated(output: output) } },
            filehandler: { _ in },
            rsyncpath: { "/bin/echo" },
            checklineforerror: { line in
                if line.contains("error") {
                    throw RsyncError.outputEncodingFailed
                }
            },
            updateprocess: { _ in },
            propogateerror: { error in Task { await state.errorPropagated(error: error) } },
            logger: { command, output in
                _  = await ActorToFile(command, output)
            },
            checkforerrorinrsyncoutput: true,
            rsyncversion3: true
        )
        
        let process = ProcessRsync(arguments: ["An error occurred"], handlers: handlers, filehandler: false)

        async let termination: () = await state.expectTermination()
        async let errorExpectation: () = await state.expectError()

        try process.executeProcess()

        // Wait for both the process to terminate and the error to be handled
        await (termination, errorExpectation)
        
        let capturedError = await state.capturedError
        #expect(capturedError is RsyncError)
        
        if let rsyncError = capturedError as? RsyncError {
            #expect(rsyncError.localizedDescription == RsyncError.outputEncodingFailed.localizedDescription)
        }
    }
}
