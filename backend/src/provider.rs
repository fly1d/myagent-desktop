//! OpenAI-compatible HTTP transport. Credentials never enter messages, events,
//! persistence, process environments, or diagnostic response bodies.
use futures_util::StreamExt;
use reqwest::{header, redirect::Policy, Client, RequestBuilder, StatusCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{collections::BTreeMap, fmt, net::IpAddr, time::Duration};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use url::{Host, Url};

const MAX_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_EVENT_BYTES: usize = 512 * 1024;
const MAX_TEXT_BYTES: usize = 1024 * 1024;
const MAX_TOOL_ARGUMENT_BYTES: usize = 256 * 1024;

/// Deliberately neither Debug nor Serialize: the key exists in memory only.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConfig {
    #[serde(default = "default_provider")]
    pub provider: String,
    pub base_url: String,
    pub model: String,
    #[serde(default)]
    pub api_key: Option<String>,
}

fn default_provider() -> String {
    "custom".into()
}

#[derive(Debug)]
pub enum ProviderError {
    Configuration(&'static str),
    Http(u16),
    Network,
    Timeout,
    Cancelled,
    Protocol(&'static str),
    Limit(&'static str),
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) | Self::Protocol(message) | Self::Limit(message) => {
                f.write_str(message)
            }
            Self::Http(401) => f.write_str("模型服务认证失败（HTTP 401），请检查 API Key。"),
            Self::Http(403) => f.write_str("模型服务拒绝访问（HTTP 403），请检查账号和模型权限。"),
            Self::Http(429) => {
                f.write_str("模型服务限流或额度不足（HTTP 429），请稍后重试并检查额度。")
            }
            Self::Http(code @ 500..=599) => write!(f, "模型服务暂时不可用（HTTP {code}）。"),
            Self::Http(code @ 300..=399) => write!(
                f,
                "模型服务返回重定向（HTTP {code}）；为避免转发密钥，已拒绝跟随。"
            ),
            Self::Http(code) => write!(f, "模型服务请求失败（HTTP {code}）。"),
            Self::Network => f.write_str("无法连接模型服务，请检查地址、网络和 TLS 证书。"),
            Self::Timeout => f.write_str("模型服务响应超时，连接已取消。"),
            Self::Cancelled => f.write_str("本轮模型请求已停止。"),
        }
    }
}

impl std::error::Error for ProviderError {}

impl ProviderConfig {
    /// Discovery checks the endpoint and credentials without inventing a model.
    pub fn validate_connection(&self) -> Result<(), ProviderError> {
        let url = validate_base_url(&self.base_url)?;
        if !is_loopback(&url) && !self.uses_api_key() {
            return Err(ProviderError::Configuration("远程模型服务需要 API Key。"));
        }
        if self
            .api_key
            .as_ref()
            .is_some_and(|key| key.len() > 16_384 || key.contains(['\r', '\n']))
        {
            return Err(ProviderError::Configuration("API Key 格式无效。"));
        }
        Ok(())
    }

    /// Saved configurations and inference additionally require an explicit ID.
    pub fn validate(&self) -> Result<(), ProviderError> {
        self.validate_connection()?;
        if !valid_model_id(&self.model) {
            return Err(ProviderError::Configuration(
                "请提供有效的模型 ID（最多 256 字节，不含控制字符或首尾空白）。",
            ));
        }
        Ok(())
    }

    pub fn uses_api_key(&self) -> bool {
        self.effective_api_key().is_some()
    }

    pub fn auth_mode(&self) -> &'static str {
        if self.uses_api_key() {
            "apikey"
        } else {
            "none"
        }
    }

    fn effective_api_key(&self) -> Option<&str> {
        self.api_key.as_deref().filter(|key| !key.trim().is_empty())
    }
}

fn valid_model_id(model: &str) -> bool {
    !model.is_empty()
        && model.len() <= 256
        && model.trim() == model
        && !model.chars().any(char::is_control)
}

pub fn validate_base_url(value: &str) -> Result<Url, ProviderError> {
    let url = Url::parse(value).map_err(|_| ProviderError::Configuration("模型服务地址无效。"))?;
    let authority = value
        .split_once("://")
        .map(|(_, rest)| rest.split(['/', '?', '#']).next().unwrap_or(""))
        .unwrap_or("");
    if url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || authority.contains('@')
    {
        return Err(ProviderError::Configuration(
            "模型服务地址不得包含账号或密码。",
        ));
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err(ProviderError::Configuration(
            "模型服务根地址不能包含查询参数或片段；API Key 仅通过请求头发送。",
        ));
    }
    if url.scheme() != "https" && !(url.scheme() == "http" && is_loopback(&url)) {
        return Err(ProviderError::Configuration(
            "远程模型服务必须使用 HTTPS；HTTP 仅允许本机 loopback 服务。",
        ));
    }
    Ok(url)
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(ip)) => IpAddr::V4(ip).is_loopback(),
        Some(Host::Ipv6(ip)) => IpAddr::V6(ip).is_loopback(),
        None => false,
    }
}

