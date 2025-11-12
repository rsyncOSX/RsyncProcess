//
//  PrintLinesTest.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Testing
import Foundation
@testable import RsyncProcess

@Suite("PrintLines Tests", .serialized)
struct PrintLinesTests {
    @Test("PrintLines receives lines via closure")
    func testPrintLinesObservable() async {
        let capture = RsyncOutputCapture.shared

        // Ensure a clean state
        await capture.disable()
        await capture.clear()
        await MainActor.run {
            PrintLines.shared.clear()
        }

        // Enable capture
        await capture.enable()

        // Get the nonisolated closure and call it synchronously as ProcessHandlers would
        let printLines = capture.makePrintLinesClosure()
        printLines("Test line A")
        printLines("Test line B")

        // Give async tasks time to complete
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        // Read observable output on MainActor
        let lines = await MainActor.run { PrintLines.shared.output }

        #expect(lines.count == 2)
        #expect(lines.contains("Test line A"))
        #expect(lines.contains("Test line B"))

        // Cleanup
        await capture.disable()
        await capture.clear()
        await MainActor.run { PrintLines.shared.clear() }
    }
}
