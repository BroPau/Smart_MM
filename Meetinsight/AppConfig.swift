//
//  AppConfig.swift
//  Meetinsight
//

import Foundation
import Security

/// 与 pipeline.py 的接口契约（见 Swift_Python_Interface_Contract.md §2/§3）。
/// 职责：本地配置持久化（UserDefaults）+ API Key（Keychain）+ 构造启动子进程的环境变量。
/// 不隔离到 @MainActor：仅读写 UserDefaults / Security，均为线程安全 API；
/// 避免与 URLSessionDownloadDelegate 等非隔离协议冲突。
final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard
    private let keychain = KeychainHelper.shared

    // MARK: - 路径配置（契约 §3 工作目录布局）
    /// 根工作目录 MM_BASE_DIR。默认放在用户文档下的 MeetingMinutes。
    var baseDir: URL {
        get {
            if let p = defaults.string(forKey: "MM_BASE_DIR") {
                return URL(fileURLWithPath: p)
            }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingMinutes")
        }
        set { defaults.set(newValue.path, forKey: "MM_BASE_DIR") }
    }

    /// whisper.cpp 二进制路径（WHISPER_CLI）。
    var whisperCLI: URL {
        get {
            if let p = defaults.string(forKey: "WHISPER_CLI") { return URL(fileURLWithPath: p) }
            return URL(fileURLWithPath: "/Users/weilu/whisper.cpp/build/bin/whisper-cli")
        }
        set { defaults.set(newValue.path, forKey: "WHISPER_CLI") }
    }

    /// ggml 模型路径（WHISPER_MODEL）。
    var whisperModel: URL {
        get {
            if let p = defaults.string(forKey: "WHISPER_MODEL") { return URL(fileURLWithPath: p) }
            return URL(fileURLWithPath: "/Users/weilu/whisper.cpp/models/ggml-large-v3.bin")
        }
        set { defaults.set(newValue.path, forKey: "WHISPER_MODEL") }
    }

    // MARK: - Python 引擎定位（v1：指向 PythonEngine 目录；正式打包时改为 Bundle 内嵌）
    /// Python 解释器解析顺序（与 SOP §运行环境 一致）：
    /// 1) UserDefaults 显式指定的 PYTHON_EXECUTABLE（最高优先级，便于临时切换）；
    /// 2) PythonEngine/app/_deps_venv/bin/python3（本地 venv，存在则用，当前未构建）；
    /// 3) 回退到系统 Python 3.11 `/usr/local/bin/python3`（已装 numpy/pypinyin/
    ///    sentence-transformers/google-genai，**pipeline 要求的最低运行环境**，见 requirements.txt）。
    /// 注意：绝不可回退到 /usr/bin/python3（macOS 自带 3.9.6，无 numpy，会导致 import 失败、退出码 1）。
    var pythonExecutable: URL {
        get {
            if let p = defaults.string(forKey: "PYTHON_EXECUTABLE") { return URL(fileURLWithPath: p) }
            let venv = URL(fileURLWithPath:
                "/Users/weilu/Downloads/ShareFolder/Meetinsight/PythonEngine/app/_deps_venv/bin/python3")
            if FileManager.default.fileExists(atPath: venv.path) { return venv }
            return URL(fileURLWithPath: "/usr/local/bin/python3")
        }
        /// 由向导「浏览 Python…」写入（UserDefaults: PYTHON_EXECUTABLE），优先级最高。
        set { defaults.set(newValue.path, forKey: "PYTHON_EXECUTABLE") }
    }

    /// 是否跳过嵌入模型（不使用 RAG 语义检索）。由向导「跳过（不使用 RAG）」设置；
    /// pipeline 读取 MM_EMBEDDING_SKIP=1 后禁用语义 RAG，Wiki 检索降级为关键词匹配。
    var embeddingModelSkipped: Bool {
        get { defaults.bool(forKey: "MM_EMBEDDING_SKIP") }
        set { defaults.set(newValue, forKey: "MM_EMBEDDING_SKIP") }
    }

    /// 本地嵌入模型路径（可选）。若用户在向导中点了「浏览本机嵌入模型…」指定了
    /// 已有 bge-small-zh-v1.5 目录（含 config.json + model.safetensors），则 pipeline
    /// 优先从此处加载，无需走网络下载。空时回退到 ~/.cache/huggingface 或在线。
    /// 同时兼容指向 snapshots/<hash>/ 子目录或解压后的模型根目录两种形式。
    var embeddingModelPath: URL? {
        get {
            guard let p = defaults.string(forKey: "EMBEDDING_MODEL_PATH"),
                  !p.isEmpty else { return nil }
            return URL(fileURLWithPath: p)
        }
        set {
            if let v = newValue {
                defaults.set(v.path, forKey: "EMBEDDING_MODEL_PATH")
            } else {
                defaults.removeObject(forKey: "EMBEDDING_MODEL_PATH")
            }
        }
    }

    /// 是否使用国内镜像下载嵌入模型（默认 false）。
    /// 设为 true 时 pipelineEnvironment() 会注入 HF_ENDPOINT=https://hf-mirror.com，
    /// huggingface_hub 库下载时即走镜像（无需科学上网）。
    /// hf-mirror.com 是 huggingface.co 的国内 CDN 镜像，文件结构完全一致，对
    /// sentence-transformers / huggingface_hub 透明（设置 HF_ENDPOINT 后所有请求自动走镜像）。
    var embeddingUseMirror: Bool {
        get { defaults.bool(forKey: "EMBEDDING_USE_MIRROR") }
        set { defaults.set(newValue, forKey: "EMBEDDING_USE_MIRROR") }
    }

    /// Hugging Face 缓存/下载根目录（HF_HOME）。
    /// **关键**：沙箱 App 禁止写用户主目录下的 ~/.cache，故指向沙箱容器可写的
    /// Caches/huggingface（App 进程天生可读写）。下载与离线加载都走这个目录，
    /// 与 pipelineEnvironment() 注入的 HF_HOME 完全一致。
    var huggingfaceHome: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("huggingface")
    }

    /// pipeline.py 脚本路径。
    /// 解析顺序（v2.2.12+）：
    ///   ① Bundle 内嵌 `Contents/Resources/PythonEngine/pipeline.py`（Xcode 「Copy PythonEngine」
    ///      阶段注入；sandbox 可读，不依赖任何 sandbox 外路径——永远受 sandbox 友好）；
    ///   ② UserDefaults 显式 `PIPELINE_SCRIPT`（向后兼容高级用户/开发期临时切换）；
    ///   ③ 旧硬编码开发路径（保留回退以防 IDE 单独打开工程、bundle 内未填充）。
    var pipelineScript: URL {
        get {
            if let u = Self.bundledPythonEngineURL()?.appendingPathComponent("pipeline.py"),
               FileManager.default.fileExists(atPath: u.path) {
                return u
            }
            if let p = defaults.string(forKey: "PIPELINE_SCRIPT"), !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            return URL(fileURLWithPath:
                "/Users/weilu/Downloads/ShareFolder/Meetinsight/PythonEngine/pipeline.py")
        }
        /// setter：让高级用户/开发期通过 `defaults write ... PIPELINE_SCRIPT <路径>`
        /// 或后续"浏览脚本…"UI 注入显式路径，覆盖默认解析；正常情况下无需调用。
        set { defaults.set(newValue.path, forKey: "PIPELINE_SCRIPT") }
    }

    /// Bundle 内嵌 PythonEngine 根目录（v2.2.12+）。
    /// 构建时 Xcode 「Copy PythonEngine」阶段把 `pipeline.py + app/*.py +
    /// 005_LLMWiKi/wiki_*.py + default_system_prompt.txt + icon_source.png +
    /// requirements.txt` 拷入 `Contents/Resources/PythonEngine/`；本方法在
    /// `pipeline.py` 存在时返回该目录 URL，否则 nil（用于回退到 sandbox 外旧路径）。
    static func bundledPythonEngineURL() -> URL? {
        guard let r = Bundle.main.resourceURL else { return nil }
        let root = r.appendingPathComponent("PythonEngine")
        let probe = root.appendingPathComponent("pipeline.py")
        return FileManager.default.fileExists(atPath: probe.path) ? root : nil
    }

    // MARK: - 大模型供应商（契约 §2）
    enum Provider: String { case gemini, openai }

    var llmProvider: Provider {
        get { Provider(rawValue: defaults.string(forKey: "MM_LLM_PROVIDER") ?? "gemini") ?? .gemini }
        set { defaults.set(newValue.rawValue, forKey: "MM_LLM_PROVIDER") }
    }
    var llmModel: String {
        get { defaults.string(forKey: "MM_LLM_MODEL") ?? (llmProvider == .gemini ? "gemini-3.5-flash" : "gpt-4o-mini") }
        set { defaults.set(newValue, forKey: "MM_LLM_MODEL") }
    }
    var openAIBaseURL: String? {
        get { defaults.string(forKey: "MM_LLM_BASE_URL") }
        set { defaults.set(newValue, forKey: "MM_LLM_BASE_URL") }
    }

    // MARK: - 自定义系统提示词（契约 §2 MM_LLM_SYSTEM_PROMPT）
    /// 会议纪要生成的自定义 system prompt；为空时使用 pipeline 内置默认提示词。
    /// 写入 UserDefaults 后由 pipelineEnvironment() 注入 MM_LLM_SYSTEM_PROMPT。
    var customSystemPrompt: String? {
        get { defaults.string(forKey: "MM_LLM_SYSTEM_PROMPT") }
        set {
            if let v = newValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                defaults.set(v, forKey: "MM_LLM_SYSTEM_PROMPT")
            } else {
                defaults.removeObject(forKey: "MM_LLM_SYSTEM_PROMPT")
            }
        }
    }

    /// **默认** system prompt（单一真相源 = `PythonEngine/app/default_system_prompt.txt`）。
    /// 设置页和向导若未自定义,均显示这个 prompt;
    /// Swift 端内置常量仅作离线/打包环境 fallback(内容与 pipeline.py `_DEFAULT_MINUTES_PROMPT` 一致)。
    var defaultSystemPrompt: String {
        let bundlePath = Bundle.main.url(forResource: "default_system_prompt", withExtension: "txt")
        if let u = bundlePath, let s = try? String(contentsOf: u, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        let sourcePath = "/Users/weilu/Downloads/ShareFolder/Meetinsight/PythonEngine/app/default_system_prompt.txt"
        if let s = try? String(contentsOfFile: sourcePath, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        return DefaultSystemPrompt.fallback
    }

    /// 当前供应商对应的 API Key（从 Keychain 读取，绝不落盘明文）。
    func apiKey() -> String? {
        keychain.read(account: llmProvider == .gemini ? "GEMINI_API_KEY" : "OPENAI_API_KEY")
    }
    func setAPIKey(_ value: String) {
        keychain.save(value, account: llmProvider == .gemini ? "GEMINI_API_KEY" : "OPENAI_API_KEY")
    }

    // MARK: - 构造 pipeline.py 启动环境（契约 §2）
    func pipelineEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["MM_BASE_DIR"] = baseDir.path
        env["MM_LLM_PROVIDER"] = llmProvider.rawValue
        env["MM_LLM_MODEL"] = llmModel
        if let key = apiKey() {
            if llmProvider == .gemini {
                env["GEMINI_API_KEY"] = key
            } else {
                env["OPENAI_API_KEY"] = key
                env["MM_LLM_API_KEY"] = key
            }
        }
        if let url = openAIBaseURL, llmProvider == .openai {
            env["OPENAI_BASE_URL"] = url
            env["MM_LLM_BASE_URL"] = url
        }
        env["WHISPER_CLI"] = whisperCLI.path
        env["WHISPER_MODEL"] = whisperModel.path
        env["MM_WHISPER_ENGINE"] = "cli"
        if let prompt = customSystemPrompt, !prompt.isEmpty {
            env["MM_LLM_SYSTEM_PROMPT"] = prompt
        }
        // .app 内嵌资源（ffmpeg 回退二进制所在：Contents/Resources）
        if let res = Bundle.main.resourceURL?.path {
            env["MM_APP_RESOURCES"] = res
        }
        // Hugging Face 缓存根目录：沙箱 App 无法写 ~/.cache，改指容器可写 Caches/huggingface
        env["HF_HOME"] = huggingfaceHome.path
        // 用户选择跳过嵌入模型 → 停用语义 RAG
        if embeddingModelSkipped {
            env["MM_EMBEDDING_SKIP"] = "1"
        }
        // 用户手动指定的本地嵌入模型路径 → pipeline 优先本地加载（避免重复下载）
        if let p = embeddingModelPath {
            env["MM_EMBEDDING_MODEL_PATH"] = p.path
        }
        // 国内镜像开关 → huggingface_hub 自动走 hf-mirror.com（无需科学上网）
        if embeddingUseMirror {
            env["HF_ENDPOINT"] = "https://hf-mirror.com"
        }
        return env
    }

    /// 是否已基本配置完成（用于决定是否弹出安装向导）。
    var isConfigured: Bool {
        apiKey() != nil && FileManager.default.fileExists(atPath: baseDir.path)
    }

    // MARK: - 各组件就绪判定（向导逐步校验用）
    var isWhisperCLIPresent: Bool {
        FileManager.default.fileExists(atPath: whisperCLI.path)
    }
    var isWhisperModelPresent: Bool {
        FileManager.default.fileExists(atPath: whisperModel.path)
    }
    var isBaseDirPresent: Bool {
        FileManager.default.fileExists(atPath: baseDir.path)
    }
}

