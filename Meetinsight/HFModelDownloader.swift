import AppKit

/// 用系统自带 curl 命令行从 HuggingFace / hf-mirror.com 下载模型仓库（不依赖 Python）。
/// 特性：
/// - 断点续传：`curl -C -`（中断后重跑，已下载字节自动续传）
/// - 文件级进度：bash 脚本向 stdout 输出结构化消息（@@TOTAL / @@FILE_START / @@FILE_DONE / @@ALL_DONE / @@ERROR）
/// - 字节级进度：解析 `curl -#` 写到 stderr 的进度条（###...XX.X%），合成总进度百分比
/// 两个 pipe（stdout / stderr）分别由 readabilityHandler 消费，回调统一派发到主线程。
final class HFModelDownloader {

    struct Progress {
        let fileIndex: Int       // 当前文件序号（1 起）
        let fileTotal: Int       // 文件总数
        let fileName: String
        let filePercent: Double  // 当前文件内 0–100
        /// 总进度：已完成文件数 + 当前文件字节比例，合成 0–100
        var overallPercent: Double {
            guard fileTotal > 0 else { return 0 }
            return min(100, (Double(max(fileIndex - 1, 0)) + filePercent / 100.0) / Double(fileTotal) * 100.0)
        }
    }

    // MARK: - bash 下载脚本（纯系统工具：curl + grep + sed，无 Python）
    private static let script = """
set -u
BASE_URL="$1"; REPO_ID="$2"; DEST_DIR="$3"

API_URL="${BASE_URL}/api/models/${REPO_ID}"
echo "@@INFO:正在获取文件列表 ${API_URL}"
RESP="$(curl -sSL --fail --connect-timeout 15 --retry 2 "${API_URL}")" || {
  echo "@@ERROR:无法获取模型文件列表（源：${BASE_URL}）。请检查网络后重试。"
  exit 1
}

# 从 HF API JSON 提取全部文件名（rfilename），并过滤与加载无关的文件
FILES="$(printf '%s' "${RESP}" \
  | grep -o '"rfilename":"[^"]*"' \
  | sed 's/"rfilename":"//;s/"$//' \
  | grep -v -E '(^|/)\\.git|\\.md$|^onnx/|^openvino/|^coreml/|^logs/|\\.msgpack$|^flax_model|^tf_model|^rust_model' || true)"

TOTAL="$(printf '%s\\n' "${FILES}" | grep -c .)"
if [ -z "${FILES}" ] || [ "${TOTAL}" -eq 0 ]; then
  echo "@@ERROR:文件列表为空（API 返回异常或网络不通）"
  exit 1
fi
echo "@@TOTAL:${TOTAL}"

N=0
while IFS= read -r F; do
  [ -z "${F}" ] && continue
  N=$((N+1))
  echo "@@FILE_START:${N}/${TOTAL}:${F}"
  OUT_PATH="${DEST_DIR}/${F}"
  mkdir -p "$(dirname "${OUT_PATH}")"
  URL="${BASE_URL}/${REPO_ID}/resolve/main/${F}"
  # -C - 断点续传；--fail 让 HTTP 4xx/5xx 返回非零退出码
  curl -# -L --fail --connect-timeout 15 --retry 2 -C - -o "${OUT_PATH}" "${URL}"
  RC=$?
  if [ "${RC}" -ne 0 ] && [ "${RC}" -eq 33 ]; then
    # 33 = Range Not Satisfiable：本地文件多半已完整/越界，删除后整档重下兜底
    echo "@@INFO:${F} 续传越界（416），重下该文件…"
    rm -f "${OUT_PATH}"
    curl -# -L --fail --connect-timeout 15 --retry 2 -o "${OUT_PATH}" "${URL}"
    RC=$?
  fi
  if [ "${RC}" -ne 0 ]; then
    echo "@@ERROR:下载 ${F} 失败（curl 退出码 ${RC}）。已下载的其余文件会保留，可重试续传。"
    exit 1
  fi
  echo "@@FILE_DONE:${N}/${TOTAL}:${F}"
done <<< "${FILES}"

echo "@@ALL_DONE:${DEST_DIR}"
"""

    // MARK: - 状态
    private var process: Process?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var fileIndex = 0
    private var fileTotal = 0
    private var fileName = ""
    private var filePercent = 0.0
    private var lastErrorMessage: String?

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - 对外接口

    /// 启动下载。回调（onLog / onProgress / onFinish）均已在主线程派发。
    /// - Parameters:
    ///   - repoID: HF 仓库 ID（如 BAAI/bge-small-zh-v1.5）
    ///   - baseURL: 下载源根地址（https://hf-mirror.com 或 https://huggingface.co）
    ///   - destination: 本地落点目录（扁平结构，SentenceTransformer 可直接加载）
    func start(repoID: String,
               baseURL: String,
               destination: URL,
               onLog: @escaping (String) -> Void,
               onProgress: @escaping (Progress) -> Void,
               onFinish: @escaping (_ success: Bool, _ message: String) -> Void) {
        cancel()
        stdoutBuffer = Data()
        stderrBuffer = Data()
        fileIndex = 0; fileTotal = 0; fileName = ""; filePercent = 0
        lastErrorMessage = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        // bash -c 'script' $0 $1 $2 $3 → 脚本内 $1/$2/$3 = baseURL/repoID/destDir
        proc.arguments = ["-c", Self.script, "hf-model-download", baseURL, repoID, destination.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmptyData else { return }
            self?.handleStdout(data, onLog: onLog, onProgress: onProgress)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let data = h.availableData.nonEmptyData else { return }
            self?.handleStderr(data, onProgress: onProgress)
        }

        proc.terminationHandler = { [weak self] p in
            let ok = (p.terminationStatus == 0)
            let errMsg = self?.lastErrorMessage
            DispatchQueue.main.async {
                if ok {
                    onFinish(true, "下载完成")
                } else {
                    onFinish(false, errMsg ?? "下载进程异常退出（退出码 \(p.terminationStatus)）")
                }
            }
            self?.process = nil
        }

        process = proc
        do {
            try proc.run()
        } catch {
            DispatchQueue.main.async {
                onFinish(false, "无法启动下载进程：\(error.localizedDescription)")
            }
            process = nil
        }
    }