pub struct Provider {
    client: Client,
    config: ProviderConfig,
}

#[derive(Clone, Debug, Default)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

pub struct Completion {
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    // Provider protocol state, never a user-facing message or delta. DeepSeek
    // requires it to be replayed across thinking-mode tool requests.
    pub reasoning_content: Option<String>,
}

impl fmt::Debug for Completion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Completion")
            .field("content_bytes", &self.content.len())
            .field("tool_count", &self.tool_calls.len())
            .field("has_reasoning_state", &self.reasoning_content.is_some())
            .finish()
    }
}

impl Provider {
    pub fn new(config: ProviderConfig) -> Result<Self, ProviderError> {
        config.validate()?;
        Self::build(config)
    }

    fn for_discovery(config: ProviderConfig) -> Result<Self, ProviderError> {
        config.validate_connection()?;
        Self::build(config)
    }

    fn build(config: ProviderConfig) -> Result<Self, ProviderError> {
        let client = Client::builder()
            .redirect(Policy::none())
            .no_proxy()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(180))
            .build()
            .map_err(|_| ProviderError::Network)?;
        Ok(Self { client, config })
    }

    fn request(&self, path: &str, post: bool) -> RequestBuilder {
        let endpoint = format!("{}/{}", self.config.base_url.trim_end_matches('/'), path);
        let request = if post {
            self.client.post(endpoint)
        } else {
            self.client.get(endpoint)
        };
        let request = request.header(
            header::ACCEPT,
            if post {
                "text/event-stream"
            } else {
                "application/json"
            },
        );
        match self.config.effective_api_key() {
            Some(key) => request.bearer_auth(key),
            None => request,
        }
    }

    pub async fn models(&self, cancel: &CancellationToken) -> Result<Vec<Value>, ProviderError> {
        let response = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            result = self.request("models", false).timeout(Duration::from_secs(30)).send() => result.map_err(network_error)?,
        };
        check_status(response.status())?;
        let mut stream = response.bytes_stream();
        let mut bytes = Vec::new();
        while let Some(chunk) = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            next = stream.next() => next,
        } {
            let chunk = chunk.map_err(network_error)?;
            if bytes.len() + chunk.len() > 2 * 1024 * 1024 {
                return Err(ProviderError::Limit("模型列表超过 2 MB 限制。"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let result: Value = serde_json::from_slice(&bytes)
            .map_err(|_| ProviderError::Protocol("模型服务未返回有效的 JSON 模型列表。"))?;
        let data = result
            .get("data")
            .and_then(Value::as_array)
            .ok_or(ProviderError::Protocol(
                "模型列表缺少 data 数组；请确认地址支持 OpenAI-compatible /models。",
            ))?;
        let mut models = Vec::new();
        for row in data.iter().take(2000) {
            if let Some(id) = row
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| valid_model_id(id))
            {
                if self
                    .config
                    .effective_api_key()
                    .is_some_and(|key| id.contains(key))
                {
                    continue;
                }
                models.push(json!({"id": id}));
            }
        }
        Ok(models)
    }

    pub async fn complete(
        &self,
        messages: Vec<Value>,
        tools: Vec<Value>,
        cancel: &CancellationToken,
        deltas: mpsc::Sender<String>,
    ) -> Result<Completion, ProviderError> {
        // A discovery-only provider must never start inference with model:"".
        self.config.validate()?;
        let messages = self.prepare_messages(messages);
        let mut body = json!({"model":self.config.model,"messages":messages,"stream":true});
        if !tools.is_empty() {
            body["tools"] = Value::Array(tools);
            // `auto` is the API default when tools are present. Omitting this
            // redundant parameter also accommodates thinking-mode endpoints.
        }
        if serde_json::to_vec(&body)
            .map_err(|_| ProviderError::Protocol("模型请求无法编码。"))?
            .len()
            > MAX_RESPONSE_BYTES
        {
            return Err(ProviderError::Limit(
                "模型会话上下文超过 8 MB 限制，请开始新任务或缩短内容。",
            ));
        }
        let response = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            result = self.request("chat/completions", true).json(&body).send() => result.map_err(network_error)?,
        };
        check_status(response.status())?;
        let mut stream = response.bytes_stream();
        let mut parser = SseParser::default();
        let mut state = CompletionState::default();
        let mut total_bytes = 0usize;
        let mut finished = false;
        while !finished {
            let next = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
                next = tokio::time::timeout(Duration::from_secs(35), stream.next()) => next.map_err(|_| ProviderError::Timeout)?,
            };
            let Some(next) = next else { break };
            let bytes = next.map_err(network_error)?;
            total_bytes = total_bytes.saturating_add(bytes.len());
            if total_bytes > MAX_RESPONSE_BYTES {
                return Err(ProviderError::Limit("模型流式响应超过 8 MB 限制。"));
            }
            for frame in parser.push(&bytes)? {
                if cancel.is_cancelled() {
                    return Err(ProviderError::Cancelled);
                }
                let outcome = state.consume(&frame)?;
                if let Some(text) = outcome.text {
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
                        sent = deltas.send(text) => sent.map_err(|_| ProviderError::Cancelled)?,
                    }
                }
                if outcome.done {
                    finished = true;
                    break;
                }
            }
        }
        if !finished {
            parser.finish()?;
            return Err(ProviderError::Protocol(
                "模型连接提前关闭，未收到完整的 [DONE] 完成标记；本轮未完成。",
            ));
        }
        state.finish()
    }

    fn prepare_messages(&self, mut messages: Vec<Value>) -> Vec<Value> {
        let deepseek = self.config.provider.eq_ignore_ascii_case("deepseek")
            || Url::parse(&self.config.base_url)
                .ok()
                .is_some_and(|url| url.host_str() == Some("api.deepseek.com"));
        for message in &mut messages {
            if message["role"] != "assistant" {
                continue;
            }
            if let Some(fields) = message.as_object_mut() {
                if deepseek {
                    // Empty state represents an older/non-thinking message;
                    // actual returned reasoning is preserved without changes.
                    fields
                        .entry("reasoning_content")
                        .or_insert_with(|| json!(""));
                    if fields.get("content").is_none_or(Value::is_null) {
                        fields.insert("content".into(), json!(""));
                    }
                } else {
                    // Switching a thread to OpenAI must not send DeepSeek-only
                    // message extensions to a stricter API.
                    fields.remove("reasoning_content");
                }
            }
        }
        messages
    }
}

