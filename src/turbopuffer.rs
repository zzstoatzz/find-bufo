//! turbopuffer vector database implementation
//!
//! implements the `VectorStore` trait for turbopuffer's hybrid search API.

use crate::providers::{SearchResult, VectorSearchError, VectorStore};
use reqwest::Client;
use serde::{Deserialize, Serialize};

const TURBOPUFFER_API_BASE: &str = "https://api.turbopuffer.com/v1/vectors";

/// raw response row from turbopuffer API
#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct QueryRow {
    pub id: String,
    pub dist: f32,
    pub attributes: serde_json::Map<String, serde_json::Value>,
}

impl From<QueryRow> for SearchResult {
    fn from(row: QueryRow) -> Self {
        let attributes = row
            .attributes
            .iter()
            .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
            .collect();

        SearchResult {
            id: row.id,
            score: row.dist,
            attributes,
        }
    }
}

#[derive(Debug, Deserialize)]
struct ErrorResponse {
    error: String,
    #[allow(dead_code)]
    status: String,
}

/// turbopuffer vector database client
///
/// supports both ANN vector search and BM25 full-text search.
#[derive(Clone)]
pub struct TurbopufferStore {
    client: Client,
    api_key: String,
    namespace: String,
}

impl TurbopufferStore {
    pub fn new(api_key: String, namespace: String) -> Self {
        Self {
            client: Client::new(),
            api_key,
            namespace,
        }
    }

    fn query_url(&self) -> String {
        format!("{}/{}/query", TURBOPUFFER_API_BASE, self.namespace)
    }

    async fn execute_query(
        &self,
        request: serde_json::Value,
    ) -> Result<Vec<QueryRow>, VectorSearchError> {
        let response = self
            .client
            .post(self.query_url())
            .header("Authorization", format!("Bearer {}", self.api_key))
            .json(&request)
            .send()
            .await?;

        if !response.status().is_success() {
            let status = response.status().as_u16();
            let body = response.text().await.unwrap_or_default();

            // check for specific error types
            if let Ok(error_resp) = serde_json::from_str::<ErrorResponse>(&body) {
                if error_resp.error.contains("too long") && error_resp.error.contains("max 1024") {
                    return Err(VectorSearchError::QueryTooLong {
                        message: error_resp.error,
                    });
                }
            }

            return Err(VectorSearchError::Api { status, body });
        }

        let body = response.text().await.map_err(|e| {
            VectorSearchError::Other(anyhow::anyhow!("failed to read response: {}", e))
        })?;

        serde_json::from_str(&body)
            .map_err(|e| VectorSearchError::Parse(format!("failed to parse response: {}", e)))
    }
}

impl VectorStore for TurbopufferStore {
    async fn search_by_vector(
        &self,
        embedding: &[f32],
        top_k: usize,
    ) -> Result<Vec<SearchResult>, VectorSearchError> {
        let request = serde_json::json!({
            "rank_by": ["vector", "ANN", embedding],
            "top_k": top_k,
            "include_attributes": ["url", "name", "filename"],
        });

        log::debug!(
            "turbopuffer vector query: {}",
            serde_json::to_string_pretty(&request).unwrap_or_default()
        );

        let rows = self.execute_query(request).await?;
        Ok(rows.into_iter().map(SearchResult::from).collect())
    }

    async fn search_by_keyword(
        &self,
        query: &str,
        top_k: usize,
    ) -> Result<Vec<SearchResult>, VectorSearchError> {
        let request = serde_json::json!({
            "rank_by": ["name", "BM25", query],
            "top_k": top_k,
            "include_attributes": ["url", "name", "filename"],
        });

        log::debug!(
            "turbopuffer BM25 query: {}",
            serde_json::to_string_pretty(&request).unwrap_or_default()
        );

        let rows = self.execute_query(request).await?;

        if let Some(first) = rows.first() {
            log::info!(
                "BM25 first result - id: {}, dist: {}, name: {:?}",
                first.id,
                first.dist,
                first.attributes.get("name")
            );
        }

        Ok(rows.into_iter().map(SearchResult::from).collect())
    }

    fn name(&self) -> &'static str {
        "turbopuffer"
    }
}

