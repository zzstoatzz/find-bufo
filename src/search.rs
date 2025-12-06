//! hybrid search combining semantic embeddings with keyword matching
//!
//! this implementation uses weighted fusion to balance semantic understanding with exact matches.
//!
//! ## search components
//!
//! ### 1. semantic search (vector/ANN)
//! - voyage AI multimodal-3 embeddings via early fusion:
//!   - filename text (e.g., "bufo-jumping-on-bed" → "bufo jumping on bed") + image content
//!   - unified transformer encoder creates 1024-dim vectors
//!   - cosine distance similarity against turbopuffer
//! - **strength**: finds semantically related bufos (e.g., "happy" → excited, smiling bufos)
//! - **weakness**: may miss exact filename matches (e.g., "happy" might not surface "bufo-is-happy")
//!
//! ### 2. keyword search (BM25)
//! - full-text search on bufo `name` field (filename without extension)
//! - BM25 ranking: IDF-weighted term frequency with document length normalization
//! - **strength**: excellent for exact/partial matches (e.g., "jumping" → "bufos-jumping-on-the-bed")
//! - **weakness**: no semantic understanding (e.g., "happy" won't find "excited" or "smiling")
//!
//! ### 3. weighted fusion
//! - formula: `score = α * semantic + (1-α) * keyword`
//! - both scores normalized to 0-1 range before fusion
//! - configurable `alpha` parameter (default 0.7):
//!   - `α=1.0`: pure semantic (best for conceptual queries like "apocalyptic", "in a giving mood")
//!   - `α=0.7`: default (70% semantic, 30% keyword - balances both strengths)
//!   - `α=0.5`: balanced (equal weight to semantic and keyword signals)
//!   - `α=0.0`: pure keyword (best for exact filename searches)
//!
//! ## empirical behavior
//!
//! query: "happy", top_k=3
//! - α=1.0: ["proud-bufo-is-excited", "bufo-hehe", "bufo-excited"] (semantic similarity)
//! - α=0.5: ["bufo-is-happy-youre-happy", ...] (exact match rises to top)
//! - α=0.0: ["bufo-is-happy-youre-happy" (1.0), others (0.0)] (only exact matches score)
//!
//! ## references
//!
//! - voyage multimodal embeddings: https://docs.voyageai.com/docs/multimodal-embeddings
//! - turbopuffer BM25: https://turbopuffer.com/docs/fts
//! - weighted fusion: standard approach in modern hybrid search systems (2024)

use crate::config::Config;
use crate::embedding::EmbeddingClient;
use crate::turbopuffer::{QueryRequest, TurbopufferClient, TurbopufferError};
use actix_web::{web, HttpRequest, HttpResponse, Result as ActixResult};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub query: String,
    #[serde(default = "default_top_k")]
    pub top_k: usize,
    /// alpha parameter for weighted fusion (0.0 = pure keyword, 1.0 = pure semantic)
    /// default 0.7 favors semantic search while still considering exact matches
    #[serde(default = "default_alpha")]
    pub alpha: f32,
    /// family-friendly mode: filters out inappropriate content (default true)
    #[serde(default = "default_family_friendly")]
    pub family_friendly: bool,
    /// comma-separated glob patterns to exclude from results (e.g., "*party*,*sad*")
    #[serde(default)]
    pub exclude: Option<String>,
}

fn default_top_k() -> usize {
    10
}

fn default_alpha() -> f32 {
    0.7
}

fn default_family_friendly() -> bool {
    true
}

/// blocklist of inappropriate bufos (filtered when family_friendly=true)
fn get_inappropriate_bufos() -> Vec<&'static str> {
    vec![
        "bufo-juicy",
        "good-news-bufo-offers-suppository",
        "bufo-declines-your-suppository-offer",
        "tsa-bufo-gropes-you",
    ]
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

/// generate etag for caching based on query parameters
fn generate_etag(query: &str, top_k: usize, alpha: f32, family_friendly: bool, exclude: &Option<String>) -> String {
    let mut hasher = DefaultHasher::new();
    query.hash(&mut hasher);
    top_k.hash(&mut hasher);
    // convert f32 to bits for consistent hashing
    alpha.to_bits().hash(&mut hasher);
    family_friendly.hash(&mut hasher);
    exclude.hash(&mut hasher);
    format!("\"{}\"", hasher.finish())
}

