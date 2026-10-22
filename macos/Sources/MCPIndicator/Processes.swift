import Darwin
import Foundation

/// Equivalente macOS de /proc: sysctl(KERN_PROC_UID) + KERN_PROCARGS2.
struct ProcInfo: Sendable {
    let pid: Int32
    let argv: [String]
    let comm: String

    var cmdline: String { argv.joined(separator: " ") }
}

enum ProcessTable {
    private static let argMax: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 256 * 1024 }
        return Int(value)
    }()

    static func listUserProcesses() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Margem para processos que nasçam entre as duas chamadas.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let me = getpid()
        var out: [ProcInfo] = []
        for kp in procs.prefix(size / stride) {
            let pid = kp.kp_proc.p_pid
            if pid <= 1 || pid == me { continue }
            guard let argv = arguments(of: pid), !argv.isEmpty else { continue }
            out.append(ProcInfo(pid: pid, argv: argv, comm: name(of: pid) ?? shortComm(kp)))
        }
        return out
    }

    /// Nome do processo até 32 caracteres (o p_comm do kinfo_proc corta em 16).
    static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func shortComm(_ kp: kinfo_proc) -> String {
        withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// argv de um PID (layout KERN_PROCARGS2: argc, exec_path, NULs, argv[0..argc]).
    static func arguments(of pid: Int32) -> [String]? {
        guard pid > 1 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }

        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            let arg = String(decoding: buffer[start..<i], as: UTF8.self)
            i += 1
            // Node/Electron reescrevem o argv com `process.title` e preenchem com espaços ou NULs.
            // O que vem depois seriam variáveis de ambiente: pára aqui, como o ps.
            if arg.isEmpty { break }
            if arg.hasSuffix("  ") {
                let title = arg.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { args.append(title) }
                break
            }
            args.append(arg)
        }
        return args.isEmpty ? nil : args
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func signal(_ pids: [Int32], _ sig: Int32) {
        for pid in pids where pid > 1 {
            // Só PIDs já associados àquele MCP.
            if kill(pid, sig) != 0 {
                NSLog("[MCP Indicator] kill -%d %d: errno %d", sig, pid, errno)
            }
        }
    }
}
