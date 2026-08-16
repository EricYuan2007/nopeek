import Foundation

// Minimal assertion harness — XCTest is unavailable without full Xcode.
// Test functions live in sibling files and are enumerated in main.swift.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL \(file):\(line) \(message)")
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if lhs != rhs {
        failures += 1
        let prefix = message.isEmpty ? "" : message + " — "
        print("FAIL \(file):\(line) \(prefix)expected \(rhs), got \(lhs)")
    }
}