/// shared search implementation used by both POST and GET handlers
async fn perform_search(
    query_text: String,
    top_k_val: usize,
    alpha: f32,
    family_friendly: bool,
    exclude: Option<String>,
    config: &Config,
) -> ActixResult<SearchResponse> {
    // parse and compile exclusion regex patterns from comma-separated string
    let exclude_patterns: Vec<Regex> = exclude
        .as_ref()
        .map(|s| {
            s.split(',')
                .map(|p| p.trim())
                .filter(|p| !p.is_empty())
                .filter_map(|p| Regex::new(p).ok()) // silently skip invalid patterns
                .collect()
        })
        .unwrap_or_default();

    let _search_span = logfire::span!(
        "bufo_search",
        query = &query_text,
        top_k = top_k_val as i64,
        alpha = alpha as f64,
        family_friendly = family_friendly,
        exclude_patterns_count = exclude_patterns.len() as i64
    ).entered();

    let exclude_patterns_str: String = exclude_patterns.iter().map(|r| r.as_str()).collect::<Vec<_>>().join(",");
    logfire::info!(
        "search request received",
        query = &query_text,
        top_k = top_k_val as i64,
        alpha = alpha as f64,
        exclude_patterns = &exclude_patterns_str
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
            query = &query_text,
            model = "voyage-3-lite"
        ).entered();

        embedding_client
            .embed_text(&query_text)
            .await
            .map_err(|e| {
                let error_msg = e.to_string();
                logfire::error!(
                    "embedding generation failed",
                    error = error_msg,
                    query = &query_text
                );
                actix_web::error::ErrorInternalServerError(format!(
                    "failed to generate embedding: {}",
                    e
                ))
            })?
    };

    logfire::info!(
        "embedding generated",
        query = &query_text,
        embedding_dim = query_embedding.len() as i64
    );

    // run vector search (semantic)
    // fetch extra results to ensure we have enough after filtering by family_friendly and exclude patterns
    let search_top_k = top_k_val * 5;
    let vector_request = QueryRequest {
        rank_by: vec![
            serde_json::json!("vector"),
            serde_json::json!("ANN"),
            serde_json::json!(query_embedding),
        ],
        top_k: search_top_k,
        include_attributes: Some(vec!["url".to_string(), "name".to_string(), "filename".to_string()]),
    };

    let namespace = config.turbopuffer_namespace.clone();
    let vector_results = {
        let _span = logfire::span!(
            "turbopuffer.vector_search",
            query = &query_text,
            top_k = search_top_k as i64,
            namespace = &namespace
        ).entered();

        tpuf_client.query(vector_request).await.map_err(|e| {
            let error_msg = e.to_string();
            logfire::error!(
                "vector search failed",
                error = error_msg,
                query = &query_text,
                top_k = search_top_k as i64
            );
            actix_web::error::ErrorInternalServerError(format!(
                "failed to query turbopuffer (vector): {}",
                e
            ))
        })?
    };

    logfire::info!(
        "vector search completed",
        query = &query_text,
        results_found = vector_results.len() as i64
    );

    // run BM25 text search (keyword)
    let bm25_results = {
        let _span = logfire::span!(
            "turbopuffer.bm25_search",
            query = &query_text,
            top_k = search_top_k as i64,
            namespace = &namespace
        ).entered();

        tpuf_client.bm25_query(&query_text, search_top_k).await.map_err(|e| {
            let error_msg = e.to_string();
            logfire::error!(
                "bm25 search failed",
                error = error_msg,
                query = &query_text,
                top_k = search_top_k as i64
            );

            // return appropriate HTTP status based on error type
            match e {
                TurbopufferError::QueryTooLong { .. } => {
                    actix_web::error::ErrorBadRequest(
                        "search query is too long (max 1024 characters for text search). try a shorter query."
                    )
                }
                _ => {
                    actix_web::error::ErrorInternalServerError(format!(
                        "failed to query turbopuffer (BM25): {}",
                        e
                    ))
                }
            }
        })?
    };

    // weighted fusion: combine vector and BM25 results
    use std::collections::HashMap;

    // normalize vector scores (cosine distance -> 0-1 similarity)
    let mut semantic_scores: HashMap<String, f32> = HashMap::new();
    for row in &vector_results {
        let score = 1.0 - (row.dist / 2.0);
        semantic_scores.insert(row.id.clone(), score);
    }

    // normalize BM25 scores using max normalization (BM25-max-scaled approach)
    // this preserves relative spacing and handles edge cases (single result, similar scores)
    // reference: https://opensourceconnections.com/blog/2023/02/27/hybrid-vigor-winning-at-hybrid-search/
    let bm25_scores_vec: Vec<f32> = bm25_results.iter().map(|r| r.dist).collect();
    let max_bm25 = bm25_scores_vec.iter().cloned().fold(f32::NEG_INFINITY, f32::max).max(0.001); // avoid division by zero

    let mut keyword_scores: HashMap<String, f32> = HashMap::new();
    for row in &bm25_results {
        // divide by max to ensure top result gets 1.0, others scale proportionally
        let normalized_score = (row.dist / max_bm25).min(1.0);
        keyword_scores.insert(row.id.clone(), normalized_score);
    }

    logfire::info!(
        "bm25 search completed",
        query = &query_text,
        results_found = bm25_results.len() as i64,
        max_bm25 = max_bm25 as f64,
        top_bm25_raw = bm25_scores_vec.first().copied().unwrap_or(0.0) as f64,
        top_bm25_normalized = keyword_scores.values().cloned().fold(f32::NEG_INFINITY, f32::max) as f64
    );

    // collect all unique results and compute weighted fusion scores
    let mut all_results: HashMap<String, crate::turbopuffer::QueryRow> = HashMap::new();
    for row in vector_results.into_iter().chain(bm25_results.into_iter()) {
        all_results.entry(row.id.clone()).or_insert(row);
    }

    let mut fused_scores: Vec<(String, f32)> = all_results
        .keys()
        .map(|id| {
            let semantic = semantic_scores.get(id).copied().unwrap_or(0.0);
            let keyword = keyword_scores.get(id).copied().unwrap_or(0.0);
            let fused = alpha * semantic + (1.0 - alpha) * keyword;
            (id.clone(), fused)
        })
        .collect();

    // filter out zero-scored results (irrelevant matches from the other search method)
    // this prevents vector-only results from appearing when alpha=0.0 (pure keyword)
    // and keyword-only results from appearing when alpha=1.0 (pure semantic)
    fused_scores.retain(|(_, score)| *score > 0.001);

    // sort by fused score (descending)
    fused_scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());

    logfire::info!(
        "weighted fusion completed",
        total_candidates = all_results.len() as i64,
        alpha = alpha as f64,
        pre_filter_results = fused_scores.len() as i64
    );

    // convert to bufo results and apply ALL filtering BEFORE truncating
    // this ensures we return top_k results after filtering, not fewer
    let inappropriate_bufos = get_inappropriate_bufos();
    let results: Vec<BufoResult> = fused_scores
        .into_iter()
        .filter_map(|(id, score)| {
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

                BufoResult {
                    id: row.id.clone(),
                    url,
                    name,
                    score,
                }
            })
        })
        .filter(|result| {
            // filter out inappropriate bufos if family_friendly mode is enabled
            if family_friendly && inappropriate_bufos.iter().any(|&blocked| result.name.contains(blocked)) {
                return false;
            }

            // filter out results matching any exclude regex pattern
            for pattern in &exclude_patterns {
                if pattern.is_match(&result.name) {
                    return false;
                }
            }

            true
        })
        .take(top_k_val) // take top_k AFTER filtering
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
        query = &query_text,
        results_count = results_count,
        top_result = &top_result_name,
        top_score = top_score_val,
        avg_score = avg_score_val
    );

    Ok(SearchResponse { results })
}

