use anyhow::{Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize)]
pub struct UpsertRequest {
    pub ids: Vec<String>,
    pub vectors: Vec<Vec<f32>>,
    pub attributes: serde_json::Value,
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
    pub dist: Option<f32>,
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

    pub async fn upsert(&self, request: UpsertRequest) -> Result<()> {
        let url = format!(
            "https://api.turbopuffer.com/v1/vectors/{}",
            self.namespace
        );

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await
            .context("failed to send upsert request")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!(
                "turbopuffer upsert failed with status {}: {}",
                status,
                body
            );
        }

        Ok(())
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
        log::debug!("turbopuffer response: {}", body);

        serde_json::from_str(&body)
            .context(format!("failed to parse query response: {}", body))
    }

    pub async fn bm25_query(&self, query_text: &str, top_k: usize) -> Result<QueryResponse> {
        let url = format!(
            "https://api.turbopuffer.com/v1/vectors/{}/query",
            self.namespace
        );

        let request = serde_json::json!({
            "rank_by": ["name", "BM25", query_text],
            "top_k": top_k,
            "include_attributes": ["url", "name", "filename"],
        });

        log::debug!("turbopuffer BM25 query request: {}", serde_json::to_string_pretty(&request)?);

        let response = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await
            .context("failed to send BM25 query request")?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!("turbopuffer BM25 query failed with status {}: {}", status, body);
        }

        let body = response.text().await.context("failed to read response body")?;
        log::debug!("turbopuffer BM25 response: {}", body);

        serde_json::from_str(&body)
            .context(format!("failed to parse BM25 query response: {}", body))
    }
}
