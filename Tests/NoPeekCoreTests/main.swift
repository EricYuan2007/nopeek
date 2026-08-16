import Foundation

// M0 smoke test — real NoPeekCore tests (state machine, intruder assessment) land in M3.
func testCorePlaceholder() {
    expectEqual(NoPeekCore.version, "0.1.0")
}

let suites: [(String, () -> Void)] = [
    ("core placeholder", testCorePlaceholder),
]

for (name, body) in suites {
    body()
    print("· \(name)")
}
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
