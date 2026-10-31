"""Modelo digital del terreno (MDT).

Fuente por defecto: IGN MDT05 (paso de malla 5 m, LiDAR PNOA, terreno desnudo, sin árboles
ni edificios) por su servicio WCS público, ya en ETRS89 / UTM 30N (EPSG:25830).
Alternativa: Copernicus GLO-30 (30 m, es un modelo de SUPERFICIE: incluye copas de árboles)
desde el bucket público de AWS, sin autenticación.
"""
import os, math, time
import numpy as np
import requests
import rasterio
from rasterio.merge import merge
from rasterio.warp import reproject, Resampling, calculate_default_transform
from rasterio.transform import from_origin

IGN_WCS = "https://servicios.idee.es/wcs-inspire/mdt"
UA = {"User-Agent": "carreteras-espana/0.1"}


def _get(url, params, destino, timeout=120):
    for intento in range(3):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=timeout)
            if r.status_code == 200 and r.content[:2] in (b"II", b"MM"):
                open(destino, "wb").write(r.content)
                return destino
            err = f"HTTP {r.status_code} {r.content[:120]!r}"
        except requests.RequestException as ex:
            err = str(ex)
        time.sleep(2 + 3 * intento)
    raise RuntimeError(f"Fallo descargando MDT: {err}")


def mdt_ign(xmin, ymin, xmax, ymax, cache_dir, paso=5, bloque=5000):
    """Descarga el MDT05 del IGN en bloques de 5x5 km y devuelve (array float32, transform)."""
    os.makedirs(cache_dir, exist_ok=True)
    xmin = math.floor(xmin / bloque) * bloque; ymin = math.floor(ymin / bloque) * bloque
    xmax = math.ceil(xmax / bloque) * bloque; ymax = math.ceil(ymax / bloque) * bloque
    ficheros = []
    for x in range(int(xmin), int(xmax), bloque):
        for y in range(int(ymin), int(ymax), bloque):
            f = os.path.join(cache_dir, f"ign_mdt{paso:02d}_{x}_{y}.tif")
            if not os.path.exists(f):
                params = {"SERVICE": "WCS", "VERSION": "2.0.1", "REQUEST": "GetCoverage",
                          "COVERAGEID": f"Elevacion25830_{paso}", "FORMAT": "image/tiff",
                          "SUBSET": [f"x({x},{x + bloque})", f"y({y},{y + bloque})"]}
                _get(IGN_WCS, params, f)
            ficheros.append(f)
    srcs = [rasterio.open(f) for f in ficheros]
    arr, tr = merge(srcs)
    for s in srcs: s.close()
    a = arr[0].astype(np.float32)
    a[a < -100] = np.nan   # sin dato (mar / fuera de España)
    return a, tr


def mdt_copernicus(xmin, ymin, xmax, ymax, cache_dir, paso=10):
    """Copernicus GLO-30 (COG en AWS) reproyectado a EPSG:25830 con paso `paso` m."""
    from pyproj import Transformer
    t = Transformer.from_crs(25830, 4326, always_xy=True)
    lons, lats = t.transform([xmin, xmax, xmin, xmax], [ymin, ymin, ymax, ymax])
    nx, ny = int((xmax - xmin) / paso), int((ymax - ymin) / paso)
    dst = np.full((ny, nx), np.nan, np.float32)
    dst_tr = from_origin(xmin, ymax, paso, paso)
    for la in range(math.floor(min(lats)), math.floor(max(lats)) + 1):
        for lo in range(math.floor(min(lons)), math.floor(max(lons)) + 1):
            ns = f"N{la:02d}" if la >= 0 else f"S{-la:02d}"
            ew = f"E{lo:03d}" if lo >= 0 else f"W{-lo:03d}"
            nombre = f"Copernicus_DSM_COG_10_{ns}_00_{ew}_00_DEM"
            url = f"/vsicurl/https://copernicus-dem-30m.s3.amazonaws.com/{nombre}/{nombre}.tif"
            tmp = np.full((ny, nx), np.nan, np.float32)
            with rasterio.Env(GDAL_HTTP_TIMEOUT=60, GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR"):
                with rasterio.open(url) as src:
                    reproject(rasterio.band(src, 1), tmp, dst_transform=dst_tr, dst_crs="EPSG:25830",
                              resampling=Resampling.bilinear, dst_nodata=np.nan)
            dst = np.where(np.isnan(dst), tmp, dst)
    return dst, dst_tr


class Mdt:
    """Rejilla de alturas con muestreo bilineal en coordenadas UTM."""
    def __init__(self, arr, transform):
        self.a = arr; self.tr = transform
        self.x0, self.paso, self.y0 = transform.c, transform.a, transform.f
        # rellenar huecos con el vecino más cercano
        if np.isnan(arr).any():
            from scipy import ndimage
            idx = ndimage.distance_transform_edt(np.isnan(arr), return_distances=False, return_indices=True)
            self.a = arr[tuple(idx)]

    def muestrear(self, x, y):
        c = (np.asarray(x) - self.x0) / self.paso - 0.5
        f = (self.y0 - np.asarray(y)) / self.paso - 0.5
        c = np.clip(c, 0, self.a.shape[1] - 1.001); f = np.clip(f, 0, self.a.shape[0] - 1.001)
        c0 = np.floor(c).astype(int); f0 = np.floor(f).astype(int)
        dc = c - c0; df = f - f0
        a = self.a
        return (a[f0, c0] * (1 - dc) * (1 - df) + a[f0, c0 + 1] * dc * (1 - df) +
                a[f0 + 1, c0] * (1 - dc) * df + a[f0 + 1, c0 + 1] * dc * df)
