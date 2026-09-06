"""Rendu du graphe de dependances en DOT, colore par statut de stack.

Reutilise directement le graphe networkx du module 1 : aucune structure de
donnees parallele n'est reconstruite ici, on ne fait que le peindre.

Le DOT est rendu cote navigateur par st.graphviz_chart : le binaire `dot`
n'a pas besoin d'etre installe sur le poste.
"""

from __future__ import annotations

import networkx as nx

# Palette par statut de stack.
STATUS_STYLE = {
    "PENDING": {"fill": "#e9ecef", "font": "#495057", "border": "#adb5bd"},
    "IN_PROGRESS": {"fill": "#ffd8a8", "font": "#8a4b00", "border": "#f76707"},
    "COMPLETE": {"fill": "#b2f2bb", "font": "#1f5c2e", "border": "#2f9e44"},
    "FAILED": {"fill": "#ffc9c9", "font": "#8b1a1a", "border": "#e03131"},
    "SKIPPED": {"fill": "#e5dbff", "font": "#5f3dc4", "border": "#7048e8"},
}

# Couleurs d'aretes : celles qui menent a une stack en cours sont mises en
# evidence — c'est ce qui rend visible "ce qui debloque la suite".
EDGE_IDLE = "#ced4da"
EDGE_BLOCKING = "#f76707"
EDGE_SATISFIED = "#2f9e44"


def classify(status: str | None) -> str:
    """Ramene un StackStatus CloudFormation a l'une des 5 familles ci-dessus."""
    if not status:
        return "PENDING"
    if status in {"ALREADY_EXISTS", "SKIPPED"}:
        return "SKIPPED"
    if status.endswith("_COMPLETE") and "ROLLBACK" not in status and "DELETE" not in status:
        return "COMPLETE"
    if "FAILED" in status or "ROLLBACK" in status or "DELETE" in status:
        return "FAILED"
    if status.endswith("_IN_PROGRESS"):
        return "IN_PROGRESS"
    return "PENDING"


def _escape(text: str) -> str:
    return text.replace('"', '\\"')


def build_dot(
    graph: nx.DiGraph,
    statuses: dict[str, str],
    waves: list[list[str]],
    frozen: bool = False,
) -> str:
    """Produit la source DOT du graphe, colore selon les statuts observes."""
    classified = {key: classify(statuses.get(key)) for key in graph.nodes}

    lines = [
        "digraph deploiement {",
        "  rankdir=LR;",
        "  bgcolor=transparent;",
        '  node [shape=box style="rounded,filled" fontname="Helvetica" fontsize=11 '
        "penwidth=1.6 margin=0.16];",
        '  edge [fontname="Helvetica" fontsize=9 penwidth=1.4 arrowsize=0.7];',
    ]

    # Une colonne par vague : le lecteur voit directement ce qui part ensemble.
    # L'etiquette de vague est placee dans le meme rang que ses stacks, et les
    # etiquettes sont chainees entre elles par des aretes invisibles pour former
    # une ligne d'en-tete ordonnee (sans ce chainage, graphviz les disperse).
    # Leur position verticale exacte reste choisie par graphviz : seule la
    # colonne (le rang) est garantie, ce qui suffit a lire les vagues.
    for index, wave in enumerate(waves, start=1):
        members = " ".join(f'"{key}"' for key in wave)
        lines.append(
            f'  "wave{index}" [shape=plaintext style=none fillcolor=transparent '
            f'fontsize=11 fontcolor="#868e96" label="Vague {index}"];'
        )
        lines.append(f'  {{ rank=same; "wave{index}" {members} }}')

    for index in range(1, len(waves)):
        lines.append(f'  "wave{index}" -> "wave{index + 1}" [style=invis];')

    for key in graph.nodes:
        state = classified[key]
        style = STATUS_STYLE[state]
        stack_name = graph.nodes[key].get("stack_name", key)
        raw = statuses.get(key) or "en attente"
        label = f"{key}\\n{_escape(raw)}"
        # Une stack en cours est soulignee par un trait plus epais.
        pen = 3.0 if state == "IN_PROGRESS" else 1.6
        lines.append(
            f'  "{key}" [label="{label}" fillcolor="{style["fill"]}" '
            f'fontcolor="{style["font"]}" color="{style["border"]}" penwidth={pen} '
            f'tooltip="{_escape(stack_name)}"];'
        )

    for source, target, data in graph.edges(data=True):
        target_state = classified[target]
        source_state = classified[source]

        if target_state == "IN_PROGRESS" and not frozen:
            # Arete qui alimente une stack en cours : c'est elle qui debloque.
            color, penwidth, style = EDGE_BLOCKING, 2.4, "solid"
        elif source_state in {"COMPLETE", "SKIPPED"}:
            color, penwidth, style = EDGE_SATISFIED, 1.4, "solid"
        else:
            color, penwidth, style = EDGE_IDLE, 1.2, "solid"

        # Une dependance de cablage parametre est tracee en pointilles :
        # elle n'existe pas dans le template, elle vient du passage d'exports
        # en --parameter-overrides.
        if data.get("kinds") == {"parameter"}:
            style = "dashed"

        lines.append(
            f'  "{source}" -> "{target}" [color="{color}" penwidth={penwidth} '
            f'style={style}];'
        )

    lines.append("}")
    return "\n".join(lines)


def progress(statuses: dict[str, str], keys) -> dict:
    """Compte les stacks par famille de statut."""
    counts = {state: 0 for state in STATUS_STYLE}
    for key in keys:
        counts[classify(statuses.get(key))] += 1
    total = len(list(keys))
    done = counts["COMPLETE"] + counts["SKIPPED"]
    return {
        "counts": counts,
        "total": total,
        "done": done,
        "ratio": done / total if total else 0.0,
        "finished": done == total and total > 0,
        "failed": counts["FAILED"] > 0,
    }
