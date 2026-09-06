"""Chargement YAML tolerant aux tags courts CloudFormation.

PyYAML en SafeLoader refuse les tags `!Ref`, `!Sub`, `!ImportValue`... utilises
partout dans infrastructure/cloudformation/. On les convertit vers leur forme
longue (`{"Ref": ...}`, `{"Fn::Sub": ...}`) pour pouvoir inspecter les templates
comme des dictionnaires Python ordinaires.

Passer par un vrai parseur YAML (et non par grep) est indispensable ici : trois
templates de ce repo contiennent le texte "Fn::ImportValue" DANS DES COMMENTAIRES
ou des descriptions (codebuild.yaml ligne 128, vpc.yml ligne 425, pipeline.yml
ligne 8). Un grep les compterait comme de vraies dependances et fausserait le
graphe. Le parseur YAML ignore les commentaires par construction.
"""

from __future__ import annotations

import yaml

# Tags courts qui n'ont PAS de prefixe "Fn::" une fois developpes.
_NO_FN_PREFIX = {"Ref", "Condition"}


class CfnLoader(yaml.SafeLoader):
    """SafeLoader qui accepte les tags courts d'intrinsics CloudFormation."""


def _multi_constructor(loader: CfnLoader, tag_suffix: str, node: yaml.Node):
    """Transforme `!Tag valeur` en `{"Fn::Tag": valeur}`."""
    key = tag_suffix if tag_suffix in _NO_FN_PREFIX else f"Fn::{tag_suffix}"

    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
        # `!GetAtt Resource.Attr` s'ecrit en scalaire mais vaut une liste.
        if key == "Fn::GetAtt":
            value = value.split(".")
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    elif isinstance(node, yaml.MappingNode):
        # Cas du repo : `!ImportValue` suivi d'un mapping `'Fn::Sub': '...'`.
        value = loader.construct_mapping(node, deep=True)
    else:  # pragma: no cover - defensif, PyYAML n'a pas d'autre type de noeud
        raise yaml.constructor.ConstructorError(
            None, None, f"noeud YAML inattendu pour le tag !{tag_suffix}", node.start_mark
        )

    return {key: value}


CfnLoader.add_multi_constructor("!", _multi_constructor)


def load_template(path) -> dict:
    """Charge un template CloudFormation en dictionnaire Python."""
    with open(path, "r", encoding="utf-8") as handle:
        loaded = yaml.load(handle, Loader=CfnLoader)
    if not isinstance(loaded, dict):
        raise ValueError(f"{path} ne contient pas un template CloudFormation valide")
    return loaded
