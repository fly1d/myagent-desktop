# MyAgent

自己维护的 macOS 桌面 Agent，源码公开在 [fly1d/myagent-desktop](https://github.com/fly1d/myagent-desktop)。原生 SwiftUI 客户端负责交互，独立 Rust 后端负责模型请求、工具执行与 SQLite 数据。运行时无需安装 Codex、Qoder、Node.js。

当前面向个人本机使用，支持 DeepSeek、OpenAI 和提供 Chat Completions 工具调用的兼容服务。远端模型凭据保存在 macOS 钥匙串；本机兼容服务可明确选择无密钥连接。这是开发中的早期版本；真实服务与具体模型的可用性需要另行验证。

## 使用

1. 首次打开应用，选择远程或本机服务，填写 API 地址。远端服务填写 API Key；本机服务可选择“无密钥（仅本机）”。
2. 模型名称可先留空，点击“测试并获取模型”。只有一个模型时自动选中；多个模型时从列表选择，再“保存并使用”。测试实际请求模型列表；模型执行和工具能力由任务验证。
3. 选择项目目录，输入任务；按 `⌘Return` 发送，Return 换行。
4. 查看实际文件、浏览器截图和执行活动。方案卡展示交付物、已有文件预览、办公影响和下一步。
5. Agent 读写项目、请求执行命令，并可使用独立后台浏览器和经授权的有限桌面 AX 操作。
6. 验收回执记录实际文件及 Agent 提供的检查依据；没有有效回执的轮次显示“验收待确认”，可继续核验。

缺少必要信息时，Agent 可在原生窗口提问。建议答案只填入编辑器，你可以自由修改，明确提交后才继续；“暂不回答”会返回取消。问题与回答保留在任务对话中。失败或停止的任务可点击“继续此任务”，沿用上下文并保留未发送草稿。

使用本机模式前，先在模型服务中准备支持工具调用的模型并启动兼容接口。例如已启动的 Ollama 默认可连接 `http://127.0.0.1:11434/v1`；参见其[兼容接口](https://docs.ollama.com/api/openai-compatibility)与[鉴权说明](https://docs.ollama.com/api/authentication)。无密钥只允许本机回环地址，不读取或发送钥匙串中的密钥。是否离线取决于所连接的服务和模型。设置中断开连接后，重启会保持断开；原地址和模型仍可查看。

`⌘N` 新建，`⌘O` 选择项目，`⌘.` 停止。停止取消模型请求、待执行工具和本轮控制授权。执行中可以浏览其他任务，草稿按任务保留。

## 构建和测试

需要 macOS 14+、Swift 6 工具链（完整 Xcode 或 Command Line Tools）、Rust stable / cargo。运行打包后的应用不需要开发工具。

```sh
./scripts/build-app.sh
open dist/MyAgent.app
```

产物 `dist/MyAgent.app` 包含本项目的原生客户端、Rust 后端及许可文件，采用本地 ad-hoc 签名。目前按本机架构构建；Developer ID 签名、公证和自动更新尚未提供。

```sh
./scripts/test.sh
```

脚本执行 Rust 测试和 Swift Testing，当前共 76 项（地址边界和轮次对账含参数化场景）。整链路测试从生产客户端发起，经真实 Rust 后端发现模型、提问、写文件、读回、生成验收回执并重启恢复；模型及浏览器使用本机 fixture。钥匙串使用独立测试 service，验证后删除测试项，不读取生产凭据。真实服务与具体模型仍需单独实测。

0.5.0 增加本机无密钥连接和先发现后选择模型的配置流程。无密钥连接可保存、重开恢复和持久断开；换地址会清除输入中的旧密钥与模型结果。显式连接测试启动后端时，也不会读取前一个服务的密钥。原有问答、任务恢复、审批与验收流程继续保留。

## 本地数据

```text
~/Library/Application Support/MyAgent/
  engine/myagent.sqlite      SQLite：线程、消息、轮次、事件、公开配置
  state.json                 客户端恢复快照，无模型密钥
  Workspace/                 默认项目目录
```

API Key 位于钥匙串服务 `dev.myagent.desktop.providers`，后端通过私有 stdin 管道取得，只留内存。无密钥模式只保存公开地址、模型与鉴权方式。客户端与后端使用 JSONL 子进程通信，不启动局域网 HTTP 服务。项目的 `deliverables/` 保存实际 PNG 和 `receipt-*.json`。应用核对回执文件存在性，业务结论仍需按任务复核。

## 扩展位置

| 模块 | 文件 |
| --- | --- |
| 模型协议、地址与 SSE | `backend/src/provider.rs` |
| 工具循环、文件、命令 | `backend/src/runner.rs` |
| SQLite 与迁移 | `backend/src/store.rs` |
| 后端 RPC | `backend/src/lib.rs`、`main.rs` |
| 原生编排与授权 | `Sources/MyAgent/AppModel.swift` |
| 主界面、设置、首次配置 | `WorkspaceView.swift`、`PreferencesView.swift`、`ConnectionSetupView.swift` |
| 后台浏览器与 AX | `NativeTools.swift` |

其他模型协议可增加适配器；多用户和远程同步可以在本地执行器外增加身份及权限层。当前没有用户注册、云同步、全天候调度或通用坐标控制。

源码采用 [MIT](LICENSE)，依赖见 [第三方许可](THIRD_PARTY_NOTICES.md)，维护说明见 [架构](docs/ARCHITECTURE.md)。
