"""Appel de l'API Anthropic pour expliquer le rapport du module 2."""

from __future__ import annotations

import os
from dataclasses import dataclass

from .prompt import SYSTEM_PROMPT, build_messages

# Modele par defaut, surchargeable par --model ou ANTHROPIC_MODEL.
DEFAULT_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-5")
# L'explication est volontairement courte (~300 mots demandes dans le prompt).
DEFAULT_MAX_TOKENS = 2000


class ExplainerError(RuntimeError):
    """Erreur exploitable cote CLI (SDK absent, cle manquante, appel en echec)."""


@dataclass
class Explanation:
    text: str
    model: str
    input_tokens: int | None = None
    output_tokens: int | None = None

    def to_json(self) -> dict:
        return {
            "text": self.text,
            "model": self.model,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
        }


def _client(api_key: str | None = None):
    """Instancie le client Anthropic, avec un message clair si le SDK manque."""
    try:
        import anthropic
    except ImportError as exc:  # pragma: no cover - depend de l'environnement
        raise ExplainerError(
            "Le SDK Anthropic n'est pas installe. Lancer : pip install anthropic"
        ) from exc

    if api_key:
        return anthropic.Anthropic(api_key=api_key)
    if not os.environ.get("ANTHROPIC_API_KEY"):
        raise ExplainerError(
            "Variable d'environnement ANTHROPIC_API_KEY absente. "
            "La definir avant de lancer l'explication (voir explainer/README.md)."
        )
    return anthropic.Anthropic()


def explain(
    report: dict,
    model: str = DEFAULT_MODEL,
    max_tokens: int = DEFAULT_MAX_TOKENS,
    api_key: str | None = None,
    include_raw_json: bool = False,
) -> Explanation:
    """Transforme le rapport JSON en explication en langage naturel."""
    client = _client(api_key)

    try:
        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=SYSTEM_PROMPT,
            messages=build_messages(report, include_raw_json=include_raw_json),
        )
    except Exception as exc:  # noqa: BLE001 - remonte proprement vers la CLI
        raise ExplainerError(f"Appel a l'API Anthropic en echec : {exc}") from exc

    text = "\n".join(block.text for block in response.content if block.type == "text")
    usage = getattr(response, "usage", None)

    return Explanation(
        text=text.strip(),
        model=model,
        input_tokens=getattr(usage, "input_tokens", None),
        output_tokens=getattr(usage, "output_tokens", None),
    )
