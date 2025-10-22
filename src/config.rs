use anyhow::{Context, Result};
use std::env;

#[derive(Clone, Debug)]
pub struct Config {
    pub host: String,
    pub port: u16,
    pub turbopuffer_api_key: String,
    pub turbopuffer_namespace: String,
    pub voyage_api_key: String,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        Ok(Config {
            host: env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string()),
            port: env::var("PORT")
                .unwrap_or_else(|_| "8080".to_string())
                .parse()
                .context("failed to parse PORT")?,
            turbopuffer_api_key: env::var("TURBOPUFFER_API_KEY")
                .context("TURBOPUFFER_API_KEY must be set")?,
            turbopuffer_namespace: env::var("TURBOPUFFER_NAMESPACE")
                .unwrap_or_else(|_| "bufos".to_string()),
            voyage_api_key: env::var("VOYAGE_API_TOKEN")
                .context("VOYAGE_API_TOKEN must be set")?,
        })
    }
}
