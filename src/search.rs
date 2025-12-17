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
//! ## references
//!
//! - voyage multimodal embeddings: https://docs.voyageai.com/docs/multimodal-embeddings
//! - turbopuffer BM25: https://turbopuffer.com/docs/fts
//! - weighted fusion: standard approach in modern hybrid search systems (2024)

use crate::config::Config;
use crate::embedding::VoyageEmbedder;
use crate::filter::{ContentFilter, Filter, Filterable};
use crate::providers::{Embedder, VectorSearchError, VectorStore};
use crate::scoring::{cosine_distance_to_similarity, fuse_scores, normalize_bm25_scores, FusionConfig};
use crate::turbopuffer::TurbopufferStore;
use actix_web::{web, HttpRequest, HttpResponse, Result as ActixResult};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
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
    /// comma-separated regex patterns to exclude from results (e.g., "excited,party")
    #[serde(default)]
    pub exclude: Option<String>,
    /// comma-separated regex patterns to include (overrides exclude)
    #[serde(default)]
    pub include: Option<String>,
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

#[derive(Debug, Serialize)]
pub struct SearchResponse {
    pub results: Vec<BufoResult>,
}

#[derive(Debug, Serialize, Clone)]
pub struct BufoResult {
    pub id: String,
    pub url: String,
    pub name: String,
    pub score: f32,
}

impl Filterable for BufoResult {
    fn name(&self) -> &str {
        &self.name
    }
}

