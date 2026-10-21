use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::{Duration, Instant};
use uuid::Uuid;

struct Backend {
    child: Child,
    output: Receiver<Value>,
    events: Vec<Value>,
    next: u64,
}

impl Backend {
    fn start(home: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_myagent-backend"))
            .args(["app-server", "--listen", "stdio://", "-c", "ignored=true"])
            .env_clear()
            .env("MYAGENT_HOME", home)
            .env("CODEX_HOME", home.join("must-not-use-legacy-home"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else {
                    break;
                };
                if let Ok(value) = serde_json::from_str(&line) {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }
        });
        let mut backend = Self {
            child,
            output: rx,
            events: vec![],
            next: 0,
        };
        assert!(backend
            .call(
                "initialize",
                json!({"clientInfo":{"name":"fixture","version":"1"}})
            )
            .get("result")
            .is_some());
        backend.send(json!({"method":"initialized"}));
        backend
    }
    fn send(&mut self, value: Value) {
        let stdin = self.child.stdin.as_mut().unwrap();
        writeln!(stdin, "{value}").unwrap();
        stdin.flush().unwrap();
    }
    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.send(json!({"id":id,"method":method,"params":params}));
        loop {
            let message = self
                .output
                .recv_timeout(Duration::from_secs(10))
                .expect("backend RPC response timed out");
            if message["id"] == id {
                return message;
            }
            self.events.push(message);
        }
    }
    fn wait_completed(&mut self, turn: &str) -> Value {
        if let Some(index) = self
            .events
            .iter()
            .position(|e| e["method"] == "turn/completed" && e["params"]["turn"]["id"] == turn)
        {
            return self.events.remove(index);
        }
        loop {
            let message = self
                .output
                .recv_timeout(Duration::from_secs(10))
                .expect("turn completion timed out");
            if message["method"] == "turn/completed" && message["params"]["turn"]["id"] == turn {
                return message;
            }
            self.events.push(message);
        }
    }
    fn wait_native_request(&mut self, method: &str) -> Value {
        if let Some(index) = self
            .events
            .iter()
            .position(|e| e["method"] == method && e.get("id").is_some())
        {
            return self.events.remove(index);
        }
        loop {
            let message = self
                .output
                .recv_timeout(Duration::from_secs(10))
                .expect("native request timed out");
            if message["method"] == method && message.get("id").is_some() {
                return message;
            }
            self.events.push(message);
        }
    }
    fn eof(&mut self) {
        self.child.stdin.take();
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(status.success());
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("backend did not exit promptly on stdin EOF");
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn home() -> PathBuf {
    let path = std::env::temp_dir().join(format!("myagent-rpc-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn state_revision_and_secret_free_provider_survive_restart() {
    let home = home();
    {
        let mut backend = Backend::start(&home);
        assert_eq!(
            backend.call("backend/health", json!({}))["result"]["backend"],
            "myagent-rust"
        );
        let response=backend.call("provider/configure",json!({"provider":"custom","baseUrl":"http://127.0.0.1:9999/v1","model":"fixture","apiKey":"never-persist-fixture-secret"}));
        assert_eq!(response["result"]["configured"], true);
        assert_eq!(
            backend.call(
                "app/state/write",
                json!({"revision":4,"state":{"tasks":[]}})
            )["result"]["saved"],
            true
        );
        assert!(backend
            .call("app/state/write", json!({"revision":3,"state":{}}))
            .get("error")
            .is_some());
        assert!(backend
            .call(
                "app/state/write",
                json!({"revision":5,"state":{"apiKey":"never-persist-fixture-secret"}})
            )
            .get("error")
            .is_some());
        backend.eof();
    }
    assert!(home.join("myagent.sqlite").exists());
    assert!(!home.join("must-not-use-legacy-home").exists());
    for file in std::fs::read_dir(&home).unwrap() {
        let file = file.unwrap();
        if file.file_type().unwrap().is_file() {
            let bytes = std::fs::read(file.path()).unwrap();
            assert!(!String::from_utf8_lossy(&bytes).contains("never-persist-fixture-secret"));
        }
    }
    {
        let mut backend = Backend::start(&home);
        let response = backend.call("app/state/read", json!({}));
        assert_eq!(response["result"]["revision"], 4);
        assert_eq!(response["result"]["state"]["tasks"], json!([]));
        assert!(backend.call("account/read", json!({}))["result"]["account"].is_null());
        backend.eof();
    }
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn active_turn_interrupt_and_eof_do_not_wait_for_provider() {
    let home = home();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    // No upstream inference occurs: this loopback listener deliberately never answers.
    let mut backend = Backend::start(&home);
    assert_eq!(backend.call("provider/configure",json!({"provider":"custom","baseUrl":format!("http://127.0.0.1:{port}/v1"),"model":"fixture","apiKey":"fixture"}))["result"]["configured"],true);
    let thread = backend.call(
        "thread/start",
        json!({"cwd":home,"developerInstructions":"fixture","dynamicTools":[]}),
    )["result"]["thread"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let turn = backend.call(
        "turn/start",
        json!({"threadId":thread,"input":[{"type":"text","text":"fixture only"}]}),
    )["result"]["turn"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(backend
        .call(
            "turn/start",
            json!({"threadId":thread,"input":[{"type":"text","text":"second"}]})
        )
        .get("error")
        .is_some());
    backend.call("turn/interrupt", json!({"threadId":thread,"turnId":turn}));
    assert_eq!(
        backend.wait_completed(&turn)["params"]["turn"]["status"],
        "interrupted"
    );
    let started = backend.call(
        "turn/start",
        json!({"threadId":thread,"input":[{"type":"text","text":"EOF cancellation fixture"}]}),
    );
    assert!(started.get("result").is_some());
    backend.eof();
    drop(listener);
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn closing_stdout_stops_backend_even_when_stdin_remains_open() {
    let home = home();
    let mut child = Command::new(env!("CARGO_BIN_EXE_myagent-backend"))
        .env_clear()
        .env("MYAGENT_HOME", &home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    drop(child.stdout.take());
    writeln!(
        child.stdin.as_mut().unwrap(),
        "{}",
        json!({"id":1,"method":"initialize","params":{}})
    )
    .unwrap();
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if start.elapsed() > Duration::from_secs(3) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("stdout disconnect left backend waiting on open stdin");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success());
    drop(child);
    std::fs::remove_dir_all(home).unwrap();
}

fn read_http_json(stream: &mut std::net::TcpStream) -> Value {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.starts_with("POST /v1/chat/completions "));
    let mut length = None;
    loop {
        line.clear();
        reader.read_line(&mut line).unwrap();
        if line == "\r\n" {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                length = Some(value.trim().parse::<usize>().unwrap());
            }
        }
    }
    let mut body = vec![0; length.expect("fixture request missing content length")];
    reader.read_exact(&mut body).unwrap();
    serde_json::from_slice(&body).unwrap()
}

#[test]
fn provider_failure_preserves_history_and_model_switches_survive_resume() {
    let home = home();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (requests_tx, requests_rx) = mpsc::channel();
    let fixture = std::thread::spawn(move || {
        for index in 0..3 {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_http_json(&mut stream);
            requests_tx.send(request).unwrap();
            let (status, kind, body) = if index == 0 {
                (
                    "500 Internal Server Error",
                    "application/json",
                    "{\"error\":{\"message\":\"fixture failure\"}}".to_owned(),
                )
            } else {
                (
                    "200 OK",
                    "text/event-stream",
                    format!(
                        "data: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
                        json!({"choices":[{"delta":{"content":"恢复成功"},"finish_reason":null}]}),
                        json!({"choices":[{"delta":{},"finish_reason":"stop"}]})
                    ),
                )
            };
            write!(stream,"HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
            stream.flush().unwrap();
        }
    });
    let mut backend = Backend::start(&home);
    assert_eq!(backend.call("provider/configure",json!({"provider":"custom","baseUrl":format!("http://{address}/v1"),"model":"provider-default","apiKey":"fixture-only"}))["result"]["configured"],true);
    let thread = backend.call(
        "thread/start",
        json!({"cwd":home,"model":"thread-original","dynamicTools":[]}),
    )["result"]["thread"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let first=backend.call("turn/start",json!({"threadId":thread,"model":"selected-model","input":[{"type":"text","text":"first prompt"}]}))["result"]["turn"]["id"].as_str().unwrap().to_owned();
    assert_eq!(
        backend.wait_completed(&first)["params"]["turn"]["status"],
        "failed"
    );
    let resumed = backend.call("thread/resume", json!({"threadId":thread}));
    assert_eq!(resumed["result"]["thread"]["model"], "selected-model");
    assert_eq!(resumed["result"]["thread"]["turns"][0]["status"], "failed");
    let second = backend.call(
        "turn/start",
        json!({"threadId":thread,"input":[{"type":"text","text":"second prompt"}]}),
    )["result"]["turn"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        backend.wait_completed(&second)["params"]["turn"]["status"],
        "completed"
    );
    backend.call(
        "thread/resume",
        json!({"threadId":thread,"model":"resumed-model"}),
    );
    let third=backend.call("turn/start",json!({"threadId":thread,"model":"per-turn-choice","input":[{"type":"text","text":"third prompt"}]}))["result"]["turn"]["id"].as_str().unwrap().to_owned();
    assert_eq!(
        backend.wait_completed(&third)["params"]["turn"]["status"],
        "completed"
    );
    let first_request = requests_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let second_request = requests_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let third_request = requests_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(first_request["model"], "selected-model");
    assert_eq!(second_request["model"], "selected-model");
    assert_eq!(third_request["model"], "per-turn-choice");
    let user_messages = second_request["messages"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|m| m["role"] == "user")
        .map(|m| m["content"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(user_messages, vec!["first prompt", "second prompt"]);
    assert!(third_request["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["role"] == "assistant" && m["content"] == "恢复成功"));
    backend.eof();
    fixture.join().unwrap();
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn interrupted_approval_and_late_reply_do_not_replay_file_write() {
    let home = home();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (requests_tx, requests_rx) = mpsc::channel();
    let fixture = std::thread::spawn(move || {
        for index in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            requests_tx.send(read_http_json(&mut stream)).unwrap();
            let delta = if index == 0 {
                json!({"tool_calls":[{"index":0,"id":"write-before-interrupt","type":"function","function":{"name":"write_file","arguments":json!({"path":"must-not-exist.txt","content":"unapproved"}).to_string()}}]})
            } else {
                json!({"content":"已停止旧操作"})
            };
            let reason = if index == 0 { "tool_calls" } else { "stop" };
            let body = format!(
                "data: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
                json!({"choices":[{"delta":delta,"finish_reason":null}]}),
                json!({"choices":[{"delta":{},"finish_reason":reason}]})
            );
            write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
            stream.flush().unwrap();
        }
    });
    let mut backend = Backend::start(&home);
    assert_eq!(backend.call("provider/configure",json!({"provider":"custom","baseUrl":format!("http://{address}/v1"),"model":"fixture","apiKey":"fixture-only"}))["result"]["configured"],true);
    let thread = backend.call("thread/start", json!({"cwd":home,"dynamicTools":[]}))["result"]
        ["thread"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let first = backend.call(
        "turn/start",
        json!({"threadId":thread,"input":[{"type":"text","text":"prepare a file"}]}),
    )["result"]["turn"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let approval = backend.wait_native_request("item/fileChange/requestApproval");
    backend.call("turn/interrupt", json!({"threadId":thread,"turnId":first}));
    assert_eq!(
        backend.wait_completed(&first)["params"]["turn"]["status"],
        "interrupted"
    );
    backend.send(json!({"id":approval["id"],"result":{"decision":"accept"}}));
    assert!(!home.join("must-not-exist.txt").exists());
    backend.call("thread/resume", json!({"threadId":thread}));
    let second = backend.call(
        "turn/start",
        json!({"threadId":thread,"input":[{"type":"text","text":"report what happened"}]}),
    )["result"]["turn"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        backend.wait_completed(&second)["params"]["turn"]["status"],
        "completed"
    );
    let _ = requests_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let resumed = requests_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let messages = resumed["messages"].as_array().unwrap();
    let tool_index = messages
        .iter()
        .position(|m| m["role"] == "tool" && m["tool_call_id"] == "write-before-interrupt")
        .expect("cancelled tool call needs an explicit interrupted result");
    assert!(messages[tool_index]["content"]
        .as_str()
        .unwrap()
        .contains("interrupted"));
    assert_eq!(messages[tool_index + 1]["role"], "user");
    assert!(!home.join("must-not-exist.txt").exists());
    backend.eof();
    fixture.join().unwrap();
    std::fs::remove_dir_all(home).unwrap();
}
