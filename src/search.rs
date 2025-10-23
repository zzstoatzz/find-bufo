//! multimodal semantic search using early fusion embeddings
//!
//! this implementation uses voyage AI's multimodal-3 model which employs a
//! unified transformer encoder for early fusion of text and image modalities.
//!
//! ## approach
//!
//! - filename text (e.g., "bufo-jumping-on-bed" → "bufo jumping on bed") is combined
//!   with image content in a single embedding request
//! - the unified encoder processes both modalities together, creating a single 1024-dim
//!   vector that captures semantic meaning from both text and visual features
//! - vector search against turbopuffer using cosine distance similarity
//!
//! ## research backing
//!
//! voyage AI's multimodal-3 demonstrates 41.44% improvement on table/figure retrieval
//! tasks when combining text + images vs images alone, validating the early fusion approach.
//!
//! references:
//! - voyage multimodal embeddings: https://docs.voyageai.com/docs/multimodal-embeddings
//! - early fusion methodology: text and images are combined in the embedding generation
//!   phase rather than fusing separate embeddings (late fusion)

use crate::config::Config;
use crate::embedding::EmbeddingClient;
use crate::turbopuffer::{QueryRequest, TurbopufferClient};
use actix_web::{web, HttpResponse, Result as ActixResult};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub query: String,
    #[serde(default = "default_top_k")]
    pub top_k: usize,
}

fn default_top_k() -> usize {
    10
}

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub results: Vec<BufoResult>,
}

#[derive(Debug, Serialize)]
pub struct BufoResult {
    pub id: String,
    pub url: String,
    pub name: String,
    pub score: f32, // normalized 0-1 score for display
}

pub async fn search(
    query: web::Json<SearchQuery>,
    config: web::Data<Config>,
) -> ActixResult<HttpResponse> {
    let embedding_client = EmbeddingClient::new(config.voyage_api_key.clone());
    let tpuf_client = TurbopufferClient::new(
        config.turbopuffer_api_key.clone(),
        config.turbopuffer_namespace.clone(),
    );

    // run vector search
    let query_embedding = {
        let _span = logfire::span!("generate_embedding", query = &query.query);
        embedding_client
            .embed_text(&query.query)
            .await
            .map_err(|e| {
                logfire::error!("failed to generate embedding", error = e.to_string());
                actix_web::error::ErrorInternalServerError(format!(
                    "failed to generate embedding: {}",
                    e
                ))
            })?
    };

    let vector_request = QueryRequest {
        rank_by: vec![
            serde_json::json!("vector"),
            serde_json::json!("ANN"),
            serde_json::json!(query_embedding),
        ],
        top_k: query.top_k,
        include_attributes: Some(vec!["url".to_string(), "name".to_string(), "filename".to_string()]),
    };

    let vector_results = {
        let _span = logfire::span!("vector_search", top_k = query.top_k);
        tpuf_client.query(vector_request).await.map_err(|e| {
            logfire::error!("vector search failed", error = e.to_string());
            actix_web::error::ErrorInternalServerError(format!(
                "failed to query turbopuffer (vector): {}",
                e
            ))
        })?
    };

    // convert vector search results to bufo results
    // turbopuffer returns cosine distance (0 = identical, 2 = opposite)
    // convert to similarity score: 1 - (distance / 2) to get 0-1 range
    let results: Vec<BufoResult> = vector_results
        .into_iter()
        .map(|row| {
            let url = row
                .attributes
                .get("url")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let name = row
                .attributes
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or(&row.id)
                .to_string();

            // convert cosine distance to similarity score
            // turbopuffer's dist field contains the cosine distance
            // for now, use a placeholder score based on rank
            // TODO: extract actual distance from turbopuffer response
            let score = 1.0; // placeholder - turbopuffer doesn't return dist in current response

            BufoResult {
                id: row.id.clone(),
                url,
                name,
                score,
            }
        })
        .collect();

    logfire::info!("search completed",
        query = &query.query,
        results_count = results.len() as i64,
        top_score = results.first().map(|r| r.score as f64).unwrap_or(0.0)
    );

    Ok(HttpResponse::Ok().json(SearchResponse { results }))
}
