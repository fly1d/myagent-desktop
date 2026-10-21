use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
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
