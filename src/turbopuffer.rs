use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TurbopufferError {
    #[error("query too long: {message}")]
    QueryTooLong { message: String },
    #[error("turbopuffer API error: {0}")]
    ApiError(String),
    #[error("request failed: {0}")]
    RequestFailed(#[from] reqwest::Error),
    #[error("{0}")]
    Other(#[from] anyhow::Error),
}

#[derive(Debug, Deserialize)]
struct TurbopufferErrorResponse {
    error: String,
    #[allow(dead_code)]
    status: String,
}

#[derive(Debug, Serialize)]
pub struct QueryRequest {
    pub rank_by: Vec<serde_json::Value>,
    pub top_k: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_attributes: Option<Vec<String>>,
}

pub type QueryResponse = Vec<QueryRow>;

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct QueryRow {
    pub id: String,
    pub dist: f32, // for vector: cosine distance; for BM25: BM25 score
    pub attributes: serde_json::Map<String, serde_json::Value>,
}

pub struct TurbopufferClient {
    client: Client,
    api_key: String,
    namespace: String,
}

impl TurbopufferClient {
    pub fn new(api_key: String, namespace: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
            namespace,
        }
    }

    pub async fn query(&self, request: QueryRequest) -> Result<QueryResponse> {
        let url = format!(
            "https://api.turbopuffer.com/v1/vectors/{}/query",
            self.namespace
        );

        let request_json = serde_json::to_string_pretty(&request)?;
        log::debug!("turbopuffer query request: {}", request_json);

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await
            .context("failed to send query request")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("turbopuffer query failed with status {}: {}", status, body);
        }

        let body = response.text().await.context("failed to read response body")?;

        serde_json::from_str(&body)
            .context(format!("failed to parse query response: {}", body))
    }

    pub async fn bm25_query(&self, query_text: &str, top_k: usize) -> Result<QueryResponse, TurbopufferError> {
        let url = format!(
            "https://api.turbopuffer.com/v1/vectors/{}/query",
            self.namespace
        );

        let request = serde_json::json!({
            "rank_by": ["name", "BM25", query_text],
            "top_k": top_k,
            "include_attributes": ["url", "name", "filename"],
        });

        if let Ok(pretty) = serde_json::to_string_pretty(&request) {
            log::debug!("turbopuffer BM25 query request: {}", pretty);
        }

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();

            // try to parse turbopuffer error response
            if let Ok(error_resp) = serde_json::from_str::<TurbopufferErrorResponse>(&body) {
                // check if it's a query length error
                if error_resp.error.contains("too long") && error_resp.error.contains("max 1024") {
                    return Err(TurbopufferError::QueryTooLong {
                        message: error_resp.error,
                    });
                }
            }

            return Err(TurbopufferError::ApiError(format!(
                "turbopuffer BM25 query failed with status {}: {}",
                status, body
            )));
        }

        let body = response.text().await
            .map_err(|e| TurbopufferError::Other(anyhow::anyhow!("failed to read response body: {}", e)))?;
        log::debug!("turbopuffer BM25 response: {}", body);

        let parsed: QueryResponse = serde_json::from_str(&body)
            .map_err(|e| TurbopufferError::Other(anyhow::anyhow!("failed to parse BM25 query response: {}", e)))?;

        // DEBUG: log first result to see what BM25 returns
        if let Some(first) = parsed.first() {
            log::info!("BM25 first result - id: {}, dist: {}, name: {:?}",
                first.id,
                first.dist,
                first.attributes.get("name")
            );
        }

        Ok(parsed)
    }
}
