use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
struct VoyageEmbeddingRequest {
    inputs: Vec<MultimodalInput>,
    model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    input_type: Option<String>,
}

#[derive(Debug, Serialize)]
struct MultimodalInput {
    content: Vec<ContentSegment>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ContentSegment {
    Text { text: String },
}

#[derive(Debug, Deserialize)]
struct VoyageEmbeddingResponse {
    data: Vec<VoyageEmbeddingData>,
}

#[derive(Debug, Deserialize)]
struct VoyageEmbeddingData {
    embedding: Vec<f32>,
}

pub struct EmbeddingClient {
    client: Client,
    api_key: String,
}

impl EmbeddingClient {
    pub fn new(api_key: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
        }
    }

    pub async fn embed_text(&self, text: &str) -> Result<Vec<f32>> {
        let request = VoyageEmbeddingRequest {
            inputs: vec![MultimodalInput {
                content: vec![ContentSegment::Text {
                    text: text.to_string(),
                }],
            }],
            model: "voyage-multimodal-3".to_string(),
            input_type: Some("query".to_string()),
        };

        let response = self
            .client
            .post("https://api.voyageai.com/v1/multimodalembeddings")
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await
            .context("failed to send embedding request")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("voyage api error ({}): {}", status, body);
        }

        let embedding_response: VoyageEmbeddingResponse = response
            .json()
            .await
            .context("failed to parse embedding response")?;

        let embedding = embedding_response
            .data
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .context("no embedding returned")?;

        Ok(embedding)
    }
}
