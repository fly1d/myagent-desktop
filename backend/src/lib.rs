pub mod provider;
pub mod runner;
pub mod store;

use anyhow::{anyhow, bail, Context, Result};
use futures_util::FutureExt;
use provider::ProviderConfig;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use store::{Store, ThreadRecord};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub struct ActiveTurn {
    pub id: String,
    pub cancel: CancellationToken,
}

pub struct State {
    pub store: Mutex<Store>,
    pub provider: Mutex<Option<ProviderConfig>>,
    pub active: Mutex<HashMap<String, ActiveTurn>>,
    outgoing: mpsc::UnboundedSender<Value>,
    pending: Mutex<HashMap<String, oneshot::Sender<Value>>>,
    closed: AtomicBool,
}

impl State {
    pub fn new(store: Store, outgoing: mpsc::UnboundedSender<Value>) -> Self {
        Self {
            store: Mutex::new(store),
            provider: Mutex::new(None),
            active: Mutex::new(HashMap::new()),
            outgoing,
            pending: Mutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
        }
    }

    pub fn send(&self, message: Value) -> Result<()> {
        if self.closed.load(Ordering::Acquire) {
            bail!("Native client disconnected");
        }
        self.outgoing
            .send(message)
            .map_err(|_| anyhow!("Native client disconnected"))
    }

    pub fn notify(&self, method: &str, params: Value) -> Result<()> {
        self.store
            .lock()
            .map_err(|_| anyhow!("Database lock failed"))?
            .add_event(method, &params)?;
        self.send(json!({"method":method,"params":params}))
    }

    pub fn receive_reply(&self, message: Value) {
        if let Some(id) = message["id"].as_str() {
            if let Ok(mut pending) = self.pending.lock() {
                if let Some(sender) = pending.remove(id) {
                    let _ = sender.send(message);
                }
            }
        }
    }

    pub fn cancel_all(&self) {
        self.closed.store(true, Ordering::Release);
        self.cancel_turns();
    }

    fn cancel_turns(&self) {
        if let Ok(active) = self.active.lock() {
            for turn in active.values() {
                turn.cancel.cancel();
            }
        }
        if let Ok(mut pending) = self.pending.lock() {
            pending.clear();
        }
    }
}

struct PendingRequest {
    state: Arc<State>,
    id: String,
}
impl Drop for PendingRequest {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.state.pending.lock() {
            pending.remove(&self.id);
        }
    }
}

pub struct TurnContext {
    pub state: Arc<State>,
    pub thread: ThreadRecord,
    pub turn_id: String,
    pub provider: ProviderConfig,
    pub messages: Vec<Value>,
    pub cancel: CancellationToken,
}

impl TurnContext {
    pub fn is_cancelled(&self) -> bool {
        self.cancel.is_cancelled()
    }

    pub fn emit(&self, method: &str, mut params: Value) -> Result<()> {
        let fields = params
            .as_object_mut()
            .context("Event params must be an object")?;
        fields
            .entry("threadId")
            .or_insert_with(|| json!(self.thread.id));
        fields
            .entry("turnId")
            .or_insert_with(|| json!(self.turn_id));
        self.state.notify(method, params)
    }

    pub fn record_message(&self, message: &Value) -> Result<()> {
        self.state
            .store
            .lock()
            .map_err(|_| anyhow!("Database lock failed"))?
            .add_message(&self.thread.id, &self.turn_id, message)
    }

    pub async fn call_native(&self, tool: &str, arguments: Value) -> Result<Value> {
        self.request_native(
            "item/tool/call",
            json!({"tool":tool,"arguments":arguments,"callId":Uuid::new_v4().to_string()}),
        )
        .await
    }

