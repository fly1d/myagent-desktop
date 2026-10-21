use anyhow::{Context, Result};
use myagent_backend::{dispatch, store::Store, State};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

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
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(message) = receiver.recv().await {
            let mut bytes = serde_json::to_vec(&message)?;
            bytes.push(b'\n');
            stdout.write_all(&bytes).await?;
            stdout.flush().await?;
        }
        Ok::<(), anyhow::Error>(())
    });
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut buffer = Vec::new();
    let mut initialized = false;
    loop {
        buffer.clear();
        // read_until alone has no frame bound: cap the underlying reader per frame.
        use tokio::io::AsyncReadExt;
        let count = (&mut stdin)
            .take(8 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut buffer)
            .await?;
        if count == 0 {
            break;
        }
        if buffer.len() > 8 * 1024 * 1024 {
            break;
        }
        let message: Value = match serde_json::from_slice(&buffer) {
            Ok(m) => m,
            Err(_) => {
                state.send(json!({"id":null,"error":{"code":-32700,"message":"Invalid JSON"}}))?;
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
                state.send(
                    json!({"id":id,"error":{"code":-32600,"message":"Already initialized"}}),
                )?;
                continue;
            }
            initialized = true;
        } else if !initialized {
            state.send(json!({"id":id,"error":{"code":-32600,"message":"Not initialized"}}))?;
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
    // A brief cancellation window lets running tools kill their child processes.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    drop(state);
    writer.abort();
    Ok(())
}
