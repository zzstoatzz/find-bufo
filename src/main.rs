mod config;
mod embedding;
mod filter;
mod providers;
mod scoring;
mod search;
mod turbopuffer;

use actix_cors::Cors;
use actix_files as fs;
use actix_governor::{Governor, GovernorConfigBuilder};
use actix_web::{middleware, web, App, HttpResponse, HttpServer};
use anyhow::Result;
use config::Config;
use opentelemetry_instrumentation_actix_web::{RequestMetrics, RequestTracing};
use tracing::level_filters::LevelFilter;

async fn index() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .body(include_str!("../static/index.html"))
}

#[actix_web::main]
async fn main() -> Result<()> {
    dotenv::dotenv().ok();

    // initialize logfire with info level filter to exclude trace/debug spans
    let logfire = logfire::configure()
        .with_default_level_filter(LevelFilter::INFO)
        .finish()
        .map_err(|e| anyhow::anyhow!("failed to initialize logfire: {}", e))?;

    let _guard = logfire.shutdown_guard();

    let config = Config::from_env()?;
    let host = config.host.clone();
    let port = config.port;

    logfire::info!("starting bufo search server",
        host = &host,
        port = port as i64
    );

    // rate limiter: 10 requests per minute per IP
    let governor_conf = GovernorConfigBuilder::default()
        .milliseconds_per_request(6000) // 1 request per 6 seconds = 10 per minute
        .burst_size(10)
        .finish()
        .unwrap();

    HttpServer::new(move || {
        let cors = Cors::permissive();

        App::new()
            // opentelemetry tracing and metrics FIRST
            .wrap(RequestTracing::new())
            .wrap(RequestMetrics::default())
            // existing middleware
            .wrap(middleware::Logger::default())
            .wrap(cors)
            .app_data(web::Data::new(config.clone()))
            .route("/", web::get().to(index))
            .service(
                web::scope("/api")
                    .wrap(Governor::new(&governor_conf))
                    .route("/search", web::post().to(search::search))
                    .route("/search", web::get().to(search::search_get))
                    .route("/health", web::get().to(|| async { HttpResponse::Ok().body("ok") }))
            )
            .service(fs::Files::new("/static", "./static").show_files_listing())
    })
    .bind((host.as_str(), port))?
    .run()
    .await?;

    Ok(())
}