fn network_error(error: reqwest::Error) -> ProviderError {
    // Never include reqwest diagnostics or a provider's body: either may contain
    // a URL or a credential echoed by a server/proxy.
    if error.is_timeout() {
        ProviderError::Timeout
    } else {
        ProviderError::Network
    }
}

fn check_status(status: StatusCode) -> Result<(), ProviderError> {
    if status.is_success() {
        Ok(())
    } else {
        Err(ProviderError::Http(status.as_u16()))
    }
}

pub async fn test_provider(config: &ProviderConfig) -> anyhow::Result<Value> {
    let provider = Provider::for_discovery(config.clone())?;
    let models = provider.models(&CancellationToken::new()).await?;
    let label = match config.provider.to_lowercase().as_str() {
        "openai" => "OpenAI",
        "deepseek" => "DeepSeek",
        "ollama" => "Ollama",
        "local" => "本机模型服务",
        _ => "OpenAI-compatible",
    };
    Ok(json!({"reachable":true,"models":models,"label":label}))
}

#[derive(Default)]
struct SseParser {
    line: Vec<u8>,
    event: Vec<u8>,
}

impl SseParser {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, ProviderError> {
        let mut frames = Vec::new();
        for byte in bytes {
            if *byte == b'\n' {
                self.consume_line(&mut frames)?;
            } else {
                self.line.push(*byte);
                if self.line.len() > MAX_EVENT_BYTES {
                    return Err(ProviderError::Limit("模型 SSE 行超过大小限制。"));
                }
            }
        }
        Ok(frames)
    }

    fn consume_line(&mut self, frames: &mut Vec<Vec<u8>>) -> Result<(), ProviderError> {
        if self.line.last() == Some(&b'\r') {
            self.line.pop();
        }
        if self.line.is_empty() {
            if !self.event.is_empty() {
                frames.push(std::mem::take(&mut self.event));
            }
        } else if self.line.starts_with(b"data:") {
            let data = &self.line[5..];
            let data = data.strip_prefix(b" ").unwrap_or(data);
            if !self.event.is_empty() {
                self.event.push(b'\n');
            }
            self.event.extend_from_slice(data);
            if self.event.len() > MAX_EVENT_BYTES {
                return Err(ProviderError::Limit("模型 SSE 事件超过大小限制。"));
            }
        }
        self.line.clear();
        Ok(())
    }

