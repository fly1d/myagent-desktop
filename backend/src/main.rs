use anyhow::{Context, Result};
use myagent_backend::{dispatch, store::Store, State};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

#[tokio::main]
async fn main() -> Result<()> {
    // Legacy app-server arguments are accepted solely for native transport compatibility.
    let home = std::env::var_os("MYAGENT_HOME")
        .or_else(|| std::env::var_os("CODEX_HOME"))
        .context("Independent MYAGENT_HOME is required")?;
    let home = std::path::PathBuf::from(home);
    std::fs::create_dir_all(&home)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700))?;
    }
    let store = Store::open(&home.join("myagent.sqlite"))?;
    let (sender, mut receiver) = mpsc::unbounded_channel::<Value>();
    let state = Arc::new(State::new(store, sender));
    let disconnected = CancellationToken::new();
    let output_disconnected = disconnected.clone();
    // Dedicated OS threads keep a blocked pipe from holding Tokio's runtime
    // shutdown open after the other pipe has disconnected.
    std::thread::spawn(move || {
        use std::io::Write;
        let stdout = std::io::stdout();
        let mut stdout = stdout.lock();
        while let Some(message) = receiver.blocking_recv() {
            let Ok(mut bytes) = serde_json::to_vec(&message) else {
                output_disconnected.cancel();
                return;
            };
            bytes.push(b'\n');
            if stdout
                .write_all(&bytes)
                .and_then(|_| stdout.flush())
                .is_err()
            {
                output_disconnected.cancel();
                return;
            }
        }
    });
    let (input_sender, mut input_receiver) = mpsc::channel(32);
    std::thread::spawn(move || {
        use std::io::{BufRead, Read};
        let stdin = std::io::stdin();
        let mut stdin = std::io::BufReader::new(stdin.lock());
        loop {
            let mut buffer = Vec::new();
            let result = (&mut stdin)
                .take(8 * 1024 * 1024 + 1)
                .read_until(b'\n', &mut buffer);
            match result {
                Ok(0) => break,
                Ok(_) if buffer.len() <= 8 * 1024 * 1024 => {
                    if input_sender.blocking_send(Ok(buffer)).is_err() {
                        break;
                    }
                }
                _ => {
                    let _ = input_sender.blocking_send(Err(()));
                    break;
                }
            }
        }
    });
    let mut initialized = false;
    loop {
        let frame = tokio::select! {
            biased;
            _=disconnected.cancelled()=>break,
            frame=input_receiver.recv()=>frame,
        };
        let Some(Ok(buffer)) = frame else {
            break;
        };
        let message: Value = match serde_json::from_slice(&buffer) {
            Ok(m) => m,
            Err(_) => {
                if state
                    .send(json!({"id":null,"error":{"code":-32700,"message":"Invalid JSON"}}))
                    .is_err()
                {
                    break;
                }
                continue;
            }
        };
        let Some(method) = message["method"].as_str() else {
            state.receive_reply(message);
            continue;
        };
        if method == "initialized" {
            continue;
        }
        let Some(id) = message.get("id").cloned() else {
            continue;
        };
        if method == "initialize" {
            if initialized {
                if state
                    .send(json!({"id":id,"error":{"code":-32600,"message":"Already initialized"}}))
                    .is_err()
                {
                    break;
                }
                continue;
            }
            initialized = true;
        } else if !initialized {
            if state
                .send(json!({"id":id,"error":{"code":-32600,"message":"Not initialized"}}))
                .is_err()
            {
                break;
            }
            continue;
        }
        let method = method.to_owned();
        let params = message.get("params").cloned().unwrap_or(json!({}));
        let task_state = state.clone();
        // Provider HTTP, turn execution, and native approvals must never block stdin replies.
        tokio::spawn(async move {
            let response = match dispatch(task_state.clone(), &method, params).await {
                Ok(result) => json!({"id":id,"result":result}),
                Err(error) => json!({"id":id,"error":{"code":-32603,"message":error.to_string()}}),
            };
            let _ = task_state.send(response);
        });
    }
    state.cancel_all();
    // Let cancellation finalize durable status and terminate command children.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(1), async {
        loop {
            if state.active.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    })
    .await;
    drop(state);
    Ok(())
}
