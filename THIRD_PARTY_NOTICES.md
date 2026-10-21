# 第三方组件

本项目自有 Swift、Rust、脚本与文档采用 [MIT](LICENSE)。依赖按各自许可证使用，并未重新许可。

本版本运行自己的 `myagent-backend`。原生客户端依赖 macOS 的 SwiftUI、AppKit、WebKit、Security 和 ApplicationServices 系统框架。

Rust 后端直接依赖 Tokio、Reqwest、Rusqlite（含 SQLite）、Serde、serde_json、futures-util、tokio-util、url、uuid 和 anyhow；完整直接及传递依赖固定在 `backend/Cargo.lock`。具体许可证以各组件文件为准。

构建脚本从 Cargo 解析的实际依赖收集许可证与通知，放入：

```text
MyAgent.app/Contents/Resources/licenses/rust/INDEX.md
MyAgent.app/Contents/Resources/licenses/rust/<package>-<version>/
```

这些文件随应用分发。升级依赖时应更新 Cargo.lock、运行测试，并重新生成许可目录。
