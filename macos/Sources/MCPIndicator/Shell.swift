import Foundation

struct ShellResult: Sendable {
    let ok: Bool
    let output: String
}

enum Shell {
    /// Corre um comando e devolve stdout+stderr juntos (saídas curtas: launchctl, kill).
    static func run(_ argv: [String]) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: argv[0])
                process.arguments = Array(argv.dropFirst())
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ShellResult(ok: false, output: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: ShellResult(
                    ok: process.terminationStatus == 0,
                    output: String(decoding: data, as: UTF8.self)
                ))
            }
        }
    }

    static func delay(ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }
}

extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }

    func firstMatch(_ pattern: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: self) else { return nil }
        return String(self[r])
    }
}
