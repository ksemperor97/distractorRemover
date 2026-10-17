import Foundation

/// Minimal test harness: Command Line Tools ship neither XCTest nor the
/// swift-testing macro plugin, so checks run as a plain executable.
enum Harness {
    static var failures = 0
    static var checks = 0
    static var currentTest = ""

    static func record(_ ok: Bool, _ message: @autoclosure () -> String, file: StaticString, line: UInt) {
        checks += 1
        if !ok {
            failures += 1
            print("  ✗ \(currentTest): \(message()) (\(file):\(line))")
        }
    }
}

func check(_ condition: Bool, _ message: @autoclosure () -> String = "condition failed",
           file: StaticString = #fileID, line: UInt = #line) {
    Harness.record(condition, message(), file: file, line: line)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ note: String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    Harness.record(actual == expected, "expected \(expected), got \(actual) \(note)", file: file, line: line)
}

func test(_ name: String, _ body: () throws -> Void) {
    Harness.currentTest = name
    let before = Harness.failures
    do { try body() } catch { Harness.record(false, "threw \(error)", file: #fileID, line: #line) }
    print("\(Harness.failures == before ? "✓" : "✗") \(name)")
}

@MainActor
func testAsync(_ name: String, _ body: @MainActor () async throws -> Void) async {
    Harness.currentTest = name
    let before = Harness.failures
    do { try await body() } catch { Harness.record(false, "threw \(error)", file: #fileID, line: #line) }
    print("\(Harness.failures == before ? "✓" : "✗") \(name)")
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("distractorRemover-checks-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
}

/// Repository root, derived from this file's location.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
