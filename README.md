# Meetinsight

> **最后更新**：2026-08-17 ｜ **版本**：v2.2.6
> **v2.2.6 更新（整项目重命名）**：英文主名 **Meetinsight**、中文副标「知会」。文件夹 / 工程名 / App 显示名 / BundleID 全部改为 Meetinsight；`AppConfig` 的 PythonEngine 路径同步更新；Keychain service 与数据目录默认刻意保留（不破坏已存 API Key 与 Wiki 数据）。已 `xcodebuild -scheme "Meetinsight" Debug` 通过并 `cmp` 部署到 `/Users/weilu/Applications/Meetinsight.app`。  
> **v2.2.5 更新（用户要求）**：已 `xcodebuild Debug` 通过并 `cmp` 字节校验部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。**Wiki 页「类型」字段支持自定义选项**——`WikiPropertySheet` 类型下拉旁新增「+」按钮，点击录入新类型；新类型**持久化**到 `baseDir/005_LLMWiKi/custom_types.json`，每次打开属性面板（新增/编辑任意 Wiki 页）都会加载，**所有页面的类型下拉共享同一份自定义项**。录入自动剔除会破坏 YAML `type:` 字段的特殊字符、并与内置 6 型及已有自定义项去重；按类型动态显隐专属字段的逻辑不变。
> **v2.2.4 修复（用户 3 点实测反馈）**：已 `xcodebuild Debug` 通过并 `cmp` 字节校验部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。① **顶部布局**：移除「Smart Minutes」标题文字；三个 tab 按钮（纪要生成 / LLM Wiki / 设置）改用 `centerXAnchor` 显式居中约束，真正水平居中（此前弹性 spacer 均分实测仍偏左）。② **Wiki 噪声根治**：删除首页「未标注公司」分组下 8 个误识别噪声页（都没有/周二上/东西晚/国产产/国产办/空调市/金元/韩柯），从 `global_desensitize_mapping.json` 源头 prune（已备份）并加入 `pipeline.py _CN_NAME_STOP` 噪声停词表彻底杜绝复活；`--build-index` 重建首页后「未标注公司」分组消失。③ **导入会议纪要行为核查**：该按钮走 `--import-docs → import_documents()`，仅 转 md → 脱敏 → 重建 RAG 知识库向量库，**不会**自动切片/抽取关键信息/建新 Wiki 页（自动建页能力在另一入口 `import_manual_minutes`，当前按钮未接）。
> 一款 **macOS 原生 App**，把会议录音自动变成结构化、可落地的会议纪要，并沉淀为个人知识 Wiki。

> **v2.0.2 修复**：① 所有弹出式通知（对话框）现在都带图标——新增 `AppAlert` 统一封装 `NSAlert`、改用 SF Symbols 图标，消除此前 App 图标缺失导致的弹窗破图；② 修复 Wiki 首页 emoji（🏢🧍🔧📁）显示成方块（□）的渲染问题；③ 补齐了 App 图标（之前 10 个尺寸槽全空，Dock/窗口/弹窗均无图标）。重新构建并部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`，重开 App 即可见。

> **v2.2.0 更新（用户要求）**：**编辑器引擎从 Vditor 换成 TipTap（ProseMirror 系）**——做到 **Typora 式真·所见即所得**：输入 `# ` 后 `#` 自动消失只留 H1 样式、`**粗体**` 直接渲染、Markdown 源码符号默认不显示；选区浮动工具条。更重要的是**真双链落地**：`[[页面]]` / `[[页面|别名]]` 渲染为可点 pill；输入 `[[` 自动弹出候选列表（↑↓ 选择、↵/Tab 确认）；**缺失页红色虚线下划线**，点击或 ⌘+Click 一键新建；**悬浮预览气泡**（hover 经宿主回传目标页正文）。Markdown 往返用 `markdown-it`+`turndown`（自写 GFM 表格/删除线规则）保证双链/表格/frontmatter 不丢。新增 Wiki 页弹窗紧凑化（v2.1.3）。离线打包 `tiptap.bundle.js`(~540KB) 经 Xcode「Copy TipTap」阶段自动进 `Contents/Resources/tiptap`；可用 `defaults write com.weilu.meetingminutes editorEngine vditor` 回退 Vditor。已 `xcodebuild Debug` 通过并部署。