/// POST /api/search handler (existing API)
pub async fn search(
    query: web::Json<SearchQuery>,
    config: web::Data<Config>,
) -> ActixResult<HttpResponse> {
    let response = perform_search(
        query.query.clone(),
        query.top_k,
        query.alpha,
        query.family_friendly,
        query.exclude.clone(),
        &config
    ).await?;
    Ok(HttpResponse::Ok().json(response))
}

/// GET /api/search handler for shareable URLs
pub async fn search_get(
    query: web::Query<SearchQuery>,
    config: web::Data<Config>,
    req: HttpRequest,
) -> ActixResult<HttpResponse> {
    // generate etag for caching
    let etag = generate_etag(&query.query, query.top_k, query.alpha, query.family_friendly, &query.exclude);

    // check if client has cached version
    if let Some(if_none_match) = req.headers().get("if-none-match") {
        if if_none_match.to_str().unwrap_or("") == etag {
            return Ok(HttpResponse::NotModified()
                .insert_header(("etag", etag))
                .finish());
        }
    }

    let response = perform_search(
        query.query.clone(),
        query.top_k,
        query.alpha,
        query.family_friendly,
        query.exclude.clone(),
        &config
    ).await?;

    Ok(HttpResponse::Ok()
        .insert_header(("etag", etag.clone()))
        .insert_header(("cache-control", "public, max-age=300")) // cache for 5 minutes
        .json(response))
}
