//! JSON-lines integration driver for the real application API.
//! Deliberately emits requested data to stdout; use only synthetic test clips.
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    let mut output = tokio::io::stdout();
    while let Some(line) = input.next_line().await? {
        if line.len() > 24 * 1024 * 1024 {
            output
                .write_all(b"{\"error\":\"Request exceeds driver limit\"}\n")
                .await?;
            continue;
        }
        let result = match arcade_core::api::call(line).await {
            Ok(response) => match serde_json::from_str::<serde_json::Value>(&response) {
                Ok(value) => serde_json::json!({"ok": value}),
                Err(_) => serde_json::json!({"error": "Core returned invalid JSON"}),
            },
            Err(message) => serde_json::json!({"error": message}),
        };
        output
            .write_all(serde_json::to_string(&result)?.as_bytes())
            .await?;
        output.write_all(b"\n").await?;
        output.flush().await?;
    }
    Ok(())
}
