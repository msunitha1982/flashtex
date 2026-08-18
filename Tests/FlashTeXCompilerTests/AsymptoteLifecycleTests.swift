import XCTest
@testable import FlashTeX

final class AsymptoteLifecycleTests: XCTestCase {

    func testActiveProcessTrackingAndTermination() {
        let compiler = Compiler()
        XCTAssertEqual(compiler.activeProcessCount, 0)

        let proc1 = Process()
        proc1.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc1.arguments = ["10"]

        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc2.arguments = ["10"]

        try? proc1.run()
        try? proc2.run()

        compiler.registerProcess(proc1)
        compiler.registerProcess(proc2)
        XCTAssertEqual(compiler.activeProcessCount, 2)

        compiler.terminateActiveProcesses()
        XCTAssertEqual(compiler.activeProcessCount, 0)

        // Give kernel a brief moment to update termination status
        let deadline = Date().addingTimeInterval(1.0)
        while (proc1.isRunning || proc2.isRunning) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertFalse(proc1.isRunning)
        XCTAssertFalse(proc2.isRunning)
    }

    func testStopCompilingBumpsGenerationAndTerminatesProcesses() {
        let compiler = Compiler()
        let initialGen = compiler.currentGeneration

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["10"]
        try? proc.run()
        compiler.registerProcess(proc)

        compiler.stopCompiling()

        XCTAssertGreaterThan(compiler.currentGeneration, initialGen)
        XCTAssertEqual(compiler.activeProcessCount, 0)

        let deadline = Date().addingTimeInterval(1.0)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        XCTAssertFalse(proc.isRunning)
    }

    func testShutdownCleansUpState() {
        let compiler = Compiler()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["10"]
        try? proc.run()
        compiler.registerProcess(proc)

        compiler.shutdown()

        XCTAssertEqual(compiler.activeProcessCount, 0)
        XCTAssertFalse(proc.isRunning)
    }
}