> **v2.2.1 修复（用户 5 点反馈 + 授权直接执行）**：已 `xcodebuild Debug` 通过并部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。① **三按钮真正居中**——旧修法 `topBar.alignment = .fill` 编译不过（`NSStackView.alignment` 无 `.fill`）；真正修法：保留 `.leading` + 显式 trailing 约束把 `topBar`/`tabRow`/`bottomRow` 拉伸到全宽，弹性 spacer 吸收多余宽度 → 纪要生成/LLM Wiki/设置 三按钮严格居中。② **Wiki 页属性可编辑**——TipTap banner 新增「✏️ 编辑属性」按钮 → `editorBridge` 发 `editProperties` → Swift 极简 YAML 解析 frontmatter → 弹 `WikiPropertySheet` 只重写 frontmatter、保留正文 → 写回并 `loadPages()`；整个 wiki page 信息现在都可编辑。③ **新增 Wiki 页对话框上半屏空白**——改为单一 `outerStack` 从顶部排字段，面板 580×700 → 620×780 容纳 chip 6 行字段。④ **双链点击跳转换（弹"未找到 Wiki 页面"）**——`resolveWikiPage` 重写为 5 档匹配（新增前缀 fuzzy 剥括号，覆盖 `ST (宪法半导体)` 这类双链）。⑤ **Wiki 人名噪声治理（中英文）**——`pipeline._looks_like_cn_name` 大幅收紧（新增单字角色尾/2字硬停表/3字角色尾），已删 25 个确证中文噪声页、首页重建 92 页、`auto_stub` 首关防再生。

> **v2.2.2 修复（用户反馈「编辑属性卡死 + 要内联同屏编辑」）**：已 `xcodebuild Debug` 通过并部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。① **修复点「编辑属性」后程序卡死**——根因是 Swift 在 `WKScriptMessageHandler` 回调里**同步调用 `evaluateJavaScript`**，触发 WKWebView 经典死锁。② **属性编辑改为内联、与正文同窗同屏（不再弹独立窗口）**——去掉 `editProperties` 弹窗链路（Swift `case "editProperties"` + `WikiViewController` 弹 `WikiPropertySheet` 一并移除）；banner「✏️ 编辑属性」改为**就地切换 banner 为可编辑表单**（input/textarea/select，按 type 动态显隐 person/company/chip 专属字段），实时写回 frontmatter；下方正文始终可见可编辑；点「✓ 完成」重组 YAML frontmatter 并保存。**全程 0 次 `evaluateJavaScript`、0 次模态弹窗**，卡死从根上消除。③ **顺带加固 `wikilinkPreview` 悬浮预览**的同步死锁隐患（改用 `DispatchQueue.main.async`）。

> **v2.2.3 修复（用户 3 点实测反馈）**：已 esbuild 重打包 `tiptap.bundle.js` + `xcodebuild Debug` 通过并部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。① **属性页「真正」始终直接可编辑**——去掉「✏️ 编辑属性」按钮与 `bannerEditMode`/`wireBannerButtons`/`commitBannerEdit` 整条切换逻辑；banner **始终渲染可编辑表单**（input/textarea/select，按 type 动态显隐），任意字段改动实时写回 frontmatter 并防抖 400ms 自动保存，无需任何按钮。② **修复「新增 Wiki 页」关闭即卡死（必现、只能强退）**——根因 `NSApp.runModal` 的 `stopModal` 只在「确定/取消」按钮里调用，点红色关闭按钮时不触发。改为 `panel.delegate = vc` + `windowWillClose` 在**任何关闭路径都 `stopModal()`**（加 `stopped` 守卫防重复）。③ **修复「新增 Wiki 页」中部大片空白 + 输入框过小**——内容栈改包进 `NSScrollView`（仅纵向滚动、从顶自然排布、空白消失），面板按内容 `fittingSize` 自适应（380–680 高，超高则滚动不裁剪）；单/多行输入框显著加大（文本框 20→24，概要/反向链接/公司简介/功能简述框高均放大）。

