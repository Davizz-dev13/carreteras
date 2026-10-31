"""Funciones de pipeline/rutas.py (anchura y velocidad desde las etiquetas OSM) para el mundo abierto."""
import re

ANCHO_CARRIL = {"motorway": 3.5, "trunk": 3.5, "primary": 3.5, "secondary": 3.25, "tertiary": 3.0, "unclassified": 2.75}
VEL_DEFECTO = {"motorway": 120, "trunk": 90, "primary": 90, "secondary": 90, "tertiary": 70, "unclassified": 50}


def tipo_base(tags):
    return tags.get("highway", "unclassified").replace("_link", "")


def refs_de(tags):
    return [r.strip() for r in re.split(r"[;,]", tags.get("ref", "")) if r.strip()]


def ancho_de(tags):
    """Anchura de la calzada (m) a partir de width / lanes / tipo de vía."""
    try:
        return float(tags["width"].replace(",", ".").split()[0])
    except (KeyError, ValueError):
        pass
    t = tipo_base(tags)
    try:
        carriles = int(tags.get("lanes", ""))
    except ValueError:
        carriles = 1 if tags.get("oneway") == "yes" else 2
    if "_link" in tags.get("highway", ""):
        carriles = 1
    return carriles * ANCHO_CARRIL.get(t, 3.0) + (1.0 if t in ("motorway", "trunk", "primary") else 0.5)


def vel_max_de(tags):
    m = re.match(r"(\d+)", tags.get("maxspeed", ""))
    return int(m.group(1)) if m else VEL_DEFECTO.get(tipo_base(tags), 50)



def vel_de(tags, sentido):
    """maxspeed:forward / maxspeed:backward (0 = no hay dato propio de ese sentido)."""
    m = re.match(r"(\d+)", tags.get("maxspeed:" + sentido, ""))
    return int(m.group(1)) if m else 0
