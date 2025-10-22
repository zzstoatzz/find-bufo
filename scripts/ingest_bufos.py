#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "httpx",
#     "beautifulsoup4",
#     "rich",
#     "python-dotenv",
#     "pillow",
# ]
# ///
"""
Scrape all bufos from bufo.zone, generate embeddings, and upload to turbopuffer.
"""

import asyncio
import base64
import hashlib
import os
import re
from io import BytesIO
from pathlib import Path
from typing import List

import httpx
from bs4 import BeautifulSoup
from PIL import Image
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from dotenv import load_dotenv

console = Console()

# Load .env from project root
load_dotenv(Path(__file__).parent.parent / ".env")


async def fetch_bufo_urls() -> set[str]:
    """Fetch all unique bufo URLs from bufo.zone"""
    console.print("[cyan]fetching bufo list from bufo.zone...[/cyan]")

    async with httpx.AsyncClient() as client:
        response = await client.get("https://bufo.zone", timeout=30.0)
        response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")

    urls = set()
    for img in soup.find_all("img"):
        src = img.get("src", "")
        if "all-the.bufo.zone" in src:
            urls.add(src)

    pattern = re.compile(
        r"https://all-the\.bufo\.zone/[^\"'>\s]+\.(png|gif|jpg|jpeg|webp)"
    )
    for match in pattern.finditer(response.text):
        urls.add(match.group(0))

    console.print(f"[green]found {len(urls)} unique bufo images[/green]")
    return urls


async def download_bufo(client: httpx.AsyncClient, url: str, output_dir: Path) -> str | None:
    """Download a single bufo and return filename"""
    filename = url.split("/")[-1]
    output_path = output_dir / filename

    if output_path.exists() and output_path.stat().st_size > 0:
        return filename

    try:
        response = await client.get(url, timeout=30.0)
        response.raise_for_status()
        output_path.write_bytes(response.content)
        return filename
    except Exception as e:
        console.print(f"[red]error downloading {url}: {e}[/red]")
        return None


async def download_all_bufos(urls: set[str], output_dir: Path) -> List[Path]:
    """Download all bufos concurrently"""
    output_dir.mkdir(parents=True, exist_ok=True)

    downloaded_files = []

    async with httpx.AsyncClient() as client:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            task = progress.add_task(
                f"[cyan]downloading {len(urls)} bufos...", total=len(urls)
            )

            batch_size = 10
            urls_list = list(urls)

            for i in range(0, len(urls_list), batch_size):
                batch = urls_list[i : i + batch_size]
                tasks = [download_bufo(client, url, output_dir) for url in batch]
                results = await asyncio.gather(*tasks, return_exceptions=True)

                for filename in results:
                    if filename and not isinstance(filename, Exception):
                        downloaded_files.append(output_dir / filename)

                progress.update(task, advance=len(batch))

                if i + batch_size < len(urls_list):
                    await asyncio.sleep(0.5)

    console.print(f"[green]downloaded {len(downloaded_files)} bufos[/green]")
    return downloaded_files


async def embed_image(client: httpx.AsyncClient, image_path: Path, api_key: str, max_retries: int = 3) -> List[float] | None:
    """Generate embedding for an image using Voyage AI with retry logic"""
    for attempt in range(max_retries):
        try:
            image = Image.open(image_path)

            # check if this is an animated image
            is_animated = hasattr(image, 'n_frames') and image.n_frames > 1

            if is_animated:
                # for animated GIFs, extract multiple keyframes for temporal representation
                num_frames = image.n_frames
                # extract up to 5 evenly distributed frames
                max_frames = min(5, num_frames)
                frame_indices = [int(i * (num_frames - 1) / (max_frames - 1)) for i in range(max_frames)]

                # extract each frame as base64 image
                content = []
                for frame_idx in frame_indices:
                    image.seek(frame_idx)
                    buffered = BytesIO()
                    image.convert("RGB").save(buffered, format="WEBP", lossless=True)
                    img_base64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
                    content.append({
                        "type": "image_base64",
                        "image_base64": f"data:image/webp;base64,{img_base64}",
                    })
            else:
                # for static images, just send the single image
                buffered = BytesIO()
                image.convert("RGB").save(buffered, format="WEBP", lossless=True)
                img_base64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
                content = [{
                    "type": "image_base64",
                    "image_base64": f"data:image/webp;base64,{img_base64}",
                }]

            response = await client.post(
                "https://api.voyageai.com/v1/multimodalembeddings",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "inputs": [{"content": content}],
                    "model": "voyage-multimodal-3",
                },
                timeout=60.0,
            )
            response.raise_for_status()
            result = response.json()
            return result["data"][0]["embedding"]
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 429:
                # rate limited - exponential backoff
                wait_time = (2 ** attempt) * 2  # 2s, 4s, 8s
                if attempt < max_retries - 1:
                    await asyncio.sleep(wait_time)
                    continue
            # show actual error response for 400s
            error_detail = e.response.text if e.response.status_code == 400 else str(e)
            console.print(f"[red]error embedding {image_path.name} ({e.response.status_code}): {error_detail}[/red]")
            return None
        except Exception as e:
            console.print(f"[red]error embedding {image_path.name}: {e}[/red]")
            return None
    return None