> **v2.1.2 更新（用户截图反馈）**：① **深色模式显示修复**——`MarkdownEditorView` CSS 全面调整 `prefers-color-scheme: dark` 下的颜色对比（`fmBanner` 底色加深、字段字色加亮），并给 vditor 容器 / 工具栏 / 弹窗 / 下拉强制吃深色主题，dark 下不淡。② **3 个主按钮顶部居中**——`MainContainerViewController` topBar 改为两行布局：第 1 行 `[NSView-elastic][tabGroup][NSView-elastic]`（弹性 spacer 把 tab 严格推到水平正中），第 2 行 `[title-left][NSView-elastic][save-right]`，tab 不再偏右。③ **Vditor 工具栏常驻显示**——`toolbarConfig.pin = true`，与 Obsidian 默认一致，工具栏不再 hover 才浮现。④ **新增 Wiki 页弹窗仿 Obsidian 笔记属性全面化**——新增独立 `WikiPropertySheet`（独立 NSWindow 模态），含 9 类属性（类型下拉含 6 种 / 规范名 / 别名 pill 可 × 删+添加 / 公司 / 职位 / 职能范围 / 标签 pill / 更新 / 反向链接 / 概要），按 type 动态显隐三类专属字段；`pipeline.add_wiki_page / render_wiki_page` 透传 `extra_tags` 与 `backlinks` 字段，用户手填反向链接时覆盖默认 `[[Wiki_首页|...]]`。已 `xcodebuild Debug` 通过，部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`。

> **v2.1.1 修复（用户截图反馈）**：① 修复「编辑器资源缺失：Resources/vditor 未打包进 App」——给 Xcode 工程加 **Copy Vditor Run Script Build Phase**（同时设 `ENABLE_USER_SCRIPT_SANDBOXING=NO`），从此 Xcode Run 和 `xcodebuild` 都自动拷贝 vditor 到 `.app/Contents/Resources/`，不再依赖手工 `cp`。② 修复「+新增 Wiki 页」弹窗挤压不可编辑——`presentPageDialog` 改用 frame-based `NSView` 容器（360×148）固定 4 个字段宽度，告别 NSStackView + NSAlert 配合时的 auto-layout 塌陷。③ 把侧栏 3 个按钮（纪要生成 / LLM Wiki / 设置）移到顶部横向 tab 栏，移除 `sidebar` 宽度约束，内容区吃满全宽。④ Wiki 列表/编辑器分隔条改为可拖动（移除 `listScroll` 固定 320pt 宽约束，加 `autosaveName` 持久化拖动位置 + 最小 200pt 宽度）。已重新构建零警告，部署到 `/Users/weilu/Applications/Smart Meeting Minutes.app`，DerivedData Debug 路径下的副本也已同步 vditor。

---

## 文档维护约定（铁律）

- 本仓库的 **`SOP.md`**（标准作业程序，含完整变更史）与 **`README.md`** 是**唯一权威文档**。任何功能性更改 / 升级后，必须在同一轮工作内更新这两份（顶部「最后更新」+ 变更摘要 + 对应章节）。
- **GitHub 备份（2026-08-17 新增）**：每次更新代码 + 重写上述文档后，**必须一并 `git push` 到 GitHub 备份**，不能只留本地。远端已切 SSH：`git@github.com:BroPau/Smart_MM.git`；`.gitignore` 已排除 `node_modules` / 运行数据 / 脱敏映射（`PythonEngine/`、`global_desensitize_mapping.json` 等还原钥匙刻意不入库，仅留本地）。

---

## 它能做什么

1. **音频转写**：把 `.m4a / .mp3 / .wav / .aac` 会议录音转成文字（whisper.cpp 或 whisper python）。
2. **隐私脱敏**：中转阶段用占位符替换真名/公司名，并保留可本地还原的映射。
3. **LLM 精炼纪要**：调用 Gemini / OpenAI 兼容大模型，生成带决策、行动项、要点的精炼纪要。
4. **个人 Wiki**：自动把纪要/资料沉淀为可检索的个人知识库（含公司/芯片等公开实体页）。
5. **单窗口分页 UI（v2.0 起，v2.1.1 顶部 tab 化）**：窗口顶部横向 tab 一键切换三个分页——**① 纪要生成 / ② LLM Wiki（默认） / ③ 设置**，全部在窗口内切换、不再弹新窗口；顶部右侧唯一**「💾 保存」**按钮仅对纪要生成页生效（Wiki 页改完即落盘）。
   - **纪要生成页**：拖放区 +「选择音频 / 开始生成」，右侧 **TipTap 驱动**的真·所见即所得编辑器预览/编辑纪要（Typora 式实时渲染、`[[双链]]` 自动完成/缺失页红字/悬浮预览；Vditor 作为可回退引擎保留）。
   - **LLM Wiki 页**：左列表（Wiki 首页置顶、**支持多选**）+ 右所见即所得预览；工具栏含 **搜索 / Wiki 首页 / 重建首页 / 刷新 / 打开文件夹 / ＋新增 / 📥 导入会议纪要 / 🗑 删除选中**；支持**右键菜单删除**与 **⌘Backspace 批量删除**。预览支持 `[[双链]]` 跳转（四级匹配：文件名 / 严格名 / 半角全角括号归一 / 别名），`[[双链]]` 渲染为可点 pill、点击经 `editorBridge` 跳转；Wiki 页顶部渲染 **frontmatter 约束 banner**（type / canonical_name / aliases / 来源 / 摘要等），一目了然页面由什么约束生成。「重建首页」只重建首页导航页（MOC），**不触碰 RAG 向量库**。
6. **会议纪要 / 导入手写纪要后自动沉淀**：每次会议纪要成功生成、或导入手写纪要成功后，pipeline 都会自动把新会议事实/学习笔记组织进个人 Wiki 并重建向量库（这是「页面生成 + RAG」重型流程，与手动「重建首页」按钮不同——手动按钮只刷新首页导航页）。可用 `MM_AUTO_WIKI=0` 关闭自动沉淀。
7. **设置页**：可视化选择 whisper.cpp 文件夹、选择/下载语音模型、填写自定义系统提示词、一键恢复默认。

## 架构一句话

- **Swift / AppKit 原生界面**（Xcode 工程）负责 GUI、配置、Keychain 保管 API Key；单窗口分页容器（纪要生成 / LLM Wiki / 设置）做「音频→纪要」与「知识库浏览/检索/维护」，**TipTap 引擎驱动的真·所见即所得编辑器**复用贯穿纪要预览与 Wiki 编辑（离线内置 `Resources/tiptap/tiptap.bundle.js` ~540KB，无外部网络依赖；Vditor 作为可回退引擎保留）；
- **Python 引擎**（`PythonEngine/pipeline.py` + `005_LLMWiKi/wiki_build.py` / `wiki_query.py`）负责转写、脱敏、精炼、Wiki 生成与检索；
- 两者用**环境变量 + JSON** 解耦通信，Swift 把 Python 当子进程调用（详见 `Swift_Python_Interface_Contract.md`）。

---

## 系统要求

- macOS（Xcode 26 工程；运行需 macOS 11+）
- Apple Silicon 推荐（Route B 发布包限 arm64）
- Python 3.11 + 依赖（`pip install -r PythonEngine/requirements.txt`）
- 转写引擎：whisper.cpp（CLI，默认）或 whisper python
- 大模型 API Key：Gemini 或 OpenAI 兼容（存系统 Keychain，绝不落盘）

---

## 快速开始（本地构建 + 运行）

### 方式 A：用 Xcode 打开构建（推荐）
1. 用 **Xcode.app** 打开 `Smart Meeting Minutes/Smart Meeting Minutes.xcodeproj`；
2. Scheme 选 `Smart Meeting Minutes`，目标 My Mac；
3. `Product ▸ Run`（⌘R）即可构建并启动；产物在 `Smart Meeting Minutes/build/Debug/Smart Meeting Minutes.app`。

### 方式 B：终端 xcodebuild
```bash
cd "Smart Meeting Minutes"
xcodebuild -project "Smart Meeting Minutes.xcodeproj" \
           -target "Smart Meeting Minutes" -configuration Debug build \
           CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