    fn finish(&self) -> Result<(), ProviderError> {
        // SSE dispatches an event only at its terminating blank line. EOF must
        // never promote a partial line or undelimited [DONE] into completion.
        if !self.line.is_empty() || !self.event.is_empty() {
            return Err(ProviderError::Protocol(
                "模型 SSE 连接在事件结束之前中断，本轮未完成。",
            ));
        }
        Ok(())
    }
}

#[derive(Default)]
struct CompletionState {
    content: String,
    reasoning_content: Option<String>,
    calls: BTreeMap<usize, ToolCall>,
    finish_reason: Option<String>,
    frames: usize,
}

struct FrameOutcome {
    text: Option<String>,
    done: bool,
}

impl CompletionState {
    fn consume(&mut self, frame: &[u8]) -> Result<FrameOutcome, ProviderError> {
        self.frames += 1;
        if self.frames > 30_000 {
            return Err(ProviderError::Limit("模型流式事件数量超过限制。"));
        }
        if frame == b"[DONE]" {
            return Ok(FrameOutcome {
                text: None,
                done: true,
            });
        }
        let value: Value = serde_json::from_slice(frame)
            .map_err(|_| ProviderError::Protocol("模型流式事件不是有效 UTF-8 JSON。"))?;
        if value.get("error").is_some_and(|error| !error.is_null()) {
            return Err(ProviderError::Protocol(
                "模型服务在流式响应中返回错误；未显示服务商原始内容以保护密钥。",
            ));
        }
        let choices = value
            .get("choices")
            .and_then(Value::as_array)
            .ok_or(ProviderError::Protocol("模型流式事件缺少 choices 数组。"))?;
        let Some(choice) = choices.first() else {
            return Ok(FrameOutcome {
                text: None,
                done: false,
            });
        };
        if choice
            .get("index")
            .is_some_and(|index| index.as_u64() != Some(0))
        {
            return Err(ProviderError::Protocol("模型返回了未请求的多选响应。"));
        }
        let delta = &choice["delta"];
        let has_output = ["content", "reasoning_content"]
            .iter()
            .any(|field| delta[*field].as_str().is_some_and(|text| !text.is_empty()))
            || delta["tool_calls"]
                .as_array()
                .is_some_and(|calls| !calls.is_empty());
        if self.finish_reason.is_some() && has_output {
            return Err(ProviderError::Protocol(
                "模型在完成标记之后继续生成输出，本轮未完成。",
            ));
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            if self
                .finish_reason
                .as_deref()
                .is_some_and(|previous| previous != reason)
            {
                return Err(ProviderError::Protocol("模型返回互相矛盾的完成原因。"));
            }
            self.finish_reason = Some(reason.to_owned());
        }
        let text = delta
            .get("content")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_owned);
        if let Some(text) = &text {
            if self.content.len() + text.len() > MAX_TEXT_BYTES {
                return Err(ProviderError::Limit("模型文本超过 1 MB 限制。"));
            }
            self.content.push_str(text);
        }
        if let Some(reasoning) = delta.get("reasoning_content").and_then(Value::as_str) {
            let retained = self.reasoning_content.get_or_insert_with(String::new);
            if retained.len() + reasoning.len() > MAX_TEXT_BYTES {
                return Err(ProviderError::Limit("模型协议推理状态超过 1 MB 限制。"));
            }
            retained.push_str(reasoning);
        }
        if delta
            .get("refusal")
            .and_then(Value::as_str)
            .is_some_and(|refusal| !refusal.is_empty())
        {
            return Err(ProviderError::Protocol("模型拒绝了本次请求。"));
        }
        if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
            for call in calls {
                if call
                    .get("type")
                    .filter(|kind| !kind.is_null())
                    .is_some_and(|kind| kind != "function")
                {
                    return Err(ProviderError::Protocol("模型返回不支持的工具调用类型。"));
                }
                let index = call
                    .get("index")
                    .and_then(Value::as_u64)
                    .ok_or(ProviderError::Protocol("工具调用缺少 index。"))?
                    as usize;
                if index >= 32 {
                    return Err(ProviderError::Limit("一次模型响应最多允许 32 个工具调用。"));
                }
                let entry = self.calls.entry(index).or_default();
                if let Some(id) = call.get("id").and_then(Value::as_str) {
                    entry.id.push_str(id);
                }
                if let Some(name) = call["function"].get("name").and_then(Value::as_str) {
                    entry.name.push_str(name);
                }
                if let Some(arguments) = call["function"].get("arguments").and_then(Value::as_str) {
                    entry.arguments.push_str(arguments);
                }
                if entry.id.len() > 256
                    || entry.name.len() > 128
                    || entry.arguments.len() > MAX_TOOL_ARGUMENT_BYTES
                {
                    return Err(ProviderError::Limit("工具调用标识或参数超过大小限制。"));
                }
            }
        }
        Ok(FrameOutcome { text, done: false })
    }

    fn finish(self) -> Result<Completion, ProviderError> {
        match self.finish_reason.as_deref() {
            Some("length") => {
                return Err(ProviderError::Protocol(
                    "模型输出达到长度上限而截断，本轮未完成。",
                ))
            }
            Some("content_filter") => {
                return Err(ProviderError::Protocol(
                    "模型输出受到内容过滤，本轮未完成。",
                ))
            }
            Some("stop" | "tool_calls") => {}
            None => {
                return Err(ProviderError::Protocol(
                    "模型缺少明确的 finish_reason，本轮未完成。",
                ))
            }
            Some(_) => return Err(ProviderError::Protocol("模型返回不支持的完成原因。")),
        }
        let calls: Vec<ToolCall> = self.calls.into_values().collect();
        if (self.finish_reason.as_deref() == Some("tool_calls")) != !calls.is_empty() {
            return Err(ProviderError::Protocol(
                "模型完成原因与工具调用内容不一致，本轮未完成。",
            ));
        }
        let mut ids = std::collections::HashSet::new();
        for call in &calls {
            if call.id.is_empty()
                || call.name.is_empty()
                || !ids.insert(call.id.clone())
                || !call
                    .name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
            {
                return Err(ProviderError::Protocol(
                    "模型工具调用缺少有效且唯一的标识或函数名。",
                ));
            }
        }
        if self.content.is_empty() && calls.is_empty() {
            return Err(ProviderError::Protocol("模型未返回文本或工具调用。"));
        }
        Ok(Completion {
            content: self.content,
            tool_calls: calls,
            reasoning_content: self.reasoning_content,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    #[test]
    fn endpoints_reject_credentials_remote_http_and_query_secrets() {
        for url in [
            "https://api.openai.com/v1",
            "https://api.deepseek.com",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:8080/v1",
            "http://localhost:8000/v1",
        ] {
            assert!(validate_base_url(url).is_ok(), "{url}");
        }
        for url in [
            "http://example.com/v1",
            "https://user:secret@example.com/v1",
            "https://@example.com/v1",
            "file:///tmp/key",
            "https://example.com/v1?key=secret",
            "https://example.com/#secret",
        ] {
            assert!(validate_base_url(url).is_err(), "{url}");
        }
    }

    #[test]
    fn discovery_validation_does_not_invent_an_inference_model() {
        let mut config = fixture_config("http://127.0.0.1:11434/v1".into());
        config.model.clear();
        config.api_key = None;
        assert!(config.validate_connection().is_ok());
        assert!(config.validate().is_err());
        assert!(Provider::new(config.clone()).is_err());
        assert!(Provider::for_discovery(config.clone()).is_ok());
        for model in ["", "   ", " model", "model ", "model\n", "model\0"] {
            config.model = model.into();
            assert!(config.validate_connection().is_ok());
            assert!(config.validate().is_err());
        }
        config.model = "qwen3:8b".into();
        assert!(config.validate().is_ok());
        assert_eq!(config.auth_mode(), "none");
        config.base_url = "https://api.example.com/v1".into();
        assert!(config.validate_connection().is_err());
        config.api_key = Some("fixture-key".into());
        assert!(config.validate_connection().is_ok());
        assert_eq!(config.auth_mode(), "apikey");
        config.model.clear();
        assert!(config.validate_connection().is_ok());
        assert!(config.validate().is_err());
        config.base_url = "http://api.example.com/v1".into();
        assert!(config.validate_connection().is_err());
    }

    #[test]
    fn no_key_is_confined_to_parsed_loopback_hosts_not_lan_or_lookalikes() {
        for address in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://127.10.20.30:11434/v1",
            "http://[::1]:11434/v1",
            "https://[::1]:11434/v1",
        ] {
            let mut config = fixture_config(address.into());
            config.api_key = None;
            assert!(config.validate_connection().is_ok(), "{address}");
        }
        for authority in [
            "localhost.evil.example:11434",
            "localhostevil.example:11434",
            "localhost.:11434",
            "127.0.0.1.evil.example:11434",
            "127.0.0.1-evil.example:11434",
            "127evil.example:11434",
            "127.0.0.1%2eevil.example:11434",
            "locаlhost:11434",
            "127.0.0.1@evil.example:11434",
            "[::1]@evil.example:11434",
            "[::1].evil.example:11434",
            "192.168.1.2:11434",
            "10.0.0.2:11434",
            "128.0.0.1:11434",
            "0.0.0.0:11434",
            "[::]:11434",
            "[::10]:11434",
            "[fe80::1]:11434",
            "[::ffff:127.0.0.1]:11434",
            "[::1%25lo0]:11434",
        ] {
            for scheme in ["http", "https"] {
                let address = format!("{scheme}://{authority}/v1");
                let mut config = fixture_config(address.clone());
                config.api_key = None;
                assert!(config.validate_connection().is_err(), "{address}");
            }
        }
    }

    #[test]
    fn sse_preserves_chinese_utf8_and_reassembles_tool_arguments() {
        let source = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\r\n\r\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"中文.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n");
        let mut parser = SseParser::default();
        let mut state = CompletionState::default();
        let mut deltas = String::new();
        for bytes in source.as_bytes().chunks(1) {
            for event in parser.push(bytes).unwrap() {
                if let Some(text) = state.consume(&event).unwrap().text {
                    deltas.push_str(&text);
                }
            }
        }
        let result = state.finish().unwrap();
        assert_eq!(deltas, "你好");
        assert_eq!(result.tool_calls[0].arguments, "{\"path\":\"中文.txt\"}");
        assert_eq!(result.tool_calls[0].name, "write_file");
    }

    #[test]
    fn rejects_oversized_frames_and_missing_tool_identity() {
        assert!(SseParser::default()
            .push(&vec![b'x'; MAX_EVENT_BYTES + 1])
            .is_err());
        let mut state = CompletionState::default();
        state.consume(br#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#).unwrap();
        assert!(state.finish().unwrap_err().to_string().contains("唯一"));
    }

    #[test]
    fn compatible_null_tool_metadata_preserves_argument_fragments() {
        let mut state = CompletionState::default();
        state.consume(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-a","type":"function","function":{"name":"read_file","arguments":"{\"path\":\""}}]}}]}).to_string().as_bytes()).unwrap();
        state.consume(json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"type":null,"function":{"name":null,"arguments":"README.md\"}"}}]},"finish_reason":"tool_calls"}]}).to_string().as_bytes()).unwrap();
        let completion = state.finish().unwrap();
        assert_eq!(completion.tool_calls[0].name, "read_file");
        assert_eq!(completion.tool_calls[0].id, "call-a");
        assert_eq!(
            completion.tool_calls[0].arguments,
            "{\"path\":\"README.md\"}"
        );
        let mut invalid = CompletionState::default();
        assert!(invalid
            .consume(
                json!({"choices":[{"delta":{"tool_calls":[{"index":0,"type":"unsupported"}]}}]})
                    .to_string()
                    .as_bytes()
            )
            .is_err());
    }

    #[test]
    fn tool_finish_reason_must_match_actual_calls() {
        for (reason, calls) in [("stop", true), ("tool_calls", false)] {
            let mut state = CompletionState::default();
            let delta = if calls {
                json!({"tool_calls":[{"index":0,"id":"call-a","type":"function","function":{"name":"read_file","arguments":"{}"}}]})
            } else {
                json!({"content":"partial"})
            };
            state
                .consume(
                    json!({"choices":[{"delta":delta,"finish_reason":reason}]})
                        .to_string()
                        .as_bytes(),
                )
                .unwrap();
            assert!(state.finish().is_err());
        }
    }

    #[test]
    fn reasoning_state_is_replayed_only_to_deepseek_and_never_displayed_as_text() {
        let mut state = CompletionState::default();
        for part in ["协议", "状态"] {
            let outcome = state
                .consume(
                    json!({"choices":[{"delta":{"reasoning_content":part}}]})
                        .to_string()
                        .as_bytes(),
                )
                .unwrap();
            assert!(outcome.text.is_none());
        }
        state
            .consume(
                json!({"choices":[{"delta":{"content":"公开回答"},"finish_reason":"stop"}]})
                    .to_string()
                    .as_bytes(),
            )
            .unwrap();
        let completion = state.finish().unwrap();
        assert_eq!(completion.reasoning_content.as_deref(), Some("协议状态"));
        assert_eq!(completion.content, "公开回答");
        assert!(!format!("{completion:?}").contains("协议状态"));
        let history =
            vec![json!({"role":"assistant","content":null,"reasoning_content":"协议状态"})];
        let mut config = fixture_config("http://127.0.0.1:1/v1".into());
        config.provider = "deepseek".into();
        let prepared = Provider::new(config)
            .unwrap()
            .prepare_messages(history.clone());
        assert_eq!(prepared[0]["reasoning_content"], "协议状态");
        assert_eq!(prepared[0]["content"], "");
        let openai = Provider::new(fixture_config("http://127.0.0.1:1/v1".into()))
            .unwrap()
            .prepare_messages(history);
        assert!(openai[0].get("reasoning_content").is_none());
    }

    async fn http_fixture(
        status: &str,
        extra: &str,
        body: String,
    ) -> (String, tokio::task::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("http://{}/v1", listener.local_addr().unwrap());
        let status = status.to_owned();
        let extra = extra.to_owned();
        let task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let count = socket.read(&mut buffer).await.unwrap();
                if count == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..count]);
                assert!(request.len() < 1024 * 1024);
                if let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&request[..end]);
                    let length = header
                        .lines()
                        .find_map(|line| {
                            line.to_lowercase()
                                .strip_prefix("content-length:")
                                .map(|value| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let header = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n",body.len());
            if socket.write_all(header.as_bytes()).await.is_ok() {
                for bytes in body.as_bytes().chunks(3) {
                    if socket.write_all(bytes).await.is_err() {
                        break;
                    }
                }
            }
            let _ = socket.shutdown().await;
            String::from_utf8(request).unwrap()
        });
        (address, task)
    }

    fn fixture_config(base_url: String) -> ProviderConfig {
        ProviderConfig {
            provider: "custom".into(),
            base_url,
            model: "fixture-model".into(),
            api_key: Some("fixture-only-secret".into()),
        }
    }

    #[tokio::test]
    async fn empty_model_discovers_real_local_models_without_authorization_header() {
        for key in [None, Some(String::new()), Some("   ".into())] {
            let (address,server) = http_fixture("200 OK","",json!({"data":[{"id":"qwen3:8b"},{"id":"actual   local model"},{"id":" invalid "},{"id":"\n"}]}).to_string()).await;
            let mut config = fixture_config(address);
            config.provider = "local".into();
            config.model.clear();
            config.api_key = key;
            let discovered = test_provider(&config).await.unwrap();
            assert_eq!(discovered["reachable"], true);
            assert_eq!(
                discovered["models"],
                json!([{"id":"qwen3:8b"},{"id":"actual   local model"}])
            );
            assert!(discovered.get("model").is_none());
            let request = server.await.unwrap();
            assert!(request.starts_with("GET /v1/models "));
            assert!(!request.to_lowercase().contains("authorization:"));
            let discovery = Provider::for_discovery(config).unwrap();
            let (sender, _receiver) = mpsc::channel(1);
            let attempted = discovery
                .complete(
                    vec![json!({"role":"user","content":"must select a model first"})],
                    vec![],
                    &CancellationToken::new(),
                    sender,
                )
                .await;
            assert!(matches!(attempted, Err(ProviderError::Configuration(_))));
        }
    }

    #[tokio::test]
    async fn real_http_models_and_streaming_with_mock_key() {
        let (address, server) = http_fixture(
            "200 OK",
            "",
            json!({"data":[{"id":"actual-fixture-model"}]}).to_string(),
        )
        .await;
        let provider = Provider::new(fixture_config(address)).unwrap();
        let models = provider.models(&CancellationToken::new()).await.unwrap();
        assert_eq!(models, vec![json!({"id":"actual-fixture-model"})]);
        let request = server.await.unwrap();
        assert!(request.starts_with("GET /v1/models "));
        assert!(request
            .to_lowercase()
            .contains("authorization: bearer fixture-only-secret"));

        let body = format!(
            "data: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
            json!({"choices":[{"delta":{"content":"你好，独立应用"},"finish_reason":null}]}),
            json!({"choices":[{"delta":{},"finish_reason":"stop"}]})
        );
        let (address, server) = http_fixture("200 OK", "", body).await;
        let provider = Provider::new(fixture_config(address)).unwrap();
        let (sender, mut receiver) = mpsc::channel(32);
        let completion = provider
            .complete(
                vec![json!({"role":"user","content":"hello"})],
                vec![],
                &CancellationToken::new(),
                sender,
            )
            .await
            .unwrap();
        assert_eq!(completion.content, "你好，独立应用");
        assert_eq!(receiver.recv().await.unwrap(), "你好，独立应用");
        let request = server.await.unwrap();
        assert!(request.starts_with("POST /v1/chat/completions "));
        let request_body: Value =
            serde_json::from_str(request.split("\r\n\r\n").nth(1).unwrap()).unwrap();
        assert_eq!(request_body["stream"], true);
        assert!(!request_body.to_string().contains("fixture-only-secret"));
    }

    #[tokio::test]
    async fn never_follows_redirect_or_echoes_error_body_secret() {
        let destination = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let extra = format!(
            "Location: http://{}/stolen\r\n",
            destination.local_addr().unwrap()
        );
        let (address, server) =
            http_fixture("302 Found", &extra, "fixture-only-secret".into()).await;
        let provider = Provider::new(fixture_config(address)).unwrap();
        let error = provider
            .models(&CancellationToken::new())
            .await
            .unwrap_err();
        assert!(matches!(error, ProviderError::Http(302)));
        assert!(!error.to_string().contains("fixture-only-secret"));
        server.await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(100), destination.accept())
                .await
                .is_err()
        );

        let (address, server) =
            http_fixture("401 Unauthorized", "", "echo fixture-only-secret".into()).await;
        let provider = Provider::new(fixture_config(address)).unwrap();
        let error = provider
            .models(&CancellationToken::new())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("401"));
        assert!(!error.to_string().contains("fixture-only-secret"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn real_http_rejects_incomplete_streams_and_error_frames() {
        let text = json!({"choices":[{"delta":{"content":"仅收到部分回答"},"finish_reason":null}]});
        let terminal = json!({"choices":[{"delta":{},"finish_reason":"stop"}]});
        let bodies = [
            // Clean HTTP EOF is not proof that model generation completed.
            format!("data: {text}\n\n"),
            format!("data: {text}\n\ndata: {terminal}\n\n"),
            format!("data: {text}\n\ndata: [DONE]\n\n"),
            format!("data: {text}\n\ndata: {terminal}\n\ndata: [DONE]"),
            format!("data: {text}\n\ndata: {{\"error\":{{\"message\":\"fixture-only-secret\"}}}}\n\ndata: [DONE]\n\n"),
            format!("data: {text}\n\ndata: {}\n\ndata: [DONE]\n\n",json!({"choices":[{"delta":{},"finish_reason":"length"}]})),
        ];
        for body in bodies {
            let (address, server) = http_fixture("200 OK", "", body).await;
            let provider = Provider::new(fixture_config(address)).unwrap();
            let (sender, _receiver) = mpsc::channel(32);
            let result = provider
                .complete(
                    vec![json!({"role":"user","content":"test"})],
                    vec![],
                    &CancellationToken::new(),
                    sender,
                )
                .await;
            let error = result.unwrap_err();
            assert!(!error.to_string().contains("fixture-only-secret"));
            server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn cancellation_drops_pending_http_request() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("http://{}/v1", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(30)).await;
            drop(socket);
        });
        let provider = Provider::new(fixture_config(address)).unwrap();
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let request = tokio::spawn(async move { provider.models(&token).await });
        tokio::time::sleep(Duration::from_millis(75)).await;
        cancel.cancel();
        let result = tokio::time::timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(result, Err(ProviderError::Cancelled)));
        server.abort();
    }

    #[tokio::test]
    async fn cancellation_stops_an_active_partial_sse_response() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = format!("http://{}/v1", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 4096];
            let _ = socket.read(&mut request).await.unwrap();
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {}\n\n",json!({"choices":[{"delta":{"content":"正在生成"},"finish_reason":null}]}));
            socket.write_all(response.as_bytes()).await.unwrap();
            tokio::time::sleep(Duration::from_secs(30)).await;
        });
        let provider = Provider::new(fixture_config(address)).unwrap();
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let (sender, mut receiver) = mpsc::channel(32);
        let request = tokio::spawn(async move {
            provider
                .complete(
                    vec![json!({"role":"user","content":"test cancellation"})],
                    vec![],
                    &token,
                    sender,
                )
                .await
        });
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), receiver.recv())
                .await
                .unwrap()
                .unwrap(),
            "正在生成"
        );
        cancel.cancel();
        let result = tokio::time::timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(result, Err(ProviderError::Cancelled)));
        server.abort();
    }
}
