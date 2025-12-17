//! voyage AI embedding implementation
//!
//! implements the `Embedder` trait for voyage's multimodal-3 model.

use crate::providers::{Embedder, EmbeddingError};
use reqwest::Client;
use serde::{Deserialize, Serialize};

const VOYAGE_API_URL: &str = "https://api.voyageai.com/v1/multimodalembeddings";
const VOYAGE_MODEL: &str = "voyage-multimodal-3";

#[derive(Debug, Serialize)]
struct VoyageRequest {
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
struct VoyageResponse {
    data: Vec<VoyageEmbeddingData>,
}

#[derive(Debug, Deserialize)]
struct VoyageEmbeddingData {
    embedding: Vec<f32>,
}

/// voyage AI multimodal embedding client
///
/// uses the voyage-multimodal-3 model which produces 1024-dimensional vectors.
/// designed for early fusion of text and image content.
#[derive(Clone)]
pub struct VoyageEmbedder {
    client: Client,
    api_key: String,
}

impl VoyageEmbedder {
    pub fn new(api_key: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
        }
    }
}

impl Embedder for VoyageEmbedder {
    async fn embed(&self, text: &str) -> Result<Vec<f32>, EmbeddingError> {
        let request = VoyageRequest {
            inputs: vec![MultimodalInput {
                content: vec![ContentSegment::Text {
                    text: text.to_string(),
                }],
            }],
            model: VOYAGE_MODEL.to_string(),
            input_type: Some("query".to_string()),
        };

        let response = self
            .client
            .post(VOYAGE_API_URL)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status().as_u16();
            let body = response.text().await.unwrap_or_default();
            return Err(EmbeddingError::Api { status, body });
        }

        let voyage_response: VoyageResponse = response.json().await.map_err(|e| {
            EmbeddingError::Other(anyhow::anyhow!("failed to parse response: {}", e))
        })?;

        voyage_response
            .data
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .ok_or(EmbeddingError::EmptyResponse)
    }

    fn name(&self) -> &'static str {
        "voyage-multimodal-3"
    }
}