/// errors that can occur during search
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("embedding error: {0}")]
    Embedding(#[from] crate::providers::EmbeddingError),

    #[error("vector search error: {0}")]
    VectorSearch(#[from] VectorSearchError),
}

impl SearchError {
    fn into_actix_error(self) -> actix_web::Error {
        match &self {
            SearchError::VectorSearch(VectorSearchError::QueryTooLong { .. }) => {
                actix_web::error::ErrorBadRequest(
                    "search query is too long (max 1024 characters for text search). try a shorter query."
                )
            }
            _ => actix_web::error::ErrorInternalServerError(self.to_string()),
        }
    }
}

/// generate etag for caching based on query parameters
fn generate_etag(
    query: &str,
    top_k: usize,
    alpha: f32,
    family_friendly: bool,
    exclude: &Option<String>,
    include: &Option<String>,
) -> String {
    let mut hasher = DefaultHasher::new();
    query.hash(&mut hasher);
    top_k.hash(&mut hasher);
    alpha.to_bits().hash(&mut hasher);
    family_friendly.hash(&mut hasher);
    exclude.hash(&mut hasher);
    include.hash(&mut hasher);
    format!("\"{}\"", hasher.finish())
}

/// execute hybrid search using the provided embedder and vector store
async fn execute_hybrid_search<E: Embedder, V: VectorStore>(
    query: &str,
    top_k: usize,
    fusion_config: &FusionConfig,
    embedder: &E,
    vector_store: &V,
) -> Result<Vec<(String, f32, HashMap<String, String>)>, SearchError> {
    // fetch extra results to ensure we have enough after filtering
    let search_top_k = top_k * 5;
    let query_owned = query.to_string();

    // generate query embedding
    let _embed_span = logfire::span!(
        "embedding.generate",
        query = &query_owned,
        model = embedder.name()
    )
    .entered();

    let query_embedding = embedder.embed(query).await?;

    logfire::info!(
        "embedding generated",
        query = &query_owned,
        embedding_dim = query_embedding.len() as i64
    );

    // run both searches in sequence (could parallelize with tokio::join! if needed)
    let namespace = vector_store.name().to_string();

    let vector_results = {
        let _span = logfire::span!(
            "turbopuffer.vector_search",
            query = &query_owned,
            top_k = search_top_k as i64,
            namespace = &namespace
        )
        .entered();

        vector_store
            .search_by_vector(&query_embedding, search_top_k)
            .await?
    };

    logfire::info!(
        "vector search completed",
        query = &query_owned,
        results_found = vector_results.len() as i64
    );

    let bm25_results = {
        let _span = logfire::span!(
            "turbopuffer.bm25_search",
            query = &query_owned,
            top_k = search_top_k as i64,
            namespace = &namespace
        )
        .entered();

        vector_store.search_by_keyword(query, search_top_k).await?
    };

    // normalize scores
    let semantic_scores: HashMap<String, f32> = vector_results
        .iter()
        .map(|r| (r.id.clone(), cosine_distance_to_similarity(r.score)))
        .collect();

    let bm25_raw: Vec<(String, f32)> = bm25_results
        .iter()
        .map(|r| (r.id.clone(), r.score))
        .collect();
    let keyword_scores = normalize_bm25_scores(&bm25_raw);

    let max_bm25 = bm25_raw
        .iter()
        .map(|(_, s)| *s)
        .fold(f32::NEG_INFINITY, f32::max);

    logfire::info!(
        "bm25 search completed",
        query = &query_owned,
        results_found = bm25_results.len() as i64,
        max_bm25 = max_bm25 as f64,
        top_bm25_raw = bm25_raw.first().map(|(_, s)| *s).unwrap_or(0.0) as f64
    );

    // fuse scores
    let fused = fuse_scores(&semantic_scores, &keyword_scores, fusion_config);

    logfire::info!(
        "weighted fusion completed",
        total_candidates = (vector_results.len() + bm25_results.len()) as i64,
        alpha = fusion_config.alpha as f64,
        pre_filter_results = fused.len() as i64
    );

    // collect attributes from both result sets
    let mut all_attributes: HashMap<String, HashMap<String, String>> = HashMap::new();
    for result in vector_results.into_iter().chain(bm25_results.into_iter()) {
        all_attributes
            .entry(result.id.clone())
            .or_insert(result.attributes);
    }

    // return fused results with attributes
    Ok(fused
        .into_iter()
        .map(|(id, score)| {
            let attrs = all_attributes.remove(&id).unwrap_or_default();
            (id, score, attrs)
        })
        .collect())
}

/// shared search implementation used by both POST and GET handlers
async fn perform_search(
    query_text: String,
    top_k_val: usize,
    alpha: f32,
    family_friendly: bool,
    exclude: Option<String>,
    include: Option<String>,
    config: &Config,
) -> ActixResult<SearchResponse> {
    let content_filter = ContentFilter::new(
        family_friendly,
        exclude.as_deref(),
        include.as_deref(),
    );

    let _search_span = logfire::span!(
        "bufo_search",
        query = &query_text,
        top_k = top_k_val as i64,
        alpha = alpha as f64,
        family_friendly = family_friendly,
        exclude_patterns_count = content_filter.exclude_pattern_count() as i64
    )
    .entered();

    logfire::info!(
        "search request received",
        query = &query_text,
        top_k = top_k_val as i64,
        alpha = alpha as f64,
        exclude_patterns = &content_filter.exclude_patterns_str()
    );

    // create clients
    let embedder = VoyageEmbedder::new(config.voyage_api_key.clone());
    let vector_store = TurbopufferStore::new(
        config.turbopuffer_api_key.clone(),
        config.turbopuffer_namespace.clone(),
    );

    let fusion_config = FusionConfig::new(alpha);

    // execute hybrid search
    let fused_results = execute_hybrid_search(
        &query_text,
        top_k_val,
        &fusion_config,
        &embedder,
        &vector_store,
    )
    .await
    .map_err(|e| e.into_actix_error())?;

    // convert to BufoResults and apply filtering
    let results: Vec<BufoResult> = fused_results
        .into_iter()
        .map(|(id, score, attrs)| BufoResult {
            id: id.clone(),
            url: attrs.get("url").cloned().unwrap_or_default(),
            name: attrs.get("name").cloned().unwrap_or_else(|| id.clone()),
            score,
        })
        .filter(|result| content_filter.matches(result))
        .take(top_k_val)
        .collect();

    let results_count = results.len() as i64;
    let top_result_name = results
        .first()
        .map(|r| r.name.clone())
        .unwrap_or_else(|| "none".to_string());
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
        query.include.clone(),
        &config,
    )
    .await?;
    Ok(HttpResponse::Ok().json(response))
}

/// GET /api/search handler for shareable URLs
pub async fn search_get(
    query: web::Query<SearchQuery>,
    config: web::Data<Config>,
    req: HttpRequest,
) -> ActixResult<HttpResponse> {
    let etag = generate_etag(
        &query.query,
        query.top_k,
        query.alpha,
        query.family_friendly,
        &query.exclude,
        &query.include,
    );

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
        query.include.clone(),
        &config,
    )
    .await?;

    Ok(HttpResponse::Ok()
        .insert_header(("etag", etag.clone()))
        .insert_header(("cache-control", "public, max-age=300"))
        .json(response))
}
