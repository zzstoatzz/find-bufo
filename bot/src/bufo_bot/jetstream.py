import json
import logging
from collections.abc import Iterator
from dataclasses import dataclass

from httpx_ws import connect_ws

logger = logging.getLogger(__name__)


@dataclass
class Post:
    """a bluesky post from the firehose"""
    did: str
    rkey: str
    text: str

    @property
    def uri(self) -> str:
        return f"at://{self.did}/app.bsky.feed.post/{self.rkey}"


class JetstreamClient:
    """subscribes to bluesky jetstream and yields posts"""

    def __init__(self, endpoint: str):
        self.endpoint = endpoint

    @property
    def url(self) -> str:
        return f"wss://{self.endpoint}/subscribe?wantedCollections=app.bsky.feed.post"

    def stream_posts(self) -> Iterator[Post]:
        """yield posts from the firehose, reconnecting on failure"""
        import time

        while True:
            try:
                logger.info(f"connecting to jetstream at {self.endpoint}")
                with connect_ws(self.url) as ws:
                    logger.info("connected to jetstream")
                    while True:
                        try:
                            message = ws.receive_text()
                            data = json.loads(message)
                            # only process commit messages for new posts
                            if data.get("kind") != "commit":
                                continue
                            commit = data.get("commit", {})
                            if commit.get("operation") != "create":
                                continue
                            record = commit.get("record", {})
                            text = record.get("text", "")
                            if not text:
                                continue
                            yield Post(
                                did=data.get("did", ""),
                                rkey=commit.get("rkey", ""),
                                text=text,
                            )
                        except json.JSONDecodeError as e:
                            logger.debug(f"skipping malformed message: {e}")
                            continue
            except Exception as e:
                logger.warning(f"jetstream connection error: {e}, reconnecting in 5s...")
                time.sleep(5)
