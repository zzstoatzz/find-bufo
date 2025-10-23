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
    let query_text = &query.query;
    let top_k_val = query.top_k;

    let _search_span = logfire::span!(
        "bufo_search",
        query = query_text,
        top_k = top_k_val as i64
    );

    logfire::info!(
        "search request received",
        query = query_text,
        top_k = top_k_val as i64
    );

    let embedding_client = EmbeddingClient::new(config.voyage_api_key.clone());
    let tpuf_client = TurbopufferClient::new(
        config.turbopuffer_api_key.clone(),
        config.turbopuffer_namespace.clone(),
    );

    // generate embedding for user query
    let query_embedding = {
        let _span = logfire::span!(
            "voyage.embed_text",
            query = query_text,
            model = "voyage-3-lite"
        );
        embedding_client
            .embed_text(query_text)
            .await
            .map_err(|e| {
                let error_msg = e.to_string();
                logfire::error!(
                    "embedding generation failed",
                    error = error_msg,
                    query = query_text
                );
                actix_web::error::ErrorInternalServerError(format!(
                    "failed to generate embedding: {}",
                    e
                ))
            })?
    };

    logfire::info!(
        "embedding generated",
        query = query_text,
        embedding_dim = query_embedding.len() as i64
    );

    let vector_request = QueryRequest {
        rank_by: vec![
            serde_json::json!("vector"),
            serde_json::json!("ANN"),
            serde_json::json!(query_embedding),
        ],
        top_k: query.top_k,
        include_attributes: Some(vec!["url".to_string(), "name".to_string(), "filename".to_string()]),
    };

    let namespace = &config.turbopuffer_namespace;
    let vector_results = {
        let _span = logfire::span!(
            "turbopuffer.query",
            query = query_text,
            top_k = top_k_val as i64,
            namespace = namespace
        );
        tpuf_client.query(vector_request).await.map_err(|e| {
            let error_msg = e.to_string();
            logfire::error!(
                "vector search failed",
                error = error_msg,
                query = query_text,
                top_k = top_k_val as i64
            );
            actix_web::error::ErrorInternalServerError(format!(
                "failed to query turbopuffer (vector): {}",
                e
            ))
        })?
    };

    let min_dist = vector_results.iter().map(|r| r.dist).min_by(|a, b| a.partial_cmp(b).unwrap()).unwrap_or(0.0) as f64;
    let max_dist = vector_results.iter().map(|r| r.dist).max_by(|a, b| a.partial_cmp(b).unwrap()).unwrap_or(0.0) as f64;
    let results_found = vector_results.len() as i64;

    logfire::info!(
        "vector search completed",
        query = query_text,
        results_found = results_found,
        min_dist = min_dist,
        max_dist = max_dist
    );

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

            // convert cosine distance to similarity score (0-1 range)
            let score = 1.0 - (row.dist / 2.0);

            BufoResult {
                id: row.id.clone(),
                url,
                name,
                score,
            }
        })
        .collect();

    let results_count = results.len() as i64;
    let top_result_name = results.first().map(|r| r.name.clone()).unwrap_or_else(|| "none".to_string());
    let top_score_val = results.first().map(|r| r.score as f64).unwrap_or(0.0);
    let avg_score_val = if !results.is_empty() {
        results.iter().map(|r| r.score as f64).sum::<f64>() / results.len() as f64
    } else {
        0.0
    };

    logfire::info!(
        "search completed successfully",
        query = query_text,
        results_count = results_count,
        top_result = &top_result_name,
        top_score = top_score_val,
        avg_score = avg_score_val
    );

    Ok(HttpResponse::Ok().json(SearchResponse { results }))
}