/// 与 pipeline.py `_DEFAULT_MINUTES_PROMPT` 内容保持一致的离线 fallback。
/// 真实运行时优先读取 `PythonEngine/app/default_system_prompt.txt`(或打包进 Bundle 的同名资源),
/// 此常量仅作开发调试 / 文件缺失时的最后兜底。
private enum DefaultSystemPrompt {
    static let fallback: String = """
你是半导体/硬件供应链会议纪要专家。输出高信息密度、结构化收敛的中文纪要。
铁律：
- 用紧凑Markdown表格/键值对收敛，禁止散文式长段平铺。
- 每条论点≤60字，直奔主题。
- 数字、日期、芯片型号、定价、交期100%精准还原。
- 脱敏占位符([PERSON_X]/[COMPANY_X]等)原样保留，禁止改删；禁止在占位符外补充中文音译名/头衔。
- 人名、公司名必须严格使用下方【已知标准名单】中的写法，禁止音译、臆造或合并不同人物；确需头衔须来自背景资料明确字段。
- 未在名单中且未被脱敏为占位符的人物，保留原文写法，不要强行对应到名单人物。
- 原文若含 [SPEAKER_X] 说话人标签：请在纪要中【保留说话人归属】——将各方立场/诉求/论据/态度按 SPEAKER 归并（如议题讨论按 SPEAKER 分列、第七章按说话人分别描写态度）。[HH:MM:SS] 时间戳仅作时序参考，不必逐条保留。
- 结合下方【背景参考】纠正语音识别的技术术语错误。
严格按以下结构输出，【共七章，禁止自行增减章节，禁止输出模板之外的任何章节（尤其不要输出'自学习/更新任务/待办补充'等额外章节）】：
【会议类型：…】
# 一、会议基本信息
| 主题 | 时间 | 地点 | 类型 |
| 核心目标 | （一句话） |
| 参会方 | 姓名 | 职务/Title | 职责 |（按方分表）
# 二、会议背景
- 缘起：
- 业务概况：
# 三、核心议题讨论
## 议题N：[名称]
- 背景与痛点：
- 讨论细节：
| 公司/人员 | 诉求(≤60字) | 论据/博弈 |
- 定论与逻辑：
# 四、决议与共识
| 核心板块 | 决议内容 | 背后考量 |
# 五、行动清单
| 序号 | 任务 | 负责人/方 | 时间节点 |（NXP/客户/共同可各分一表）
# 六、关键信息备忘
- 时间节点：| 日期 | 事件 |
- 关键数据：| 项目 | 数值 |
- 风险点：| 风险 | 说明 | 应对 |
# 七、会议氛围与态度（必填章节，须具体描写各方立场态度与会议整体基调，≥80字，禁止空白）
- 各方态度与整体基调：
"""
}
