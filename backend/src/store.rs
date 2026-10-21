use anyhow::{bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;
use uuid::Uuid;

pub const SCHEMA_VERSION: i64 = 1;

#[derive(Clone, Serialize, Deserialize)]
pub struct ThreadRecord {
    pub id: String,
    pub cwd: String,
    pub developer_instructions: String,
    pub dynamic_tools: Vec<Value>,
    pub model: Option<String>,
}

pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let mut connection = Connection::open(path).context("Cannot open application database")?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "foreign_keys", true)?;
        let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            bail!("Database schema is newer than this backend");
        }
        if version == 0 {
            let transaction = connection.transaction()?;
            transaction.execute_batch(
                "CREATE TABLE threads (
                  id TEXT PRIMARY KEY, cwd TEXT NOT NULL, developer_instructions TEXT NOT NULL,
                  dynamic_tools TEXT NOT NULL, model TEXT, created_at INTEGER NOT NULL DEFAULT(unixepoch()),
                  updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
                 CREATE TABLE turns (
                  id TEXT PRIMARY KEY, thread_id TEXT NOT NULL REFERENCES threads(id), status TEXT NOT NULL,
                  error TEXT, started_at INTEGER NOT NULL DEFAULT(unixepoch()), completed_at INTEGER);
                 CREATE TABLE messages (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT NOT NULL REFERENCES threads(id),
                  turn_id TEXT NOT NULL REFERENCES turns(id), payload TEXT NOT NULL,
                  created_at INTEGER NOT NULL DEFAULT(unixepoch()));
                 CREATE INDEX messages_by_thread ON messages(thread_id,id);
                 CREATE TABLE events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, thread_id TEXT, turn_id TEXT,
                  method TEXT NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT(unixepoch()));
                 CREATE INDEX events_by_thread ON events(thread_id,id);
                 CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 PRAGMA user_version=1;",
            )?;
            transaction.commit()?;
        }
        // A crashed process cannot leave a supposedly active turn forever.
        connection.execute(
            "UPDATE turns SET status='interrupted', error='Backend restarted', completed_at=unixepoch() WHERE status='inProgress'",
            [],
        )?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
            for suffix in ["-wal", "-shm"] {
                let sidecar = std::path::PathBuf::from(format!("{}{suffix}", path.display()));
                if sidecar.exists() {
                    std::fs::set_permissions(sidecar, std::fs::Permissions::from_mode(0o600))?;
                }
            }
        }
        Ok(Self { connection })
    }

    pub fn create_thread(
        &mut self,
        cwd: String,
        instructions: String,
        tools: Vec<Value>,
        model: Option<String>,
    ) -> Result<ThreadRecord> {
        let thread = ThreadRecord {
            id: Uuid::new_v4().to_string(),
            cwd,
            developer_instructions: instructions,
            dynamic_tools: tools,
            model,
        };
        self.connection.execute(
            "INSERT INTO threads(id,cwd,developer_instructions,dynamic_tools,model) VALUES(?1,?2,?3,?4,?5)",
            params![thread.id, thread.cwd, thread.developer_instructions, serde_json::to_string(&thread.dynamic_tools)?, thread.model],
        )?;
        Ok(thread)
    }

    pub fn thread(&self, id: &str) -> Result<ThreadRecord> {
        let record = self
            .connection
            .query_row(
                "SELECT id,cwd,developer_instructions,dynamic_tools,model FROM threads WHERE id=?1",
                [id],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, Option<String>>(4)?,
                    ))
                },
            )
            .optional()?
            .context("Unknown thread")?;
        Ok(ThreadRecord {
            id: record.0,
            cwd: record.1,
            developer_instructions: record.2,
            dynamic_tools: serde_json::from_str(&record.3)?,
            model: record.4,
        })
    }

    pub fn update_thread(&mut self, thread: &ThreadRecord) -> Result<()> {
        self.connection.execute("UPDATE threads SET cwd=?2,developer_instructions=?3,dynamic_tools=?4,model=?5,updated_at=unixepoch() WHERE id=?1",
            params![thread.id,thread.cwd,thread.developer_instructions,serde_json::to_string(&thread.dynamic_tools)?,thread.model])?;
        Ok(())
    }

    pub fn create_turn(&mut self, thread: &str, id: &str) -> Result<()> {
        self.connection.execute(
            "INSERT INTO turns(id,thread_id,status) VALUES(?1,?2,'inProgress')",
            params![id, thread],
        )?;
        self.connection.execute(
            "UPDATE threads SET updated_at=unixepoch() WHERE id=?1",
            [thread],
        )?;
        Ok(())
    }

    pub fn finish_turn(&mut self, id: &str, status: &str, error: Option<&str>) -> Result<()> {
        self.connection.execute(
            "UPDATE turns SET status=?2,error=?3,completed_at=unixepoch() WHERE id=?1",
            params![id, status, error],
        )?;
        Ok(())
    }

    pub fn add_message(&mut self, thread: &str, turn: &str, message: &Value) -> Result<()> {
        let payload = serde_json::to_string(message)?;
        if payload.len() > 1024 * 1024 {
            bail!("Message exceeds the 1 MB persistence limit");
        }
        self.connection.execute(
            "INSERT INTO messages(thread_id,turn_id,payload) VALUES(?1,?2,?3)",
            params![thread, turn, payload],
        )?;
        Ok(())
    }

    pub fn messages(&self, thread: &str) -> Result<Vec<Value>> {
        let mut query = self.connection.prepare(
            "SELECT payload FROM messages WHERE thread_id=?1 ORDER BY id DESC LIMIT 240",
        )?;
        let rows = query.query_map([thread], |r| r.get::<_, String>(0))?;
        let mut messages = Vec::new();
        let mut bytes = 0usize;
        for row in rows {
            let text = row?;
            bytes += text.len();
            if bytes > 4 * 1024 * 1024 {
                break;
            }
            messages.push(serde_json::from_str::<Value>(&text)?);
        }
        messages.reverse();
        // Never start a truncated history with an orphaned tool response.
        if let Some(first_user) = messages.iter().position(|m| m["role"] == "user") {
            messages.drain(..first_user);
        } else {
            messages.clear();
        }
        Ok(messages)
    }

    pub fn turns(&self, thread: &str) -> Result<Vec<Value>> {
        let mut query = self.connection.prepare("SELECT id,status,error,started_at,completed_at FROM turns WHERE thread_id=?1 ORDER BY started_at DESC,rowid DESC LIMIT 100")?;
        let rows = query.query_map([thread], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, Option<i64>>(4)?,
            ))
        })?;
        let mut values=rows.map(|row| {let (id,status,error,start,end)=row?;Ok(json!({"id":id,"status":status,"items":[],"error":error.map(|message|json!({"message":message})),"startedAt":start,"completedAt":end}))}).collect::<Result<Vec<_>>>()?;
        values.reverse();
        Ok(values)
    }

    pub fn add_event(&mut self, method: &str, params: &Value) -> Result<()> {
        let payload = serde_json::to_string(params)?;
        if payload.len() > 1024 * 1024 {
            bail!("Event exceeds the 1 MB persistence limit");
        }
        self.connection.execute(
            "INSERT INTO events(thread_id,turn_id,method,payload) VALUES(?1,?2,?3,?4)",
            params![
                params.get("threadId").and_then(Value::as_str),
                params.get("turnId").and_then(Value::as_str),
                method,
                payload
            ],
        )?;
        if self.connection.last_insert_rowid() % 128 == 0 {
            self.connection.execute("DELETE FROM events WHERE id < (SELECT id FROM events ORDER BY id DESC LIMIT 1 OFFSET 9999)",[])?;
        }
        Ok(())
    }

    pub fn put_config(&mut self, key: &str, value: &Value) -> Result<()> {
        reject_secrets(value)?;
        let encoded = serde_json::to_string(value)?;
        if encoded.len() > 4 * 1024 * 1024 {
            bail!("Application state exceeds the 4 MB limit");
        }
        self.connection.execute("INSERT INTO config(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",params![key,encoded])?;
        Ok(())
    }

    pub fn config(&self, key: &str) -> Result<Option<Value>> {
        let value: Option<String> = self
            .connection
            .query_row("SELECT value FROM config WHERE key=?1", [key], |r| r.get(0))
            .optional()?;
        value.map(|s| Ok(serde_json::from_str(&s)?)).transpose()
    }

    pub fn write_app_state(&mut self, state: Value, revision: i64) -> Result<()> {
        if revision < 0 {
            bail!("State revision cannot be negative");
        }
        reject_secrets(&state)?;
        if let Some(current) = self.config("app_state")? {
            let old = current["revision"].as_i64().unwrap_or(-1);
            if revision < old || (revision == old && current["state"] != state) {
                bail!("State revision conflict; reload the latest app state");
            }
        }
        self.put_config("app_state", &json!({"state":state,"revision":revision}))
    }
}