> 本地开发时，App 默认通过绝对路径调用本机 `PythonEngine/`（需本机保留该目录且 Python 3.11 就绪）。

### 首次运行
启动后走**安装向导四步**：校验依赖 → 选工作目录（baseDir） → 选 LLM 供应商并填 API Key → 进入主界面。之后秒开，直接读取 `~/Library/Application Support/MeetingMinutes/config.json`。

---

## LLM Wiki（分页②：浏览 / 检索 / 编辑）

点击顶部 tab **「📚 LLM Wiki」** 进入（默认进入此分页；菜单栏 **「知识库 → 打开 LLM Wiki」** 也可直达）。界面左右两大块：

- **左侧**是 Wiki 页面列表：**Wiki 首页始终置顶**（文件 `005_LLMWiKi/Wiki_首页.md`），其余页面来自 `005_LLMWiKi/wiki_pages/`（`--list-wiki-pages` 返回）。
- **右侧**是选中页面的内容预览/编辑区，采用 **TipTap 驱动的真·所见即所得编辑器**（ProseMirror 系，离线内置，默认引擎）：
  - **默认 Obsidian 实时预览（IR）**：同一份 DOM 边打字边渲染，`[[某页面]]` 渲染为**可点击双链 pill**；
  - 工具栏 `edit-mode` 切 **Typora 真所见即所得（WYSIWYG）**、`both` 切**分屏（SV）**；
  - 编辑完点顶部 / 容器工具栏 **「💾 保存」** 即写回对应 `.md`；
  - 点击 `[[双链]]` 会跳转（经 `editorBridge` 通知宿主）到对应 Wiki 页。
