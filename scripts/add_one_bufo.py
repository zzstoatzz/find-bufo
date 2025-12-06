#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "httpx",
#     "python-dotenv",
#     "pillow",
# ]
# ///
"""
Add a single bufo to turbopuffer.
Usage: uv run scripts/add_one_bufo.py <path_to_image>
"""

import asyncio
import base64
import hashlib
import os
import sys
from io import BytesIO
from pathlib import Path

import httpx
from PIL import Image
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")


async def embed_image(client: httpx.AsyncClient, image_path: Path, api_key: str) -> list[float] | None:
    """Generate embedding for an image using Voyage AI"""
    try:
        image = Image.open(image_path)
        is_animated = hasattr(image, 'n_frames') and image.n_frames > 1
        filename_text = image_path.stem.replace("-", " ").replace("_", " ")

        content = [{"type": "text", "text": filename_text}]

        if is_animated:
            num_frames = image.n_frames
            max_frames = min(5, num_frames)
            frame_indices = [int(i * (num_frames - 1) / (max_frames - 1)) for i in range(max_frames)]
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
            buffered = BytesIO()
            image.convert("RGB").save(buffered, format="WEBP", lossless=True)
            img_base64 = base64.b64encode(buffered.getvalue()).decode("utf-8")
            content.append({
                "type": "image_base64",
                "image_base64": f"data:image/webp;base64,{img_base64}",
            })

        response = await client.post(
            "https://api.voyageai.com/v1/multimodalembeddings",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "inputs": [{"content": content}],
                "model": "voyage-multimodal-3",
                "input_type": "document",
            },
            timeout=60.0,
        )
        response.raise_for_status()
        result = response.json()
        return result["data"][0]["embedding"]
    except Exception as e:
        print(f"error embedding {image_path.name}: {e}")
        return None


async def upload_to_turbopuffer(filename: str, embedding: list[float], api_key: str, namespace: str):
    """Upload single embedding to turbopuffer"""
    file_hash = hashlib.sha256(filename.encode()).hexdigest()[:16]
    name = filename.rsplit(".", 1)[0]
    url = f"https://find-bufo.fly.dev/static/{filename}"

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"https://api.turbopuffer.com/v1/vectors/{namespace}",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "ids": [file_hash],
                "vectors": [embedding],
                "distance_metric": "cosine_distance",
                "attributes": {
                    "url": [url],
                    "name": [name],
                    "filename": [filename],
                },
                "schema": {
                    "name": {"type": "string", "full_text_search": True},
                    "filename": {"type": "string", "full_text_search": True},
                },
            },
            timeout=30.0,
        )
        if response.status_code != 200:
            print(f"turbopuffer error: {response.text}")
            response.raise_for_status()

    print(f"uploaded {filename} to turbopuffer")


async def main():
    if len(sys.argv) < 2:
        print("usage: uv run scripts/add_one_bufo.py <path_to_image>")
        sys.exit(1)

    image_path = Path(sys.argv[1])
    if not image_path.exists():
        print(f"file not found: {image_path}")
        sys.exit(1)

    voyage_api_key = os.getenv("VOYAGE_API_TOKEN")
    if not voyage_api_key:
        print("VOYAGE_API_TOKEN not set")
        sys.exit(1)

    tpuf_api_key = os.getenv("TURBOPUFFER_API_KEY")
    if not tpuf_api_key:
        print("TURBOPUFFER_API_KEY not set")
        sys.exit(1)

    tpuf_namespace = os.getenv("TURBOPUFFER_NAMESPACE", "bufos")

    print(f"adding {image_path.name}...")

    async with httpx.AsyncClient() as client:
        embedding = await embed_image(client, image_path, voyage_api_key)
        if not embedding:
            print("failed to generate embedding")
            sys.exit(1)

    await upload_to_turbopuffer(image_path.name, embedding, tpuf_api_key, tpuf_namespace)
    print("done!")


if __name__ == "__main__":
    asyncio.run(main())
