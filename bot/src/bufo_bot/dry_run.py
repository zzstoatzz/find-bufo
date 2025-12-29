"""dry run the matcher against the firehose without posting"""
import logging

import httpx

from bufo_bot.config import settings
from bufo_bot.jetstream import JetstreamClient
from bufo_bot.matcher import Bufo, BufoMatcher

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(message)s",
)
logger = logging.getLogger(__name__)


def load_bufos() -> list[Bufo]:
    """fetch the list of bufos from the find-bufo API"""
    api_url = "https://find-bufo.com/api/search?query=bufo&top_k=2000&alpha=0"
    resp = httpx.get(api_url, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    return [
        Bufo(name=r["name"], url=r["url"])
        for r in data.get("results", [])
        if r.get("name") and r.get("url")
    ]


def main():
    bufos = load_bufos()
    logger.info(f"loaded {len(bufos)} bufos")

    matcher = BufoMatcher(bufos, min_words=settings.min_phrase_words)

    jetstream = JetstreamClient(settings.jetstream_endpoint)

    match_count = 0
    for post in jetstream.stream_posts():
        match = matcher.find_match(post.text)
        if match:
            match_count += 1
            print(f"\n{'='*60}")
            print(f"POST: {post.text[:200]}")
            print(f"BUFO: {match.name}")
            print(f"PHRASE: {match.phrase}")
            print(f"{'='*60}")

            if match_count >= 20:
                print("\n--- stopping after 20 matches ---")
                break


if __name__ == "__main__":
    main()
