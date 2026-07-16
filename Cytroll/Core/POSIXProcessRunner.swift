import Foundation
import Darwin

/// iOS-safe process launcher.
///
/// `Foundation.Process` / `NSTask` exist only on macOS. TrollStore apps
/// that need to spawn helpers (`cytrollhelper`, `dpkg`, `ldid`, …) use
/// `posix_spawn` + pipes instead — same approach as Filza / TrollFools /
/// other unsandboxed tooling.
enum POSIXProcessRunner {
    struct Result {
        let exitStatus: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Spawns `executable` with `arguments` and `environment`, waits for
    /// exit, and returns captured stdout/stderr. Throws only when the
    /// spawn itself fails (missing binary, permission denied, …).
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> Result {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else {
            throw POSIXProcessError.pipeFailed(errno)
        }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw POSIXProcessError.pipeFailed(errno)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

        // argv[0] is the executable path; remaining slots are user args; nil-terminated.
        var argvPointers: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        defer { for ptr in argvPointers where ptr != nil { free(ptr) } }

        var envPointers: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for ptr in envPointers where ptr != nil { free(ptr) } }

        var pid: pid_t = 0
        let spawnStatus = argvPointers.withUnsafeMutableBufferPointer { argvBuf in
            envPointers.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(
                    &pid,
                    executable,
                    &fileActions,
                    nil,
                    argvBuf.baseAddress,
                    envBuf.baseAddress
                )
            }
        }

        // Parent no longer needs write ends.
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnStatus == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw POSIXProcessError.spawnFailed(spawnStatus)
        }

        let stdoutData = readAll(from: stdoutPipe[0])
        let stderrData = readAll(from: stderrPipe[0])
        close(stdoutPipe[0])
        close(stderrPipe[0])

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1 {
            if errno != EINTR { break }
        }

        // Decode waitpid status without relying on WIFEXITED/WEXITSTATUS
        // macros (not always exposed cleanly to Swift).
        let exitCode: Int32
        if (waitStatus & 0x7f) == 0 {
            exitCode = (waitStatus >> 8) & 0xff
        } else if (((waitStatus & 0x7f) + 1) >> 1) > 0 {
            exitCode = 128 + (waitStatus & 0x7f)
        } else {
            exitCode = -1
        }

        return Result(exitStatus: exitCode, stdout: stdoutData, stderr: stderrData)
    }

    private static func readAll(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(buffer, count: n)
            } else {
                break
            }
        }
        return data
    }
}

enum POSIXProcessError: Error, LocalizedError {
    case pipeFailed(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .pipeFailed(let code):
            return "pipe() failed: \(String(cString: strerror(code)))"
        case .spawnFailed(let code):
            return "posix_spawn failed: \(String(cString: strerror(code)))"
        }
    }
}