- **列表/编辑器之间的分隔条可拖动自由调整两侧宽度**（v2.1.1 起；`autosaveName="WikiSplitPosition"` 自动持久化用户偏好；左侧最小 200pt）。
- **列表上方工具栏**：
  - 搜索框：输入关键词回车，调用本地语义检索（`wiki_query.py`，**全程不出网**），结果以只读形式显示在右侧；
  - `🏠 Wiki 首页`：回到置顶的首页；
  - `重建 Wiki`：运行 `wiki_build.py`，把词库/纪要重新组织成结构化页面并重建向量索引（**首次需联网下载 bge 模型 ≈90MB**，之后秒级）；
  - `刷新索引`：重新生成 Wiki 首页（`--build-index`）并统一页格式（`--normalize-wiki`）；
  - `打开文件夹`：在访达打开 `005_LLMWiKi/wiki_pages/`；
  - `＋ 新增`：可视化表单新增 Wiki 页（写入 `005_LLMWiKi/wiki_pages/` 并同步脱敏词典）；
  - `💾 保存`：保存当前正在编辑的页面（替代旧版的「✎ 编辑」按钮——v1.8 起直接点右侧进入编辑、点保存落盘，更贴合 Obsidian 习惯）。

> 注：从 v1.6 起，**每次会议纪要成功生成后会自动重建 Wiki**（pipeline 末尾自动运行 `wiki_build.py`）；v1.7 起**导入手写纪要成功也会自动重建 Wiki**，所以常规使用下 Wiki 页会随会议/导入自动更新，无需手动点「重建 Wiki」；手动「重建 Wiki」按钮保留用于全量重组织或补充资料后主动刷新。若想临时跳过自动重建（如快速本地测试），运行前设环境变量 `MM_AUTO_WIKI=0` 即可。

---

## 纪要生成（分页①）

点击顶部 tab **「🎙 纪要生成」** 进入：

- **拖放区**：把会议音频文件拖入；或点 **「选择音频文件…」** 用文件选择器挑选。
- 点 **「开始生成」**：把音频拷入 `001_Audio/` 并跑完整 pipeline（转写→脱敏→精炼→自动重建 Wiki）。**「取消」** 可中止。
- **「📥 导入 RAG 文档」**（音频区下方）：选文件或文件夹（`.md/.txt/.csv/.doc/.docx/.eml/.pdf/.xls/.xlsx`），作为 RAG 素材导入——自动转 markdown、明文落 `003_Meeting_Minutes/imported_docs_<ts>/`、脱敏稿落 `005_LLMWiKi/knowledge_base/imported_docs_<ts>/` 并重建向量库；进度与成功/失败数显示在下方日志。
- **左右布局**：左栏（约 280px）= 拖放区 + 开始生成/取消 + 导入 RAG 文档 + 进度条 + 处理日志；右栏 = 纪要预览/编辑区（Obsidian 式编辑器）：点击任意处**所见即所得**进编辑、`[[双链]]` 可点、点 **「💾 保存」**（顶部工具栏）写回 `003_Meeting_Minutes/` 最新 `.md`。

## 设置（分页③）

点击顶部 tab **「⚙️ 设置」** 进入：

- **whisper.cpp 文件夹**：点「选择 whisper.cpp 文件夹…」定位到含 `build/bin/whisper-cli` 的目录；或点「下载并构建 whisper.cpp」自动 `git clone` + `cmake` 构建到 `/Users/weilu/whisper.cpp`。
- **语音模型**：下拉选择档位（tiny/base/small/medium/large-v3/turbo），本机已存在的 `ggml-*.bin` 会被自动识别并提示「使用此模型」；未下载的点「下载所选模型」（从 HuggingFace 拉取，仅本机、不上传）。
- **自定义系统提示词**：留空用内置默认（半导体/硬件供应链纪要专家）；填写后整体替换生成纪要的 system prompt，写入 `MM_LLM_SYSTEM_PROMPT`，下次生成生效。
- **恢复默认**：一键重置 whisper 路径、语音模型、自定义提示词（API Key / 供应商不受影响）。

---

## 目录结构（工作目录 baseDir 下）

