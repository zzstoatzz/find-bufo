mod config;
mod embedding;
mod search;
mod turbopuffer;

use actix_cors::Cors;
use actix_files as fs;
use actix_web::{middleware, web, App, HttpResponse, HttpServer};
use anyhow::Result;
use config::Config;

async fn index() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/html; charset=utf-8")
        .body(include_str!("../static/index.html"))
}

#[actix_web::main]
async fn main() -> Result<()> {
    dotenv::dotenv().ok();
    env_logger::init();

    let config = Config::from_env()?;
    let host = config.host.clone();
    let port = config.port;

    log::info!("starting bufo search server on {}:{}", host, port);

    HttpServer::new(move || {
        let cors = Cors::permissive();

        App::new()
            .wrap(middleware::Logger::default())
            .wrap(cors)
            .app_data(web::Data::new(config.clone()))
            .route("/", web::get().to(index))
            .service(
                web::scope("/api")
                    .route("/search", web::post().to(search::search))
                    .route("/health", web::get().to(|| async { HttpResponse::Ok().body("ok") }))
            )
            .service(fs::Files::new("/static", "./static").show_files_listing())
    })
    .bind((host.as_str(), port))?
    .run()
    .await?;

    Ok(())
}
