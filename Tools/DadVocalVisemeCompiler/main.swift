import Foundation

private enum DriverError: Error, CustomStringConvertible {
    case missingArgument(String)

    var description: String {
        switch self {
        case .missingArgument(let name):
            return "DadVocalVisemeCompiler is missing required argument \(name)"
        }
    }
}

private func value(after flag: String, in arguments: inout [String]) throws -> String {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        throw DriverError.missingArgument(flag)
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let repositoryRoot = try value(after: "--repository-root", in: &arguments)
    let python = try value(after: "--python", in: &arguments)
    let driver = try value(after: "--driver", in: &arguments)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [driver] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    environment["KMP_DUPLICATE_LIB_OK"] = "TRUE"
    environment["OMP_NUM_THREADS"] = "1"
    process.environment = environment
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}