| 目录 | 内容 |
|------|------|
| `001_Audio/` | 原始录音 + `Processed_Archive/` 归档 |
| `002_Transcript/` | 纯净转写 / 带时间戳稿 / 脱敏带说话人稿 |
| `003_Meeting_Minutes/` | ★ 终稿纪要（含真名，仅本地） |
| `004_Desensitize_Cache/` | 脱敏映射（还原钥匙，**勿删**） |
| `005_LLMWiKi/` | 个人 Wiki（页 / 知识库 / 参考资料） |
| `006_Runtime_Log/` | 运行日志 |

> ⚠️ 这套目录名是**唯一命名契约**（见 `SOP.md` §4），不要自行改名。

---

## 仓库布局

```
Meetinsight/
├── Smart Meeting Minutes/        # Xcode 工程（Swift/AppKit 原生界面）
│   └── Smart Meeting Minutes.xcodeproj
├── PythonEngine/                 # Python 处理引擎
│   ├── pipeline.py               # 主流程（转写→脱敏→精炼→Wiki）
│   ├── app/                      # 启动器 / 向导 / 打包脚本（build_app.sh）
│   ├── requirements.txt
│   ├── 001_Audio … 006_Runtime_Log/   # 本地工作数据（示例）
│   └── share_export.sh           # 隐私优先分享包导出
├── Swift_Python_Interface_Contract.md  # Swift↔Python 接口契约
├── SOP.md                        # 标准作业程序（构建/维护/坑位）
└── README.md                     # 本文
```

---

## 发布打包（给同事 / 公开版）

```bash
bash PythonEngine/app/build_app.sh
```
产物 `PythonEngine/Smart Minutes.app` 为**下载式、源码加密**包，首跑向导联网下载依赖，可直接拷给同事（Apple Silicon）。

---

## 文档索引

- **`SOP.md`** — 构建、目录契约、接口、发布、排障、变更记录（开发必读）
- **`Swift_Python_Interface_Contract.md`** — Swift 与 Python 引擎的 CLI/JSON 通信契约

---

## 常见问题 / 排障

