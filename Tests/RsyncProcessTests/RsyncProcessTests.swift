import Testing
@testable import RsyncProcess

@Test func example() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
}

/*
 import RsyncProcess

 let handlers = ProcessHandlers(
     processtermination: { output, id in
         print("Process terminated with ID: \(id ?? -1)")
     },
     filehandler: { count in
         print("Files processed: \(count)")
     },
     rsyncpath: { "/usr/bin/rsync" },
     checklineforerror: { line in
         if line.contains("error") { throw NSError(domain: "rsync", code: 1) }
     },
     updateprocess: { process in
         // Store process reference
     },
     propogateerror: { error in
         print("Error: \(error)")
     },
     checkforerrorinrsyncoutput: true
 )

 let rsyncProcess = ProcessRsyncVer3x(
     arguments: ["--version"],
     handlers: handlers,
     filhandler: false
 )

 */
