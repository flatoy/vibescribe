import Foundation

@MainActor
final class TestHarness {
    private var failures: [String] = []
    private var current: String = ""
    private var ranTests = 0

    func run(_ name: String, _ body: () throws -> Void) {
        current = name
        ranTests += 1
        do {
            try body()
            print("  ok  \(name)")
        } catch {
            failures.append("\(name): \(error)")
            print("  FAIL \(name): \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expectation failed", file: String = #file, line: Int = #line) {
        if !condition {
            let fileName = (file as NSString).lastPathComponent
            failures.append("\(current) [\(fileName):\(line)] \(message())")
            print("  FAIL \(current) [\(fileName):\(line)]: \(message())")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
        if actual != expected {
            let fileName = (file as NSString).lastPathComponent
            failures.append("\(current) [\(fileName):\(line)] expected \(expected) got \(actual)")
            print("  FAIL \(current) [\(fileName):\(line)]: expected \(expected) got \(actual)")
        }
    }

    func expectNil<T>(_ value: T?, file: String = #file, line: Int = #line) {
        if value != nil {
            let fileName = (file as NSString).lastPathComponent
            failures.append("\(current) [\(fileName):\(line)] expected nil got \(String(describing: value!))")
            print("  FAIL \(current) [\(fileName):\(line)]: expected nil got \(String(describing: value!))")
        }
    }

    func require<T>(_ value: T?, _ message: @autoclosure () -> String = "expected non-nil", file: String = #file, line: Int = #line) throws -> T {
        if let value {
            return value
        }
        let fileName = (file as NSString).lastPathComponent
        let msg = "\(current) [\(fileName):\(line)] \(message())"
        failures.append(msg)
        throw TestFailure(message: msg)
    }

    func summarize() -> Bool {
        let passed = ranTests - failures.count
        print("")
        print("\(passed)/\(ranTests) passed")
        if failures.isEmpty {
            return true
        }
        print("")
        print("Failures:")
        for failure in failures {
            print("  - \(failure)")
        }
        return false
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