fn reject_secrets(value: &Value) -> Result<()> {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
                if [
                    "apikey",
                    "accesstoken",
                    "refreshtoken",
                    "authorization",
                    "password",
                ]
                .contains(&normalized.as_str())
                {
                    bail!("Secrets must remain in Keychain, not SQLite configuration");
                }
                reject_secrets(value)?;
            }
        }
        Value::Array(values) => {
            for value in values {
                reject_secrets(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn durable_threads_messages_and_revision_conflicts() -> Result<()> {
        let dir = std::env::temp_dir().join(format!("myagent-store-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir)?;
        let path = dir.join("test.sqlite");
        let id;
        {
            let mut store = Store::open(&path)?;
            let thread = store.create_thread(
                dir.display().to_string(),
                "instructions".into(),
                vec![json!({"name":"test"})],
                None,
            )?;
            id = thread.id;
            store.create_turn(&id, "turn")?;
            store.add_message(&id, "turn", &json!({"role":"user","content":"hello"}))?;
            store.write_app_state(json!({"tasks":[]}), 2)?;
            let version: i64 = store
                .connection
                .pragma_query_value(None, "user_version", |r| r.get(0))?;
            assert_eq!(version, SCHEMA_VERSION);
            assert!(store.write_app_state(json!({}), 1).is_err());
            assert!(store.write_app_state(json!({"different":true}), 2).is_err());
            store.write_app_state(json!({"tasks":[]}), 2)?;
            assert!(store
                .put_config("provider", &json!({"apiKey":"secret"}))
                .is_err());
        }
        {
            let store = Store::open(&path)?;
            assert_eq!(store.thread(&id)?.developer_instructions, "instructions");
            assert_eq!(store.messages(&id)?.len(), 1);
            assert_eq!(store.turns(&id)?[0]["status"], "interrupted");
            assert_eq!(store.config("app_state")?.unwrap()["revision"], 2);
        }
        std::fs::remove_dir_all(dir)?;
        Ok(())
    }

    #[test]
    fn rejects_unknown_future_migration() -> Result<()> {
        let dir = std::env::temp_dir().join(format!("myagent-schema-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir)?;
        let path = dir.join("test.sqlite");
        {
            let store = Store::open(&path)?;
            store
                .connection
                .pragma_update(None, "user_version", SCHEMA_VERSION + 1)?;
        }
        assert!(Store::open(&path).is_err());
        std::fs::remove_dir_all(dir)?;
        Ok(())
    }
}
