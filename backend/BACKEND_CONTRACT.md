# MyAgent local backend contract

The backend is an independent Rust JSONL process. It accepts the existing launch arguments but does not invoke Codex. `MYAGENT_HOME/myagent.sqlite` (with `CODEX_HOME` accepted only as a legacy transport fallback) holds application state; API keys remain in process memory and the native client's Keychain only.

## Provider RPCs

- `provider/configure`: `{provider, baseUrl, model, apiKey}`. All are strings. `baseUrl` is an OpenAI-compatible API root, normally ending in `/v1`. Cloud providers require a nonempty key; a local loopback development endpoint may omit it. Persists only `provider`, `baseUrl` and `model`, returns `{configured:true,configuration:{provider,baseUrl,model}}`.
- `provider/test`: same three fields, tests the supplied configuration without saving it. Returns the provider module's JSON result or a JSON-RPC error. Never returns or logs the key.
- `backend/health`: reports backend identity, SQLite schema, configured state, and version.
- `account/read`: returns `{account:{type:"apiKey",provider,email}|null, requiresOpenaiAuth:true}`. This is model-provider configuration, not a product account system.
- `model/list`: returns the configured model in the existing `{data,nextCursor:null}` shape.

## Shared Rust API

`provider.rs` owns `ProviderConfig` (`Clone`, `Deserialize`, `#[serde(rename_all="camelCase")]`) with public `provider`, `base_url`, `model: String`, `api_key: Option<String>`. It exports `pub async fn test_provider(config: &ProviderConfig) -> anyhow::Result<serde_json::Value>`.

`runner.rs` exports `pub async fn run_turn(ctx: crate::TurnContext) -> anyhow::Result<()>`. The wrapper in `main` owns terminal turn status and `turn/completed`; runner emits item lifecycle and text delta events.

`TurnContext` exposes:

- `pub state: Arc<State>`
- `pub thread: ThreadRecord` (`id`, `cwd`, `developer_instructions`, `dynamic_tools: Vec<Value>`, `model: Option<String>`)
- `pub turn_id: String`
- `pub provider: ProviderConfig` (ephemeral secret; never serialize)
- `pub messages: Vec<Value>` (persisted Chat Completions messages including the newly submitted user message; prepend developer instructions in runner)
- `pub cancel: tokio_util::sync::CancellationToken`
- `ctx.emit(method: &str, params: Value) -> anyhow::Result<()>` adds threadId/turnId if absent, saves an event, then sends a JSONL notification.
- `ctx.record_message(message: &Value) -> anyhow::Result<()>` persists a canonical Chat Completions assistant/tool message.
- `ctx.call_native(tool: &str, arguments: Value) -> anyhow::Result<Value>` emits `item/tool/call`, waits for the native client's same-ID result, and observes cancellation. The returned Value is `{success,contentItems}`.
- `ctx.request_native(method: &str, params: Value) -> anyhow::Result<Value>` supports command/file approvals with the same reply and cancellation mechanism.
- `ctx.is_cancelled() -> bool`.

`State.store` is `std::sync::Mutex<Store>`. Keep its guards short and never across await. Use `ctx` helpers rather than accessing SQLite from runner. `State` owns the JSONL writer sender and native-response pending map. Reading stdin continues while RPC handlers and turns execute.

`app/state/read` returns `{state,revision}`. `app/state/write {state,revision}` persists native-client state and rejects decreasing revisions, equal-revision conflicting writes, and structured secret fields. `provider/read` returns persisted public configuration and whether an in-memory credential is configured.

## Turn lifecycle

`thread/start` persists cwd/developerInstructions/dynamicTools/model; `thread/resume` loads its own SQLite thread. `turn/start {threadId,input:[{type:"text",text}]}` saves user input, rejects a second active turn on the same thread, returns `{turn:{id,status:"inProgress",items:[]}}`, then starts runner. The main wrapper emits `turn/started` and, on completion, `turn/completed {threadId,turn:{id,status,items:[],error?}}`. Status is completed, interrupted, or failed. Interrupt and stdin EOF signal cancellation. Native request IDs are unique strings and are independent of callId/itemId.

Runner's model-facing dynamic tools use the thread's `type:function/name/description/inputSchema` definitions converted to Chat Completions tools. Application tools such as present_choices/browser/desktop/complete_task route via `ctx.call_native`; local file/shell tools execute in runner with explicit workspace confinement and cancellation.