    pub async fn request_native(&self, method: &str, mut params: Value) -> Result<Value> {
        if self.is_cancelled() {
            bail!("Turn interrupted");
        }
        let fields = params
            .as_object_mut()
            .context("Native request params must be an object")?;
        fields
            .entry("threadId")
            .or_insert_with(|| json!(self.thread.id));
        fields
            .entry("turnId")
            .or_insert_with(|| json!(self.turn_id));
        let id = format!("native-{}", Uuid::new_v4());
        let (sender, receiver) = oneshot::channel();
        self.state
            .pending
            .lock()
            .map_err(|_| anyhow!("Request lock failed"))?
            .insert(id.clone(), sender);
        // The outer turn cancellation can drop this entire future before its
        // select branch runs. A guard also handles that drop path.
        let _pending = PendingRequest {
            state: self.state.clone(),
            id: id.clone(),
        };
        if let Err(error) = self
            .state
            .send(json!({"id":id,"method":method,"params":params}))
        {
            return Err(error);
        }
        let reply = tokio::select! {
            biased;
            _=self.cancel.cancelled()=>Err(anyhow!("Turn interrupted")),
            result=receiver=>result.map_err(|_|anyhow!("Native client disconnected")),
            _=tokio::time::sleep(std::time::Duration::from_secs(900))=>Err(anyhow!("Native request timed out")),
        };
        let reply = reply?;
        if let Some(error) = reply.get("error") {
            bail!(
                "{}",
                error["message"].as_str().unwrap_or("Native request failed")
            );
        }
        reply
            .get("result")
            .cloned()
            .context("Native response has no result")
    }
}