| 现象 | 可能原因 / 处理 |
|------|----------------|
| 运行 pipeline 报「异常退出，退出码 1」+ stderr `No module named 'numpy'` | App 误用了无 numpy 的解释器（macOS 自带 `/usr/bin/python3`）。已修复为回退系统 Python 3.11 `/usr/local/bin/python3`（含 numpy）。若仍报错，确认未把 `PYTHON_EXECUTABLE` 误设为旧 python。详见 `SOP.md` §8。 |
| LLM 精炼报 `404 NOT_FOUND ... gemini-2.5-flash is no longer available to new users` | `gemini-2.5-flash` 等新用户已停用。已修复：默认模型改 `gemini-3.5-flash`，且 pipeline 会自动把旧模型名重映射到 3.x（无需手动清设置）；Swift 向导模型下拉框也已换成 3.x。仍报 404 可在模型设置/`MM_MODEL` 换 `gemini-3.6-flash` 等。详见 `SOP.md` §8。 |
| RAG 报 `RAG 检索失败: replace() argument 2 must be str, not None` | 脱敏时裸词条（实体字典中无 `->` 占位符的词）值为 None 导致 `replace(str, None)` 崩溃。已修复：相关替换循环加 `tag` 守护，裸词条跳过不崩溃。详见 `SOP.md` §8。 |
| 转写/精炼阶段空跑、无输入 | 工作目录（baseDir）未指向含 `001_Audio` 的目录；目录命名契约见 `SOP.md` §4。 |
| `xcodebuild` 卡签名 | 加 `CODE_SIGNING_ALLOWED=NO` 兜底（见上文方式 B）。 |
| LLM Wiki 分页「重建 Wiki」首次很慢 / 卡在「重建中」 | 首次需联网下载向量模型 `BAAI/bge-small-zh-v1.5`（≈90MB），属正常；下载完后续重建很快。若长期不动，检查网络或 `~/.cache/huggingface`。 |
| LLM Wiki 分页搜不到结果 | `wiki_query.py` 优先语义检索（需 bge 模型），缺模型时退化为关键词匹配；确认 `005_LLMWiKi/wiki_pages/` 已有页面（可先点「重建 Wiki」或跑一次纪要流程）。 |
| 运行 pipeline 报「异常退出，退出码 6」+ stderr 出现 `add_dense_scalar_long_long` / `Read-only bytes are being bound ...` | 这是 **sentence-transformers 在 Apple Silicon 的 MPS(Metal) 后端做 embedding 时的硬崩溃**，Python 无法捕获。已修复：所有 embedding 模型强制走 CPU（`device="cpu"`，bge-small 极小、CPU 足够快且稳定）。若仍报此错，确认未在其他地方直接 `SentenceTransformer(...)` 而绕过 `_load_embedding_model()`。详见 `SOP.md` §8。 |
| 不希望自动重建 Wiki（想手动控制 / 仅快速本地测试） | pipeline 默认在「会议纪要成功生成」和「导入手写纪要成功」后都自动跑 `wiki_build.py`。设环境变量 `MM_AUTO_WIKI=0` 即可关闭自动重建；手动「重建 Wiki」按钮与菜单项仍随时可用。 |
| App 一启动就闪退 / 控制台报 `no common ancestor` 或 `Unknown class ...ViewController` | v1.8 单窗口分页后曾因「约束激活时视图还没入树」+「残留旧 storyboard 主界面」连环崩溃。v1.9 已修复（按钮先入栈再激活约束、`sidebar/contentView` 先 `addSubview` 进 `body`、pbxproj 删 `NSMainStoryboardFile` + 删废弃 Main.storyboard）。若你是从旧构建升级，请**先清 DerivedData 缓存再 ⌘R**：`rm -rf ~/Library/Developer/Xcode/DerivedData/Meetinsight-*`（旧缓存里残留旧的 storyboardc 与旧类，不清会重复崩溃）。详见 `SOP.md` §8 ④⑤。 |
| 控制台一大堆 `linkd.autoShortcut` / `connection to service named com.apple.linkd.autoShortcut` | 若 **App 窗口正常出现**，则**与本 App 无关**，是 macOS 系统框架（Shortcuts/Intents 守护进程）在当前环境不可用时的噪声日志，不影响启动与功能，可忽略。但若**同时 App 窗口完全不出现**，则不是噪声问题，而是 `@main` 入口未可靠触发 `didFinishLaunching` 的 bug（v1.9.2 已用显式 `main.swift` 入口彻底修复）。 |
| App 启动后**窗口完全不出现**，控制台只有 `linkd.autoShortcut` 等系统噪声、无任何崩溃 | **不是崩溃、也不是旧 App**：根因是移除 storyboard 后 `@main` 合成入口未能可靠触发 `applicationDidFinishLaunching`，导致窗口永不创建（与 v1.9.1 曾怀疑的 Debug Dylib 无关——`ENABLE_DEBUG_DYLIB = NO` 已保留但单靠它修不好）。**v1.9.2 已根治**：改用显式 `main.swift` 入口（`app.delegate = AppDelegate(); app.run()`），保证 `didFinishLaunching` 必被调用；并装未捕获异常处理器把静默异常弹窗可见。若你本地是从旧构建升级，**先清 DerivedData 再 ⌘R**：`rm -rf ~/Library/Developer/Xcode/DerivedData/Meetinsight-*`；全新构建后窗口应正常弹出（首次会走四步安装向导）。详见 `SOP.md` §8 ⑥⑦。 |
| App 窗口出现后，**点选 Wiki 页/搜索时立刻崩溃**：控制台 `NSInvalidArgumentException: +[NSJSONSerialization dataWithJSONObject:options:error:]: Invalid top-level type in JSON write`、堆栈指向 `MarkdownEditorView.jsString` ← `renderNow` ← `load(markdown:)` ← `WikiViewController.selectPage` | **`NSJSONSerialization` 顶层只接受 Array/Dictionary，把 Swift `String` 直接传给它会 100% 抛此错**。v1.9.3 已修：`MarkdownEditorView.jsString()` 改用 `JSONEncoder().encode(s)`（正确把顶层 String 序列化为 `"escaped"`）。其他语言/工具链也有同类陷阱：要把 Swift String 注入 JS / JSON RPC 必须用 `JSONEncoder` 或手工 JSON 转义。详见 `SOP.md` §8 ⑧。 |
| 启动后 LLM Wiki 分页大量 `Unable to simultaneously satisfy constraints` 冲突警告（堆栈指向 `NSSplitView.height == NSStackView.height` 一类等高约束） | **`NSSplitView.heightAnchor == 父栈.heightAnchor` 是反模式**：父栈里装着 split 自己，等高数学上不可能满足，会持续触发 `Unable to simultaneously satisfy constraints` 并 break 兜底。v1.9.3 已修：`WikiViewController.setupUI()` 删除该等高约束，改靠 `split.setContentHuggingPriority(.defaultLow, for: .vertical/.horizontal)` + 栈的 `.fill` 分布让 split 吃掉剩余空间。详见 `SOP.md` §8 ⑨。 |
| 点击 `[[双链]]` 跳到不存在的页并报错（如点 `[[ADI (亚德诺) \|ADI]]`） | **双链别名 `[[name\|alias]]` 被整段当跳转目标**。v1.9.4 已修：内嵌 JS `inline()` 按 `\|` 拆，`target = 左侧`、`display = 右侧`，只把左侧写进 `data-name`；`htmlToMd()` 回写也按同样规则。详见 `SOP.md` §8。 |
| 想要「所见即所得」实时渲染编辑，但点一下预览就变成一个新编辑窗 | v2.2 起编辑器底层换成离线内置 **TipTap 引擎**（ProseMirror 系）：默认 **Typora 式真所见即所得**，Markdown 源码符号不显示、边打字边渲染、`[[双链]]` 自动完成/缺失页红字/悬浮预览；Vditor 作为可回退引擎保留（见 `SOP.md` §8）。 |
| 想自主把已有会议记录/文档加进 RAG 知识库 | 纪要生成分页有「📥 导入 RAG 文档」按钮：选文件或文件夹（支持 `.md/.txt/.csv/.doc/.docx/.eml/.pdf/.xls/.xlsx`），自动经 pandoc/原生转 markdown，**明文**落 `003_Meeting_Minutes/imported_docs_<ts>/`、**脱敏稿**落 `005_LLMWiKi/knowledge_base/imported_docs_<ts>/` 并重建向量库。运行日志会显示进度与成功/失败数。详见 `SOP.md` §9 v1.9.4。 |
| 设置页系统提示词是空的，想看/改 pipeline.py 默认提示词 | v1.9.4 起设置页**默认就显示 pipeline.py 的默认提示词**（`AppConfig.defaultSystemPrompt` 单一真相源 = `PythonEngine/app/default_system_prompt.txt`，Bundle 资源优先、源路径兜底），可直接编辑并保存为自定义提示词。详见 `SOP.md` §9 v1.9.4。 |
| 想让 App 窗口记住上次大小 / 自适应 | v1.9.4 主窗口默认 `1280×820`（最小 `1100×720`），按屏幕可视区居中；拖动改变大小后会经 `didResizeNotification` 写入 `MM_WINDOW_WIDTH`/`MM_WINDOW_HEIGHT`，下次启动沿用。详见 `SOP.md` §8。 |
| 控制台 `linkd.autoShortcut` 等系统噪声想彻底清掉 | 这些是 macOS 系统框架日志，App 代码无法消除；v1.9.4 提供可控开关——启动 App 前设 `MM_QUIET_STDERR=1`（如 `MM_QUIET_STDERR=1 open "/Users/weilu/Applications/Smart Meeting Minutes.app"`），`main.swift` 会在启动期把 stderr 重定向到 `/dev/null`；调试时设 `0` 或不设即可恢复。详见 `SOP.md` §8。 |
| 导入 RAG 文档后「RAG 向量库已重建」但搜不到导入的内容 / 日志报 `502 Bad Gateway` | v1.9.4 初版有两处隐患：① embedding 模型 `bge-small-zh-v1.5` 在**有 `HTTPS_PROXY` 的环境**下会向 HuggingFace Hub 校验 revision 被代理劫持成 `502`，导致 RAG 重建失败；② 导入稿落在 `knowledge_base/imported_docs_<ts>/` 子目录、而索引扫描漏扫该目录，且重建时漏传 `content` 字段。v1.9.5 已修：embedding 改为**离线优先加载**（`local_files_only=True`，权重已在本地、零网络零 502），并让索引扫描覆盖 `imported_docs_*` 子目录、补 `content` 字段。Route A 的 .app 直接读 `PythonEngine/pipeline.py` 源路径，**无需重装 app** 即可生效。已验证导入 2 样本后向量库真正写入 2 个 chunk。详见 `SOP.md` §8 / §9 v1.9.5。 |

> 更多坑位与根因见 **`SOP.md` §8**。

---

## 许可与备注

- 个人工具，本地优先；`003_Meeting_Minutes` 与 `004_Desensitize_Cache` 含真名/还原钥匙，**绝不外传**。
- 分享代码用 `PythonEngine/share_export.sh --profile tool|knowledge`，已自动剔除所有 PII。
