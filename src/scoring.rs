//! score fusion and normalization for hybrid search
//!
//! this module handles the weighted combination of semantic (vector) and
//! keyword (BM25) search scores.
//!
//! ## normalization strategies
//!
//! - **cosine distance → similarity**: `1.0 - (distance / 2.0)` maps [0, 2] → [1, 0]
//! - **BM25 max-scaling**: divide by max score so top result = 1.0
//!
//! ## fusion formula
//!
//! ```text
//! score = α * semantic + (1 - α) * keyword
//! ```
//!
//! reference: https://opensourceconnections.com/blog/2023/02/27/hybrid-vigor-winning-at-hybrid-search/

use std::collections::HashMap;

/// configuration for score fusion
#[derive(Debug, Clone)]
pub struct FusionConfig {
    /// weight for semantic scores (0.0 = pure keyword, 1.0 = pure semantic)
    pub alpha: f32,
    /// minimum fused score to include in results (filters noise)
    pub min_score: f32,
}

impl Default for FusionConfig {
    fn default() -> Self {
        Self {
            alpha: 0.7,
            min_score: 0.001,
        }
    }
}

impl FusionConfig {
    pub fn new(alpha: f32) -> Self {
        Self {
            alpha,
            ..Default::default()
        }
    }
}

/// normalize cosine distance to similarity score
///
/// cosine distance ranges from 0 (identical) to 2 (opposite).
/// we convert to similarity: 1.0 (identical) to 0.0 (opposite).
#[inline]
pub fn cosine_distance_to_similarity(distance: f32) -> f32 {
    1.0 - (distance / 2.0)
}

/// normalize BM25 scores using max-scaling
///
/// divides all scores by the maximum score, ensuring:
/// - top result gets score 1.0
/// - relative spacing is preserved
/// - handles edge cases (empty results, identical scores)
pub fn normalize_bm25_scores(scores: &[(String, f32)]) -> HashMap<String, f32> {
    let max_score = scores
        .iter()
        .map(|(_, s)| *s)
        .fold(f32::NEG_INFINITY, f32::max)
        .max(0.001); // avoid division by zero

    scores
        .iter()
        .map(|(id, score)| (id.clone(), (score / max_score).min(1.0)))
        .collect()
}

/// fuse semantic and keyword scores using weighted combination
///
/// returns items sorted by fused score (descending), filtered by min_score.
pub fn fuse_scores(
    semantic_scores: &HashMap<String, f32>,
    keyword_scores: &HashMap<String, f32>,
    config: &FusionConfig,
) -> Vec<(String, f32)> {
    // collect all unique IDs
    let all_ids: std::collections::HashSet<_> = semantic_scores
        .keys()
        .chain(keyword_scores.keys())
        .collect();

    let mut fused: Vec<(String, f32)> = all_ids
        .into_iter()
        .map(|id| {
            let semantic = semantic_scores.get(id).copied().unwrap_or(0.0);
            let keyword = keyword_scores.get(id).copied().unwrap_or(0.0);
            let score = config.alpha * semantic + (1.0 - config.alpha) * keyword;
            (id.clone(), score)
        })
        .filter(|(_, score)| *score > config.min_score)
        .collect();

    // sort descending by score
    fused.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    fused
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_distance_to_similarity() {
        assert!((cosine_distance_to_similarity(0.0) - 1.0).abs() < 0.001);
        assert!((cosine_distance_to_similarity(2.0) - 0.0).abs() < 0.001);
        assert!((cosine_distance_to_similarity(1.0) - 0.5).abs() < 0.001);
    }

    #[test]
    fn test_normalize_bm25_scores() {
        let scores = vec![
            ("a".to_string(), 10.0),
            ("b".to_string(), 5.0),
            ("c".to_string(), 2.5),
        ];

        let normalized = normalize_bm25_scores(&scores);

        assert!((normalized["a"] - 1.0).abs() < 0.001);
        assert!((normalized["b"] - 0.5).abs() < 0.001);
        assert!((normalized["c"] - 0.25).abs() < 0.001);
    }

    #[test]
    fn test_fuse_scores_pure_semantic() {
        let mut semantic = HashMap::new();
        semantic.insert("a".to_string(), 0.9);
        semantic.insert("b".to_string(), 0.5);

        let mut keyword = HashMap::new();
        keyword.insert("a".to_string(), 0.1);
        keyword.insert("c".to_string(), 1.0);

        let config = FusionConfig::new(1.0); // pure semantic
        let fused = fuse_scores(&semantic, &keyword, &config);

        assert_eq!(fused[0].0, "a");
        assert!((fused[0].1 - 0.9).abs() < 0.001);
    }

    #[test]
    fn test_fuse_scores_balanced() {
        let mut semantic = HashMap::new();
        semantic.insert("a".to_string(), 0.8);

        let mut keyword = HashMap::new();
        keyword.insert("a".to_string(), 0.4);

        let config = FusionConfig::new(0.5); // balanced
        let fused = fuse_scores(&semantic, &keyword, &config);

        // 0.5 * 0.8 + 0.5 * 0.4 = 0.6
        assert!((fused[0].1 - 0.6).abs() < 0.001);
    }
}
