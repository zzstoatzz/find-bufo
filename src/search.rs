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

    // Run vector search
    let query_embedding = embedding_client
        .embed_text(&query.query)
        .await
        .map_err(|e| {
            log::error!("failed to generate embedding: {}", e);
            actix_web::error::ErrorInternalServerError(format!(
                "failed to generate embedding: {}",
                e
            ))
        })?;

    let vector_request = QueryRequest {
        rank_by: vec![
            serde_json::json!("vector"),
            serde_json::json!("ANN"),
            serde_json::json!(query_embedding),
        ],
        top_k: query.top_k * 2, // get more results for fusion
        include_attributes: Some(vec!["url".to_string(), "name".to_string(), "filename".to_string()]),
    };

    let vector_results = tpuf_client.query(vector_request).await.map_err(|e| {
        log::error!("failed to query turbopuffer (vector): {}", e);
        actix_web::error::ErrorInternalServerError(format!(
            "failed to query turbopuffer (vector): {}",
            e
        ))
    })?;

    // Run BM25 text search
    let bm25_results = tpuf_client.bm25_query(&query.query, query.top_k * 2).await.map_err(|e| {
        log::error!("failed to query turbopuffer (BM25): {}", e);
        actix_web::error::ErrorInternalServerError(format!(
            "failed to query turbopuffer (BM25): {}",
            e
        ))
    })?;

    // Combine results using Reciprocal Rank Fusion (RRF)
    use std::collections::HashMap;
    let mut rrf_scores: HashMap<String, f32> = HashMap::new();
    let k = 60.0; // RRF constant

    // Add vector search rankings
    for (rank, row) in vector_results.iter().enumerate() {
        let score = 1.0 / (k + (rank as f32) + 1.0);
        *rrf_scores.entry(row.id.clone()).or_insert(0.0) += score;
    }

    // Add BM25 search rankings
    for (rank, row) in bm25_results.iter().enumerate() {
        let score = 1.0 / (k + (rank as f32) + 1.0);
        *rrf_scores.entry(row.id.clone()).or_insert(0.0) += score;
    }

    // Collect all unique results
    let mut all_results: HashMap<String, crate::turbopuffer::QueryRow> = HashMap::new();
    for row in vector_results.into_iter().chain(bm25_results.into_iter()) {
        all_results.entry(row.id.clone()).or_insert(row);
    }

    // Sort by RRF score and take top_k
    let mut scored_results: Vec<(String, f32)> = rrf_scores.into_iter().collect();
    scored_results.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    scored_results.truncate(query.top_k);

    // Normalize scores to 0-0.95 range
    let max_score = scored_results.first().map(|(_, s)| *s).unwrap_or(1.0);
    let min_score = scored_results.last().map(|(_, s)| *s).unwrap_or(0.0);
    let score_range = (max_score - min_score).max(0.001); // avoid division by zero

    let results: Vec<BufoResult> = scored_results
        .into_iter()
        .filter_map(|(id, raw_score)| {
            all_results.get(&id).map(|row| {
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

                // Normalize score to 0-0.95 range
                let normalized_score = ((raw_score - min_score) / score_range) * 0.95;

                BufoResult {
                    id: row.id.clone(),
                    url,
                    name,
                    score: normalized_score,
                }
            })
        })
        .collect();

    Ok(HttpResponse::Ok().json(SearchResponse { results }))
}
