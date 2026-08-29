//
//  PipelineRunner.swift
//  Meetinsight
//
//  子进程运行器：以 NSTask/Process 调用 pipeline.py（见 Swift_Python_Interface_Contract.md §4/§5）。
//  - 通过 AppConfig.pipelineEnvironment() 注入全部环境契约变量（含 Keychain 中的 API Key）。
//  - stdout：业务结果（尝试解析末尾 JSON 对象）。
//  - stderr：JSON-Lines 进度流（契约 §5），逐行解析后回调到主线程驱动原生进度条。
//

import Foundation

/// pipeline.py 单次运行的结果。
struct PipelineResult {
    let exitCode: Int32
    let stdout: String
    let finalJSON: [String: Any]?   // 解析 stdout 得到的业务 JSON（若有）
    let error: Error?
}

/// 解析 stderr JSON-Lines 得到的单条进度。
struct PipelineProgress {
    let level: String            // "info" / "warn" / "error"
    let message: String
    let step: String?           // 阶段标识（契约 §5 的 step 字段）
    let progress: Double?       // 0...1；缺失则为 nil（仅日志）
}

/// 子进程运行器（非隔离，UI 回调统一派发到主线程）。
final class PipelineRunner {

    static let shared = PipelineRunner()

    private var currentProcess: Process?
    private let outQueue = DispatchQueue(label: "pipeline.stdout")
    private let errQueue = DispatchQueue(label: "pipeline.stderr")
    // stderr 行缓冲（JSON-Lines 切分用，类属性以便 terminationHandler 收尾）
    private var stderrBuffer = ""
    // stderr 原始文本（出错时带回给用户看真正的 Python 报错）
    private var stderrRawText = ""

    /// 运行 Python 脚本（默认 pipeline.py，Wiki 功能可传入 wiki_build.py / wiki_query.py 等）。
    /// - Parameters:
    ///   - script: 要执行的 Python 脚本路径；传 `nil`（默认）则跑 `AppConfig.pipelineScript`（pipeline.py）。
    ///   - arguments: 附加 CLI 参数，默认 `["--json-log"]`；可追加子命令如 `["--list-wiki-pages"]`。
    ///   - progress: 进度回调（已派发到主线程）。
    ///   - completion: 完成回调（已派发到主线程）。
    func run(
        script: URL? = nil,
        arguments: [String] = ["--json-log"],
        progress: @escaping (PipelineProgress) -> Void,
        completion: @escaping (PipelineResult) -> Void
    ) {
        let cfg = AppConfig.shared
        let target = script ?? cfg.pipelineScript
        let process = Process()
        process.executableURL = cfg.pythonExecutable
        process.arguments = [target.path] + arguments
        process.environment = cfg.pipelineEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var stdoutData = Data()
        stderrBuffer = ""
        stderrRawText = ""

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.errQueue.async {
                // 收集原始 stderr（出错时供用户看真正的 Python 报错）
                self.stderrRawText += text
                // 按行切分，保留未完成的半行到 stderrBuffer
                let combined = self.stderrBuffer + text
                var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                self.stderrBuffer = lines.popLast() ?? ""
                for raw in lines {
                    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !s.isEmpty, let d = s.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                    let level = obj["level"] as? String ?? "info"
                    let msg = obj["msg"] as? String ?? ""
                    let step = obj["step"] as? String
                    let prog = (obj["progress"] as? NSNumber).map { $0.doubleValue }
                    DispatchQueue.main.async {
                        progress(PipelineProgress(level: level, message: msg, step: step, progress: prog))
                    }
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.outQueue.async { stdoutData.append(data) }
        }

        process.terminationHandler = { proc in
            // 终止后立即关闭读 handler，避免继续触发空包回调
            errPipe.fileHandleForReading.readabilityHandler = nil
            outPipe.fileHandleForReading.readabilityHandler = nil

            // 确保 stdout/stderr 全部读取完毕
            self.outQueue.sync {}
            self.errQueue.sync {}

            let outText = String(data: stdoutData, encoding: .utf8) ?? ""
            let capturedStderr = self.stderrRawText
            let json = Self.parseTrailingJSON(outText)
            DispatchQueue.main.async {
                let ok = proc.terminationStatus == 0
                let error: NSError? = ok ? nil : NSError(
                    domain: "PipelineRunner",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey:
                        "pipeline.py 异常退出，退出码 \(proc.terminationStatus)" +
                        (capturedStderr.isEmpty ? "" : "\n\n— stderr —\n\(capturedStderr)")]
                )
                completion(PipelineResult(
                    exitCode: proc.terminationStatus,
                    stdout: outText,
                    finalJSON: json,
                    error: error
                ))
            }
        }

        currentProcess = process
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(PipelineResult(exitCode: -1, stdout: "", finalJSON: nil, error: error))
            }
        }
    }

    /// 取消当前运行（若正在运行）。
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }

    // MARK: - 解析 stdout 末尾 JSON（业务结果）

    private static func parseTrailingJSON(_ text: String) -> [String: Any]? {
        guard !text.isEmpty else { return nil }
        for line in text.components(separatedBy: .newlines).reversed() {
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let d = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            return obj
        }
        return nil
    }
}