    /// 终止正在进行的下载（已完成的文件保留，下次续传）。
    func cancel() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    // MARK: - stdout：结构化消息（文件级进度）

    private func handleStdout(_ data: Data,
                              onLog: @escaping (String) -> Void,
                              onProgress: @escaping (Progress) -> Void) {
        stdoutBuffer.append(data)
        // 按换行切行，逐行解析
        while let nlIdx = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nlIdx]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nlIdx)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            parseStdoutLine(line, onLog: onLog, onProgress: onProgress)
        }
    }

    /// 解析 "N/M:name" 形式的负载 → (N, M, name)
    private static func parseIndexPayload(_ payload: String) -> (index: Int, total: Int, name: String)? {
        let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let nums = parts[0].split(separator: "/")
        guard nums.count == 2, let i = Int(nums[0]), let t = Int(nums[1]) else { return nil }
        return (i, t, String(parts[1]))
    }

    private func parseStdoutLine(_ line: String,
                                 onLog: @escaping (String) -> Void,
                                 onProgress: @escaping (Progress) -> Void) {
        if line.hasPrefix("@@TOTAL:") {
            let n = Int(line.dropFirst("@@TOTAL:".count)) ?? 0
            fileTotal = n
            DispatchQueue.main.async {
                onLog("共 \(n) 个文件待下载")
            }
        } else if line.hasPrefix("@@FILE_START:") {
            let payload = String(line.dropFirst("@@FILE_START:".count))
            if let (i, t, name) = Self.parseIndexPayload(payload) {
                fileIndex = i
                fileTotal = t
                fileName = name
                filePercent = 0
                emitProgress(onProgress)
            }
        } else if line.hasPrefix("@@FILE_DONE:") {
            let payload = String(line.dropFirst("@@FILE_DONE:".count))
            if let (i, t, name) = Self.parseIndexPayload(payload) {
                fileIndex = i
                fileTotal = t
                fileName = name
                filePercent = 100
                emitProgress(onProgress)
            }
            DispatchQueue.main.async {
                onLog("✅ 已完成 \(self.fileName)")
            }
        } else if line.hasPrefix("@@ALL_DONE:") {
            let path = String(line.dropFirst("@@ALL_DONE:".count))
            DispatchQueue.main.async {
                onLog("✅ 全部文件下载完成：\(path)")
            }
        } else if line.hasPrefix("@@ERROR:") {
            let msg = String(line.dropFirst("@@ERROR:".count))
            lastErrorMessage = msg
            DispatchQueue.main.async {
                onLog("❌ \(msg)")
            }
        } else if line.hasPrefix("@@INFO:") {
            let msg = String(line.dropFirst("@@INFO:".count))
            DispatchQueue.main.async {
                onLog(msg)
            }
        } else {
            DispatchQueue.main.async {
                onLog(line)
            }
        }
    }

    // MARK: - stderr：curl 进度条解析（字节级进度）

    /// `curl -#` 进度条形如 `#####-------  42.7%`，用 \\r 原地刷新。
    /// 只保留缓冲区最后一段（最后一个 \\r/\\n 之后），取其中百分比。
    private func handleStderr(_ data: Data, onProgress: @escaping (Progress) -> Void) {
        stderrBuffer.append(data)
        // 截取最后一个 \r (0x0D) 或 \n (0x0A) 之后的内容作为"当前段"
        var segmentStart = stderrBuffer.startIndex
        var idx = stderrBuffer.startIndex
        while idx < stderrBuffer.endIndex {
            let b = stderrBuffer[idx]
            if b == 0x0D || b == 0x0A { segmentStart = stderrBuffer.index(after: idx) }
            idx = stderrBuffer.index(after: idx)
        }
        // 防缓冲无限增长：只保留当前段
        if segmentStart > stderrBuffer.startIndex {
            stderrBuffer.removeSubrange(stderrBuffer.startIndex..<segmentStart)
        }
        if stderrBuffer.count > 4096 { stderrBuffer.removeFirst(stderrBuffer.count - 256) }

        let segment = String(decoding: stderrBuffer, as: UTF8.self)
        guard let pct = Self.firstPercent(in: segment) else { return }
        // 过滤回退噪声（新文件刚开始时旧 100% 残留）
        if pct <= filePercent + 0.01 || (filePercent > 99 && pct < 5) { return }
        filePercent = pct
        emitProgress(onProgress)
    }

    /// 从文本中提取第一个百分数（如 "  42.7%" → 42.7）
    private static func firstPercent(in s: String) -> Double? {
        guard let r = s.range(of: #"[0-9]+(?:\.[0-9]+)?%"#, options: .regularExpression) else { return nil }
        let num = s[r].dropLast()
        return Double(num)
    }

    private func emitProgress(_ onProgress: @escaping (Progress) -> Void) {
        let p = Progress(fileIndex: fileIndex, fileTotal: fileTotal,
                         fileName: fileName, filePercent: filePercent)
        DispatchQueue.main.async {
            onProgress(p)
        }
    }
}

private extension Data {
    /// 非空时返回 self，否则 nil（readabilityHandler 可能给空包）
    var nonEmptyData: Data? { isEmpty ? nil : self }
}
