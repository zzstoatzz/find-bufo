import logging
from datetime import datetime, timezone

import httpx
from atproto import Client, models

from bufo_bot.config import settings
from bufo_bot.jetstream import JetstreamClient, Post
from bufo_bot.matcher import Bufo, BufoMatcher, BufoMatch

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger(__name__)


def get_recent_bufo_names(client: Client, minutes: int) -> set[str]:
    """fetch bufo names we've posted recently (from alt text)"""
    try:
        # fetch our recent posts
        feed = client.app.bsky.feed.get_author_feed(
            {"actor": settings.bsky_handle, "limit": 50}
        )
        cutoff = datetime.now(timezone.utc).timestamp() - (minutes * 60)
        recent = set()

        for item in feed.feed:
            post = item.post
            # parse created_at timestamp
            created = post.record.created_at
            if isinstance(created, str):
                # parse ISO format
                try:
                    ts = datetime.fromisoformat(created.replace("Z", "+00:00"))
                    if ts.timestamp() < cutoff:
                        break  # posts are sorted newest first
                except ValueError:
                    continue

            # extract alt text from embedded image
            embed = post.record.embed
            if embed and hasattr(embed, "media"):
                media = embed.media
                if hasattr(media, "images"):
                    for img in media.images:
                        if img.alt:
                            # convert alt text back to filename format
                            recent.add(img.alt.replace(" ", "-") + ".png")
                            recent.add(img.alt.replace(" ", "-") + ".gif")

        logger.info(f"found {len(recent)} bufos posted in last {minutes} minutes")
        return recent
    except Exception as e:
        logger.warning(f"failed to fetch recent posts: {e}")
        return set()


def load_bufos() -> list[Bufo]:
    """fetch the list of bufos from the find-bufo API"""
    api_url = "https://find-bufo.com/api/search?query=bufo&top_k=2000&alpha=0"

    try:
        resp = httpx.get(api_url, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        bufos = [
            Bufo(name=r["name"], url=r["url"])
            for r in data.get("results", [])
            if r.get("name") and r.get("url")
        ]
        logger.info(f"loaded {len(bufos)} bufos from API")
        return bufos
    except Exception as e:
        logger.error(f"failed to load bufos from API: {e}")
        return []


def quote_post_with_bufo(client: Client, post: Post, match: BufoMatch) -> None:
    """quote the post with the matching bufo image"""
    # fetch the bufo image
    logger.info(f"fetching bufo image: {match.url}")

    try:
        img_data = httpx.get(match.url, timeout=10).content
    except Exception as e:
        logger.error(f"failed to fetch bufo image: {e}")
        return

    # upload the image blob
    try:
        uploaded = client.upload_blob(img_data)
    except Exception as e:
        logger.error(f"failed to upload blob: {e}")
        return

    # create the quote post with image
    # we need to resolve the post to get a strong ref
    try:
        post_ref = models.create_strong_ref(
            models.ComAtprotoRepoStrongRef.Main(uri=post.uri, cid="")  # CID will be fetched
        )
        # actually, we need to fetch the post to get its CID
        # use the repo.getRecord API
        parts = post.uri.replace("at://", "").split("/")
        did, collection, rkey = parts[0], parts[1], parts[2]
        record = client.app.bsky.feed.post.get(did, rkey)
        post_ref = models.create_strong_ref(record)
    except Exception as e:
        logger.error(f"failed to resolve post: {e}")
        return

    # build the embed: quote + image
    embed = models.AppBskyEmbedRecordWithMedia.Main(
        record=models.AppBskyEmbedRecord.Main(record=post_ref),
        media=models.AppBskyEmbedImages.Main(
            images=[
                models.AppBskyEmbedImages.Image(
                    image=uploaded.blob,
                    alt=match.name.replace("-", " "),
                )
            ]
        ),
    )

    # post it
    try:
        client.send_post(text="", embed=embed)
        logger.info(f"posted bufo reply: {match.name} (phrase: {match.phrase})")
    except Exception as e:
        logger.error(f"failed to send post: {e}")


def run_bot():
    """main bot loop"""
    logger.info("starting bufo bot...")

    # load bufos from API
    bufos = load_bufos()
    if not bufos:
        logger.error("no bufos loaded, exiting")
        return

    # initialize matcher
    matcher = BufoMatcher(bufos, min_words=settings.min_phrase_words)

    # initialize bluesky client
    client = Client()
    client.login(settings.bsky_handle, settings.bsky_app_password)
    logger.info(f"logged in as {settings.bsky_handle}")

    # connect to jetstream
    jetstream = JetstreamClient(settings.jetstream_endpoint)

    # track recently posted bufos (refreshed periodically)
    recent_bufos: set[str] = set()
    last_refresh = 0.0

    # process posts
    for post in jetstream.stream_posts():
        match = matcher.find_match(post.text)
        if match:
            logger.info(f"match: '{match.phrase}' -> {match.name}")

            if not settings.posting_enabled:
                logger.info("posting disabled, skipping")
                continue

            # refresh cooldown cache every 5 minutes
            now = datetime.now(timezone.utc).timestamp()
            if now - last_refresh > 300:
                recent_bufos = get_recent_bufo_names(client, settings.cooldown_minutes)
                last_refresh = now

            # check cooldown
            if match.name in recent_bufos:
                logger.info(f"cooldown: {match.name} posted recently, skipping")
                continue

            quote_post_with_bufo(client, post, match)
            recent_bufos.add(match.name)  # add to local cache immediately


def main():
    run_bot()


if __name__ == "__main__":
    main()
