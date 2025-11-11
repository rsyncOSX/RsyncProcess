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
        
        func printline(_ line: String) {
            print(line)
        }
    }
    
    // MARK: - Helper Methods
    
    func createMockHandlers(
        // rsyncPath: String? = "/usr/bin/rsync",
        rsyncPath: String? = "/opt/homebrew/bin/rsync",
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
    // START
    
    @Test("Full process lifecycle with rsync")
        func fullProcessLifecycle() async throws {
            let state = TestState()
            let handlers = createMockHandlers(state: state)
            let process = RsyncProcess(
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
        
        @Test("Process termination with pending output data")
        func processTerminationWithPendingData() async throws {
            let state = TestState()
            var handlers = createMockHandlers(state: state)
            handlers.printlines = state.printline(_:)
            let hiddenID = 1
            
            let process = RsyncProcess(
                arguments: ["--version"],
                hiddenID: hiddenID,
                handlers: handlers,
                usefilehandler: false
            )
            
            // Execute the process which will generate real output
            try process.executeProcess()
            
            // Give process time to generate output and complete
            try await Task.sleep(nanoseconds: 2_000_000_000)
            
            // Verify that output was captured during execution
            #expect(process.output.count > 0)
            
            // Verify the termination handler was called with the output data
            #expect(state.mockOutput != nil)
            #expect(state.mockOutput?.count ?? 0 > 0)
            
            // Verify the hidden ID was passed correctly
            #expect(state.mockHiddenID == hiddenID)
            
            // Verify output contains version information (proves data was present at termination)
            let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
            #expect(outputString.contains("rsync") || outputString.contains("version"))
        }
        
        @Test("Process termination called before all data is handled")
        func processTerminationBeforeAllDataHandled() async throws {
            let state = TestState()
            let hiddenID = 1
            var dataHandledCount = 0
            var terminationOutputCount = 0
            
            // Create handlers that track data handling vs termination
            let handlers = ProcessHandlers(
                processtermination: { output, id in
                    state.mockOutput = output
                    state.mockHiddenID = id
                    terminationOutputCount = output?.count ?? 0
                    PackageLogger.process.info("Termination called with \(terminationOutputCount) lines")
                },
                filehandler: { count in
                    dataHandledCount = count
                    state.fileHandlerCount = count
                },
                rsyncpath: { "/usr/bin/rsync" },
                checklineforerror: { _ in },
                updateprocess: { process in
                    state.processUpdateCalled = true
                },
                propogateerror: { error in
                    state.errorPropagated = error
                },
                logger: { command, output in
                    _ = await ActorToFile(command, output)
                },
                checkforerrorinrsyncoutput: false,
                rsyncversion3: false,
                environment: nil
            )
            
            // Use a command that generates significant output quickly
            // This increases the chance of termination happening while data is still in the pipe
            let process = RsyncProcess(
                arguments: ["--help"],  // Generates multi-line output
                hiddenID: hiddenID,
                handlers: handlers,
                usefilehandler: true
            )
            
            try process.executeProcess()
            
            // Wait for process to complete - the 50ms drain period is built into the process
            try await Task.sleep(nanoseconds: 3_000_000_000)
            
            // Verify termination was called
            #expect(state.mockOutput != nil)
            #expect(state.mockHiddenID == hiddenID)
            
            // The key test: termination should have output data
            // This proves the drain mechanism captured data that was still in the pipe
            #expect(terminationOutputCount > 0)
            
            // Verify the process captured help output (proving drain worked)
            let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
            #expect(outputString.contains("rsync") || outputString.contains("usage") || outputString.contains("options"))
            
            PackageLogger.process.info("Test complete - Data handled during execution: \(dataHandledCount), Data at termination: \(terminationOutputCount)")
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