async def generate_embeddings(
    image_paths: List[Path], api_key: str
) -> dict[str, List[float]]:
    """Generate embeddings for all images with controlled concurrency"""
    embeddings = {}

    # limit to 50 concurrent requests to stay well under 2000/min rate limit
    semaphore = asyncio.Semaphore(50)

    async def embed_with_semaphore(client, image_path):
        async with semaphore:
            embedding = await embed_image(client, image_path, api_key)
            return (image_path.name, embedding)

    async with httpx.AsyncClient() as client:
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=console,
        ) as progress:
            task = progress.add_task(
                f"[cyan]generating embeddings for {len(image_paths)} images...",
                total=len(image_paths),
            )

            # process all images concurrently with semaphore
            tasks = [embed_with_semaphore(client, img) for img in image_paths]
            results = await asyncio.gather(*tasks)

            for name, embedding in results:
                if embedding:
                    embeddings[name] = embedding
                progress.update(task, advance=1)

    console.print(f"[green]generated {len(embeddings)} embeddings[/green]")
    return embeddings


async def upload_to_turbopuffer(
    embeddings: dict[str, List[float]],
    bufo_urls: dict[str, str],
    api_key: str,
    namespace: str,
):
    """Upload embeddings to turbopuffer"""
    console.print("[cyan]uploading to turbopuffer...[/cyan]")

    ids = []
    vectors = []
    urls = []
    names = []
    filenames = []

    for filename, embedding in embeddings.items():
        # use hash as ID to stay under 64 byte limit
        file_hash = hashlib.sha256(filename.encode()).hexdigest()[:16]
        ids.append(file_hash)
        vectors.append(embedding)
        urls.append(bufo_urls.get(filename, ""))
        names.append(filename.rsplit(".", 1)[0])
        filenames.append(filename)

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"https://api.turbopuffer.com/v1/vectors/{namespace}",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "ids": ids,
                "vectors": vectors,
                "distance_metric": "cosine_distance",
                "attributes": {
                    "url": urls,
                    "name": names,
                    "filename": filenames,
                },
                "schema": {
                    "name": {
                        "type": "string",
                        "full_text_search": True,
                    },
                    "filename": {
                        "type": "string",
                        "full_text_search": True,
                    },
                },
            },
            timeout=120.0,
        )
        if response.status_code != 200:
            console.print(f"[red]turbopuffer error: {response.text}[/red]")
            response.raise_for_status()

    console.print(
        f"[green]uploaded {len(ids)} bufos to turbopuffer namespace '{namespace}'[/green]"
    )


async def main():
    """Main function"""
    console.print("[bold cyan]bufo ingestion pipeline[/bold cyan]\n")

    voyage_api_key = os.getenv("VOYAGE_API_TOKEN")
    if not voyage_api_key:
        console.print("[red]VOYAGE_API_TOKEN not set[/red]")
        return

    tpuf_api_key = os.getenv("TURBOPUFFER_API_KEY")
    if not tpuf_api_key:
        console.print("[red]TURBOPUFFER_API_KEY not set[/red]")
        return

    tpuf_namespace = os.getenv("TURBOPUFFER_NAMESPACE", "bufos")

    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    output_dir = project_root / "data" / "bufos"

    bufo_urls_raw = await fetch_bufo_urls()

    bufo_urls_map = {url.split("/")[-1]: url for url in bufo_urls_raw}

    image_paths = await download_all_bufos(bufo_urls_raw, output_dir)

    embeddings = await generate_embeddings(image_paths, voyage_api_key)

    await upload_to_turbopuffer(embeddings, bufo_urls_map, tpuf_api_key, tpuf_namespace)

    console.print("\n[bold green]ingestion complete![/bold green]")


if __name__ == "__main__":
    asyncio.run(main())
