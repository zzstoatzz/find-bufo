import re
import logging
from dataclasses import dataclass

logger = logging.getLogger(__name__)


@dataclass
class BufoMatch:
    """a matched bufo image"""
    name: str
    url: str
    phrase: str  # the matched phrase


def extract_phrase(filename: str) -> list[str]:
    """extract phrase words from a bufo filename (preserving order)"""
    # remove extension
    name = filename.rsplit(".", 1)[0]
    # replace separators with spaces, extract words
    name = re.sub(r"[-_]", " ", name)
    words = re.findall(r"[a-z]+", name.lower())
    # strip leading "bufo" if present
    if words and words[0] == "bufo":
        words = words[1:]
    return words


@dataclass
class Bufo:
    """a bufo with name and URL"""
    name: str
    url: str


class BufoMatcher:
    """matches post text against bufo image names using exact phrase matching"""

    def __init__(self, bufos: list[Bufo], min_words: int = 4):
        self.min_words = min_words
        # precompute phrases from bufo names
        self.bufos: list[tuple[Bufo, list[str]]] = []
        for bufo in bufos:
            phrase = extract_phrase(bufo.name)
            if len(phrase) >= min_words:
                self.bufos.append((bufo, phrase))
        logger.info(f"loaded {len(self.bufos)} bufos with >= {min_words} word phrases")

    def find_match(self, post_text: str) -> BufoMatch | None:
        """find a matching bufo if post contains exact phrase"""
        # normalize post text to lowercase words
        post_words = re.findall(r"[a-z]+", post_text.lower())
        if len(post_words) < self.min_words:
            return None

        # check each bufo phrase for exact sequential match
        for bufo, phrase in self.bufos:
            if self._contains_phrase(post_words, phrase):
                return BufoMatch(
                    name=bufo.name,
                    url=bufo.url,
                    phrase=" ".join(phrase),
                )

        return None

    def _contains_phrase(self, post_words: list[str], phrase: list[str]) -> bool:
        """check if post_words contains phrase as consecutive subsequence"""
        phrase_len = len(phrase)
        for i in range(len(post_words) - phrase_len + 1):
            if post_words[i : i + phrase_len] == phrase:
                return True
        return False
