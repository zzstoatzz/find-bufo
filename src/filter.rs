//! composable result filters
//!
//! filters are predicates that can be combined to create complex filtering logic.

use regex::Regex;

/// a single search result that can be filtered
pub trait Filterable {
    fn name(&self) -> &str;
}

/// a predicate that can accept or reject items
pub trait Filter<T: Filterable>: Send + Sync {
    /// returns true if the item should be kept
    fn matches(&self, item: &T) -> bool;
}

/// filters out inappropriate content based on a blocklist
struct BlocklistFilter {
    blocklist: Vec<&'static str>,
}

impl BlocklistFilter {
    fn inappropriate_bufos() -> Self {
        Self {
            blocklist: vec![
                "bufo-juicy",
                "good-news-bufo-offers-suppository",
                "bufo-declines-your-suppository-offer",
                "tsa-bufo-gropes-you",
            ],
        }
    }
}

impl<T: Filterable> Filter<T> for BlocklistFilter {
    fn matches(&self, item: &T) -> bool {
        !self.blocklist.iter().any(|blocked| item.name().contains(blocked))
    }
}

/// filters out items matching any of the given regex patterns
struct ExcludePatternFilter {
    patterns: Vec<Regex>,
}

impl ExcludePatternFilter {
    fn from_comma_separated(pattern_str: &str) -> Self {
        let patterns = pattern_str
            .split(',')
            .map(|p| p.trim())
            .filter(|p| !p.is_empty())
            .filter_map(|p| Regex::new(p).ok())
            .collect();

        Self { patterns }
    }

    fn empty() -> Self {
        Self { patterns: vec![] }
    }
}

impl<T: Filterable> Filter<T> for ExcludePatternFilter {
    fn matches(&self, item: &T) -> bool {
        !self.patterns.iter().any(|p| p.is_match(item.name()))
    }
}

/// combined filter that handles family-friendly mode and include/exclude patterns
pub struct ContentFilter {
    family_friendly: bool,
    blocklist: BlocklistFilter,
    exclude: ExcludePatternFilter,
    include_patterns: Vec<Regex>,
}

impl ContentFilter {
    pub fn new(
        family_friendly: bool,
        exclude_str: Option<&str>,
        include_str: Option<&str>,
    ) -> Self {
        let exclude = exclude_str
            .map(ExcludePatternFilter::from_comma_separated)
            .unwrap_or_else(ExcludePatternFilter::empty);

        let include_patterns: Vec<Regex> = include_str
            .map(|s| {
                s.split(',')
                    .map(|p| p.trim())
                    .filter(|p| !p.is_empty())
                    .filter_map(|p| Regex::new(p).ok())
                    .collect()
            })
            .unwrap_or_default();

        Self {
            family_friendly,
            blocklist: BlocklistFilter::inappropriate_bufos(),
            exclude,
            include_patterns,
        }
    }

    pub fn exclude_pattern_count(&self) -> usize {
        self.exclude.patterns.len()
    }

    pub fn exclude_patterns_str(&self) -> String {
        self.exclude
            .patterns
            .iter()
            .map(|r| r.as_str())
            .collect::<Vec<_>>()
            .join(",")
    }
}

impl<T: Filterable> Filter<T> for ContentFilter {
    fn matches(&self, item: &T) -> bool {
        // check family-friendly blocklist
        if self.family_friendly && !self.blocklist.matches(item) {
            return false;
        }

        // check if explicitly included (overrides exclude)
        let matches_include = self.include_patterns.iter().any(|p| p.is_match(item.name()));
        if matches_include {
            return true;
        }

        // check exclude patterns
        self.exclude.matches(item)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestItem {
        name: String,
    }

    impl Filterable for TestItem {
        fn name(&self) -> &str {
            &self.name
        }
    }

    #[test]
    fn test_blocklist_filter() {
        let filter = BlocklistFilter::inappropriate_bufos();
        let good = TestItem {
            name: "bufo-happy".into(),
        };
        let bad = TestItem {
            name: "bufo-juicy".into(),
        };

        assert!(filter.matches(&good));
        assert!(!filter.matches(&bad));
    }

    #[test]
    fn test_exclude_pattern_filter() {
        let filter = ExcludePatternFilter::from_comma_separated("test, draft");
        let good = TestItem {
            name: "bufo-happy".into(),
        };
        let bad = TestItem {
            name: "bufo-test-mode".into(),
        };

        assert!(filter.matches(&good));
        assert!(!filter.matches(&bad));
    }

    #[test]
    fn test_include_overrides_exclude() {
        let filter = ContentFilter::new(false, Some("party"), Some("birthday-party"));
        let excluded = TestItem {
            name: "bufo-party".into(),
        };
        let included = TestItem {
            name: "bufo-birthday-party".into(),
        };

        assert!(!filter.matches(&excluded));
        assert!(filter.matches(&included));
    }
}