pub async fn dispatch(state: Arc<State>, method: &str, params: Value) -> Result<Value> {
    if state.closed.load(Ordering::Acquire) {
        bail!("Native client disconnected");
    }
    match method {
        "initialize" => Ok(
            json!({"userAgent":format!("MyAgent Local Backend/{}",env!("CARGO_PKG_VERSION")),"platformFamily":"unix","platformOs":std::env::consts::OS}),
        ),
        "backend/health" => Ok(
            json!({"backend":"myagent-rust","version":env!("CARGO_PKG_VERSION"),"database":"sqlite","schemaVersion":store::SCHEMA_VERSION,"configured":state.provider.lock().unwrap().is_some()}),
        ),
        "provider/test" => {
            let config: ProviderConfig =
                serde_json::from_value(params).context("Invalid provider configuration")?;
            provider::test_provider(&config).await
        }
        "provider/configure" => {
            let config: ProviderConfig =
                serde_json::from_value(params).context("Invalid provider configuration")?;
            // Constructing a provider validates URL and key without making an inference request.
            let _ = provider::Provider::new(config.clone())?;
            let auth_mode = config.auth_mode();
            let public = json!({"provider":config.provider,"baseUrl":config.base_url,"model":config.model,"authMode":auth_mode});
            state
                .store
                .lock()
                .unwrap()
                .put_config("provider", &public)?;
            *state.provider.lock().unwrap() = Some(config);
            state.notify(
                "account/updated",
                json!({"authMode":auth_mode,"planType":null}),
            )?;
            Ok(json!({"configured":true,"configuration":public}))
        }
        "provider/read" => {
            let config = state.store.lock().unwrap().config("provider")?;
            Ok(
                json!({"configuration":config,"configured":state.provider.lock().unwrap().is_some()}),
            )
        }
        "account/read" => {
            let provider = state.provider.lock().unwrap();
            let account = provider.as_ref().map(|p| {
                let display_name = format!("{} · {}",p.provider,p.model);
                if p.uses_api_key() {
                    json!({"type":"apiKey","provider":p.provider,"email":display_name,"displayName":display_name})
                } else {
                    json!({"type":"local","provider":p.provider,"displayName":display_name})
                }
            });
            Ok(
                json!({"account":account,"authMode":provider.as_ref().map(ProviderConfig::auth_mode),"requiresOpenaiAuth":provider.as_ref().is_none_or(ProviderConfig::uses_api_key)}),
            )
        }
        "account/logout" => {
            *state.provider.lock().unwrap() = None;
            state.cancel_turns();
            state.notify("account/updated", json!({"authMode":null,"planType":null}))?;
            Ok(json!({}))
        }
        "model/list" => {
            let provider = state.provider.lock().unwrap();
            let data=provider.as_ref().map(|p|vec![json!({"id":p.model,"model":p.model,"displayName":p.model,"isDefault":true,"hidden":false,"description":"Configured provider model","defaultReasoningEffort":"medium","supportedReasoningEfforts":[]})]).unwrap_or_default();
            Ok(json!({"data":data,"nextCursor":null}))
        }
        "app/state/read" => Ok(state
            .store
            .lock()
            .unwrap()
            .config("app_state")?
            .unwrap_or(json!({"state":null,"revision":0}))),
        "app/state/write" => {
            let revision = params["revision"]
                .as_i64()
                .context("revision must be an integer")?;
            let value = params.get("state").cloned().context("state is required")?;
            state
                .store
                .lock()
                .unwrap()
                .write_app_state(value, revision)?;
            Ok(json!({"revision":revision,"saved":true}))
        }
        "thread/start" => {
            let cwd = params["cwd"].as_str().context("cwd is required")?;
            let cwd = std::fs::canonicalize(cwd).context("Project directory does not exist")?;
            if !cwd.is_dir() {
                bail!("Project path is not a directory");
            }
            let tools = params["dynamicTools"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let thread = state.store.lock().unwrap().create_thread(
                cwd.display().to_string(),
                params["developerInstructions"]
                    .as_str()
                    .unwrap_or("")
                    .into(),
                tools,
                params["model"].as_str().map(String::from),
            )?;
            let response = thread_response(&state, &thread)?;
            state.notify("thread/started", json!({"thread":response["thread"]}))?;
            Ok(response)
        }
        "thread/resume" => {
            let id = params["threadId"]
                .as_str()
                .context("threadId is required")?;
            let mut thread = state.store.lock().unwrap().thread(id)?;
            if let Some(model) = params["model"].as_str() {
                thread.model = Some(model.into());
            }
            if let Some(instructions) = params["developerInstructions"].as_str() {
                thread.developer_instructions = instructions.into();
            }
            if let Some(tools) = params.get("dynamicTools") {
                thread.dynamic_tools = tools
                    .as_array()
                    .context("dynamicTools must be an array")?
                    .clone();
            }
            state.store.lock().unwrap().update_thread(&thread)?;
            thread_response(&state, &thread)
        }
        "turn/start" => start_turn(state, params),
        "turn/interrupt" => {
            let thread = params["threadId"]
                .as_str()
                .context("threadId is required")?;
            let turn = params["turnId"].as_str().context("turnId is required")?;
            if let Some(active) = state.active.lock().unwrap().get(thread) {
                if active.id == turn {
                    active.cancel.cancel();
                }
            }
            Ok(json!({}))
        }
        _ => bail!("Unsupported method: {method}"),
    }
}

fn thread_response(state: &State, thread: &ThreadRecord) -> Result<Value> {
    let turns = state.store.lock().unwrap().turns(&thread.id)?;
    let model = thread.model.clone().or_else(|| {
        state
            .provider
            .lock()
            .unwrap()
            .as_ref()
            .map(|p| p.model.clone())
    });
    Ok(
        json!({"thread":{"id":thread.id,"cwd":thread.cwd,"turns":turns,"model":model},"model":model,"modelProvider":"openai-compatible","cwd":thread.cwd,"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":{"type":"dangerFullAccess"}}),
    )
}

fn start_turn(state: Arc<State>, params: Value) -> Result<Value> {
    let thread_id = params["threadId"]
        .as_str()
        .context("threadId is required")?;
    let mut thread = state.store.lock().unwrap().thread(thread_id)?;
    let mut provider = state
        .provider
        .lock()
        .unwrap()
        .clone()
        .context("Configure an API provider and key first")?;
    if let Some(model) = thread.model.as_ref() {
        provider.model = model.clone();
    }
    if let Some(model) = params["model"].as_str() {
        provider.model = model.to_owned();
        thread.model = Some(model.to_owned());
    }
    provider.validate()?;
    let text = params["input"]
        .as_array()
        .context("input must be an array")?
        .iter()
        .filter(|i| i["type"] == "text")
        .filter_map(|i| i["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    if text.trim().is_empty() {
        bail!("A nonempty text input is required");
    }
    let turn_id = match params.get("clientTurnId") {
        Some(value) => Uuid::parse_str(value.as_str().context("clientTurnId must be a UUID")?)
            .context("clientTurnId must be a UUID")?
            .to_string(),
        None => Uuid::new_v4().to_string(),
    };
    let cancel = CancellationToken::new();
    {
        let mut active = state.active.lock().unwrap();
        if state.closed.load(Ordering::Acquire) {
            bail!("Native client disconnected");
        }
        if active.contains_key(thread_id) {
            bail!("This thread already has an active turn");
        }
        active.insert(
            thread_id.into(),
            ActiveTurn {
                id: turn_id.clone(),
                cancel: cancel.clone(),
            },
        );
    }
    let prepared = (|| -> Result<Vec<Value>> {
        let mut store = state.store.lock().unwrap();
        store.begin_turn(
            thread_id,
            &turn_id,
            &json!({"role":"user","content":text}),
            params["model"].as_str(),
        )
    })();
    let messages = match prepared {
        Ok(m) => m,
        Err(error) => {
            // begin_turn is atomic. A conflicting client ID must not mutate
            // the previously committed turn that owns that ID.
            state.active.lock().unwrap().remove(thread_id);
            return Err(error);
        }
    };
    let ctx = TurnContext {
        state: state.clone(),
        thread,
        turn_id: turn_id.clone(),
        provider,
        messages,
        cancel: cancel.clone(),
    };
    let running = json!({"id":turn_id,"status":"inProgress","items":[]});
    if let Err(error) = state.notify("turn/started", json!({"threadId":thread_id,"turn":running})) {
        let _ = state.store.lock().unwrap().finish_turn(
            &turn_id,
            "failed",
            Some("Unable to publish turn start"),
        );
        state.active.lock().unwrap().remove(thread_id);
        return Err(error);
    }
    let thread_id = thread_id.to_owned();
    tokio::spawn(async move {
        let run = std::panic::AssertUnwindSafe(runner::run_turn(ctx)).catch_unwind();
        let result = tokio::select! {biased;_=cancel.cancelled()=>Err(anyhow!("Turn interrupted")),result=run=>result.unwrap_or_else(|_|Err(anyhow!("Agent execution terminated unexpectedly")))};
        let mut status = if cancel.is_cancelled() {
            "interrupted"
        } else if result.is_ok() {
            "completed"
        } else {
            "failed"
        };
        let mut error = result.err().map(|e| e.to_string());
        if let Ok(mut store) = state.store.lock() {
            if store
                .finish_turn(&turn_id, status, error.as_deref())
                .is_err()
            {
                status = "failed";
                error = Some("Unable to save the turn result".into());
            }
        }
        state.active.lock().unwrap().remove(&thread_id);
        let _=state.notify("turn/completed",json!({"threadId":thread_id,"turn":{"id":turn_id,"status":status,"items":[],"error":error.map(|message|json!({"message":message}))}}));
    });
    Ok(json!({"turn":running}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn local_model_discovery_is_not_configuration_or_inference_authorization() -> Result<()> {
        use tokio::{
            io::{AsyncReadExt, AsyncWriteExt},
            net::TcpListener,
        };
        let home = std::env::temp_dir().join(format!("myagent-local-discovery-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&home)?;
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let address = format!("http://{}/v1", listener.local_addr()?);
        let fixture = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0u8; 1024];
            while !request.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                let length = socket.read(&mut buffer).await.unwrap();
                assert!(length > 0);
                request.extend_from_slice(&buffer[..length]);
                assert!(request.len() < 16_384);
            }
            let body = json!({"data":[{"id":"qwen3:8b"}]}).to_string();
            socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await.unwrap();
            String::from_utf8(request).unwrap()
        });
        let store = Store::open(&home.join("test.sqlite"))?;
        let (outgoing, mut events) = mpsc::unbounded_channel();
        let state = Arc::new(State::new(store, outgoing));
        let connection = json!({"provider":"local","baseUrl":address,"model":""});
        let discovery = dispatch(state.clone(), "provider/test", connection.clone()).await?;
        assert_eq!(discovery["models"], json!([{"id":"qwen3:8b"}]));
        let request = fixture.await?;
        assert!(request.starts_with("GET /v1/models "));
        assert!(!request.to_lowercase().contains("authorization:"));
        assert!(state.provider.lock().unwrap().is_none());
        assert!(state.store.lock().unwrap().config("provider")?.is_none());
        assert!(dispatch(state.clone(), "provider/configure", connection)
            .await
            .is_err());
        assert!(state.provider.lock().unwrap().is_none());

        let configured = dispatch(
            state.clone(),
            "provider/configure",
            json!({"provider":"local","baseUrl":address,"model":"qwen3:8b"}),
        )
        .await?;
        assert_eq!(configured["configuration"]["authMode"], "none");
        let event = events.recv().await.context("configuration event missing")?;
        assert_eq!(event["params"]["authMode"], "none");
        let account = dispatch(state.clone(), "account/read", json!({})).await?;
        assert_eq!(account["account"]["type"], "local");
        assert!(account["account"].get("email").is_none());
        assert_eq!(account["authMode"], "none");
        assert_eq!(account["requiresOpenaiAuth"], false);
        let saved = state.store.lock().unwrap().config("provider")?.unwrap();
        assert_eq!(saved, configured["configuration"]);
        assert!(saved.get("apiKey").is_none());
        let thread = dispatch(state.clone(), "thread/start", json!({"cwd":home})).await?["thread"]
            ["id"]
            .as_str()
            .unwrap()
            .to_owned();
        for model in ["", "   ", "bad\nmodel"] {
            assert!(dispatch(state.clone(),"turn/start",json!({"threadId":thread,"model":model,"input":[{"type":"text","text":"must select a real model"}]})).await.is_err());
        }
        assert!(state.active.lock().unwrap().is_empty());
        assert!(state.store.lock().unwrap().turns(&thread)?.is_empty());
        assert_eq!(
            state.provider.lock().unwrap().as_ref().unwrap().model,
            "qwen3:8b"
        );

        let keyed = dispatch(state.clone(),"provider/configure",json!({"provider":"custom","baseUrl":address,"model":"qwen3:8b","apiKey":"fixture-never-persist-key"})).await?;
        assert_eq!(keyed["configuration"]["authMode"], "apikey");
        let account = dispatch(state.clone(), "account/read", json!({})).await?;
        assert_eq!(account["account"]["type"], "apiKey");
        assert_eq!(account["authMode"], "apikey");
        let saved = state
            .store
            .lock()
            .unwrap()
            .config("provider")?
            .unwrap()
            .to_string();
        assert!(!saved.contains("fixture-never-persist-key"));
        assert!(!saved.contains("apiKey"));
        drop(state);
        std::fs::remove_dir_all(home)?;
        Ok(())
    }

    #[tokio::test]
    async fn native_reply_routes_by_id_and_cancellation_releases_pending() -> Result<()> {
        let home = std::env::temp_dir().join(format!("myagent-native-rpc-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&home)?;
        let mut store = Store::open(&home.join("test.sqlite"))?;
        let thread =
            store.create_thread(home.display().to_string(), String::new(), vec![], None)?;
        let (outgoing, mut incoming) = mpsc::unbounded_channel();
        let state = Arc::new(State::new(store, outgoing));
        let cancel = CancellationToken::new();
        let context = TurnContext {
            state: state.clone(),
            thread: thread.clone(),
            turn_id: "turn".into(),
            provider: ProviderConfig {
                provider: "custom".into(),
                base_url: "http://127.0.0.1/v1".into(),
                model: "fixture".into(),
                api_key: None,
            },
            messages: vec![],
            cancel: cancel.clone(),
        };
        let request = tokio::spawn(async move {
            context
                .request_native(
                    "item/commandExecution/requestApproval",
                    json!({"itemId":"item","command":"fixture only"}),
                )
                .await
        });
        let envelope = incoming.recv().await.context("No native request")?;
        assert_eq!(envelope["params"]["threadId"], thread.id);
        state.receive_reply(json!({"id":envelope["id"],"result":{"decision":"accept"}}));
        assert_eq!(request.await??["decision"], "accept");
        assert!(state.pending.lock().unwrap().is_empty());

        let context = TurnContext {
            state: state.clone(),
            thread: thread.clone(),
            turn_id: "turn-2".into(),
            provider: ProviderConfig {
                provider: "custom".into(),
                base_url: "http://127.0.0.1/v1".into(),
                model: "fixture".into(),
                api_key: None,
            },
            messages: vec![],
            cancel: cancel.clone(),
        };
        let request = tokio::spawn(async move {
            context
                .call_native("present_choices", json!({"title":"fixture"}))
                .await
        });
        let _ = incoming.recv().await.context("No native request")?;
        // Aborting the outer turn drops the future rather than polling its
        // cancellation select branch. This used to leave the pending entry.
        request.abort();
        assert!(request.await.unwrap_err().is_cancelled());
        assert!(state.pending.lock().unwrap().is_empty());
        cancel.cancel();
        drop(state);
        std::fs::remove_dir_all(home)?;
        Ok(())
    }

    #[tokio::test]
    async fn failed_start_notification_releases_thread_and_marks_failed() -> Result<()> {
        let home = std::env::temp_dir().join(format!("myagent-start-failure-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&home)?;
        let mut store = Store::open(&home.join("test.sqlite"))?;
        let thread =
            store.create_thread(home.display().to_string(), String::new(), vec![], None)?;
        let (sender, receiver) = mpsc::unbounded_channel();
        drop(receiver);
        let state = Arc::new(State::new(store, sender));
        *state.provider.lock().unwrap() = Some(ProviderConfig {
            provider: "custom".into(),
            base_url: "http://127.0.0.1/v1".into(),
            model: "fixture".into(),
            api_key: None,
        });
        assert!(dispatch(
            state.clone(),
            "turn/start",
            json!({"threadId":thread.id,"input":[{"type":"text","text":"hello"}]})
        )
        .await
        .is_err());
        assert!(state.active.lock().unwrap().is_empty());
        assert_eq!(
            state.store.lock().unwrap().turns(&thread.id)?[0]["status"],
            "failed"
        );
        drop(state);
        std::fs::remove_dir_all(home)?;
        Ok(())
    }

    #[tokio::test]
    async fn resume_refreshes_native_tools_and_duplicate_client_id_preserves_history() -> Result<()>
    {
        let home = std::env::temp_dir().join(format!("myagent-resume-tools-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&home)?;
        let mut store = Store::open(&home.join("test.sqlite"))?;
        let thread = store.create_thread(home.display().to_string(), "old".into(), vec![], None)?;
        let submitted = Uuid::new_v4().to_string();
        store.begin_turn(
            &thread.id,
            &submitted,
            &json!({"role":"user","content":"original"}),
            None,
        )?;
        store.finish_turn(&submitted, "completed", None)?;
        let (sender, _receiver) = mpsc::unbounded_channel();
        let state = Arc::new(State::new(store, sender));
        *state.provider.lock().unwrap() = Some(ProviderConfig {
            provider: "custom".into(),
            base_url: "http://127.0.0.1/v1".into(),
            model: "fixture".into(),
            api_key: None,
        });
        let tools = json!([{"type":"function","name":"ask_user","inputSchema":{"type":"object"}}]);
        let restored = dispatch(
            state.clone(),
            "thread/resume",
            json!({
                "threadId":thread.id, "developerInstructions":"current", "dynamicTools":tools
            }),
        )
        .await?;
        assert_eq!(restored["thread"]["turns"][0]["id"], submitted);
        let updated = state.store.lock().unwrap().thread(&thread.id)?;
        assert_eq!(updated.developer_instructions, "current");
        assert_eq!(updated.dynamic_tools, tools.as_array().unwrap().clone());
        assert!(dispatch(
            state.clone(),
            "turn/start",
            json!({
                "threadId":thread.id, "clientTurnId":submitted,
                "input":[{"type":"text","text":"must not be duplicated"}]
            })
        )
        .await
        .is_err());
        assert!(state.active.lock().unwrap().is_empty());
        assert_eq!(
            state.store.lock().unwrap().turns(&thread.id)?[0]["status"],
            "completed"
        );
        assert_eq!(state.store.lock().unwrap().messages(&thread.id)?.len(), 1);
        assert!(dispatch(state.clone(), "turn/start", json!({
            "threadId":thread.id, "clientTurnId":"invalid", "input":[{"type":"text","text":"invalid"}]
        })).await.is_err());
        assert_eq!(state.store.lock().unwrap().turns(&thread.id)?.len(), 1);
        drop(state);
        std::fs::remove_dir_all(home)?;
        Ok(())
    }
}
