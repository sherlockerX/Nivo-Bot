"""Encrypting the stored identifiers so the operator can read them and a copied
database cannot.

AES-256-GCM with a key derived from CLOUD_SECRET (config.identifier_key); a
fresh 12-byte nonce per value, stored in front of the ciphertext, base64 as a
whole. The account id is bound in as associated data so a value cannot be
moved from one row to another.
"""

from __future__ import annotations

import base64
import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


class IdentifierCrypto:
    def __init__(self, key: bytes):
        if len(key) != 32:
            raise ValueError("identifier key must be 32 bytes")
        self._aead = AESGCM(key)

    def encrypt(self, account_id: str, plaintext: str) -> str:
        nonce = os.urandom(12)
        ct = self._aead.encrypt(nonce, plaintext.encode(), account_id.encode())
        return base64.b64encode(nonce + ct).decode()

    def decrypt(self, account_id: str, token: str) -> str | None:
        """None when the column is empty (an account from before this existed)
        or was written under another secret."""
        if not token:
            return None
        try:
            raw = base64.b64decode(token)
            return self._aead.decrypt(raw[:12], raw[12:], account_id.encode()).decode()
        except (ValueError, InvalidTag):
            return None
