//! provider abstractions for embedding and vector search backends
//!
//! these traits allow swapping implementations (e.g., voyage → openai embeddings)
//! without changing the search logic.
//!
//! ## design notes
//!
//! we use `async fn` in traits directly (stabilized in rust 1.75). for this crate's
//! use case (single-threaded actix-web), the Send bound issue doesn't apply.
//!
//! the trait design follows patterns from:
//! - async-openai's `Config` trait for backend abstraction
//! - tower's `Service` trait for composability (though simpler here)

use std::future::Future;
use thiserror::Error;

/// errors that can occur when generating embeddings
#[derive(Debug, Error)]
pub enum EmbeddingError {
    #[error("failed to send request: {0}")]
    Request(#[from] reqwest::Error),

    #[error("api error ({status}): {body}")]
    Api { status: u16, body: String },

    #[error("no embedding returned from provider")]
    EmptyResponse,

    #[error("{0}")]
    Other(#[from] anyhow::Error),
}

/// a provider that can generate embeddings for text
///
/// implementations should be cheap to clone (wrap expensive resources in Arc).
///
/// # example
///
/// ```ignore
/// let client = VoyageEmbedder::new(api_key);
/// let embedding = client.embed("hello world").await?;
/// ```
pub trait Embedder: Send + Sync {
    /// generate an embedding vector for the given text
    fn embed(&self, text: &str) -> impl Future<Output = Result<Vec<f32>, EmbeddingError>> + Send;

    /// human-readable name for logging/debugging
    fn name(&self) -> &'static str;
}

/// errors that can occur during vector search
#[derive(Debug, Error)]
pub enum VectorSearchError {
    #[error("request failed: {0}")]
    Request(#[from] reqwest::Error),

    #[error("api error ({status}): {body}")]
    Api { status: u16, body: String },

    #[error("query too long: {message}")]
    QueryTooLong { message: String },

    #[error("parse error: {0}")]
    Parse(String),

    #[error("{0}")]
    Other(#[from] anyhow::Error),
}

/// a single result from a vector search
#[derive(Debug, Clone)]
pub struct SearchResult {
    pub id: String,
    /// raw distance/score from the backend (interpretation varies by method)
    pub score: f32,
    /// arbitrary key-value attributes
    pub attributes: std::collections::HashMap<String, String>,
}

/// a provider that can perform vector similarity search
pub trait VectorStore: Send + Sync {
    /// search by vector embedding (ANN/cosine similarity)
    fn search_by_vector(
        &self,
        embedding: &[f32],
        top_k: usize,
    ) -> impl Future<Output = Result<Vec<SearchResult>, VectorSearchError>> + Send;

    /// search by keyword (BM25 full-text search)
    fn search_by_keyword(
        &self,
        query: &str,
        top_k: usize,
    ) -> impl Future<Output = Result<Vec<SearchResult>, VectorSearchError>> + Send;

    /// human-readable name for logging/debugging
    fn name(&self) -> &'static str;
}
