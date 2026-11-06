#!/usr/bin/env python3
"""Motor v2: tablas de ciclo (síntesis por tabla de onda) para el sonido del motor en tiempo real (scripts/motor_sintesis.gd).
4 cilindros en línea (orden 1-3-4-2, una explosión cada 180° de cigüeñal → el 2º orden del cigüeñal domina), gasolina TSI
y diésel TDI. Por cada rpm de una rejilla y dos cargas (retención/corte de inyección y plena carga) se calcula UN ciclo de
motor (720°) por suma de armónicos de orden de ciclo, limitado en banda para esas rpm (sin aliasing al leerlo a 22.050 Hz),
con las resonancias del escape en Hz reales a esas rpm (el timbre no se estira con el tono, como pasaba al acelerar bucles).
El juego lee el ciclo con un acumulador de fase (continuo: sin clics ni escalones) y mezcla las tablas vecinas de rpm y de
carga; los ruidos (flujo del escape, admisión, soplido y silbido del turbo, válvula de descarga) son bucles de ruido filtrado
modulados por la envolvente de las explosiones. Todo es síntesis propia (sin grabaciones de terceros).
Uso: python3 pipeline/sonido_motor_v2.py   (numpy)"""
import json, os, numpy as np

FS = 22050                       # frecuencia de mezcla del generador en el juego
N = 2048                         # muestras por ciclo de motor en la tabla
NE = 256                         # muestras por ciclo de la envolvente de explosiones
AQUI = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(AQUI, '..', 'juego', 'datos', 'sonido')
MOT = {
 'tsi': dict(diesel=False, ralenti=700, corte=6500,
             rejilla=[550, 700, 850, 1000, 1200, 1450, 1700, 2000, 2350, 2750, 3200, 3700, 4250, 4850, 5500, 6200, 6900]),
 'tdi': dict(diesel=True, ralenti=800, corte=5000,
             rejilla=[600, 800, 950, 1100, 1300, 1550, 1800, 2100, 2450, 2850, 3300, 3800, 4350, 4950, 5500]),
}

def lp2(f, fc, q=0.707): s = 1j * f / fc; return 1 / (s * s + s / q + 1)
def hp2(f, fc, q=0.707): s = 1j * f / fc; return (s * s) / (s * s + s / q + 1)
def pk(f, f0, q, g): s = 1j * f / f0; return 1 + (10 ** (g / 20) - 1) * (s / q) / (s * s + s / q + 1)

def escape_H(f, dsl):
    """Respuesta del escape (colector → catalizador/FAP → silenciosos → cola), en Hz reales. Supuestos de un 2,0 l."""
    L = 3.4                                     # m, tubo hasta el silencioso trasero
    tubo = 1 / (1 + 0.35 * np.exp(-2j * np.pi * f * 2 * L / 480.0))
    rad = hp2(f, 45, 0.6)                       # radiación de la cola (poca energía por debajo de ~45 Hz)
    if not dsl:
        m = lp2(f, 1100, 0.75) * pk(f, 105, 2.5, 5) * pk(f, 210, 3, 2.5) * pk(f, 480, 2, -3) * pk(f, 1500, 1.8, 2)
    else:                                       # diésel: filtro de partículas, más apagado y grave
        m = lp2(f, 700, 0.7) * pk(f, 85, 2.5, 5) * pk(f, 260, 2.5, 2) * pk(f, 950, 2, -2)
    return tubo * rad * m

def ciclo(m, rpm, carga, rng_c):
    dsl = m['diesel']
    f0 = rpm / 120.0                            # Hz por orden de ciclo (720°)
    x = np.clip((rpm - m['ralenti']) / (m['corte'] - m['ralenti']), 0, 1.1)
    # límite de banda: la tabla se lee hasta un 25 % más rápido (hasta la rpm siguiente de la rejilla)
    flim = min(0.45 * FS / 1.25, 9000.0)
    H = int(min(N // 2 - 1, flim // f0))
    k = np.arange(1, H + 1); f = k * f0
    # explosiones: 4 por ciclo (1-3-4-2) con diferencias fijas entre cilindros (inyector, colector) → medios órdenes
    a_c = 1 + rng_c['a'] * (1.0 if carga > 0.5 else 2.2) * (1 + 1.5 * max(0, 0.25 - x))
    d_c = rng_c['d'] * (1 + 2 * max(0, 0.25 - x))
    fase = np.array([0.0, 0.25, 0.5, 0.75]) + d_c
    tau = (0.38e-3 if not dsl else 0.5e-3) * (1.0 if carga > 0.5 else 1.8)
    G = 1 / (1 + 1j * 2 * np.pi * f * tau) ** 2
    run = [1.5e-3, 2.0e-3, 1.8e-3, 1.4e-3]       # rebote en cada rama del colector (s)
    X = np.zeros(H, complex)
    for c in range(4):
        X += a_c[c] * G * np.exp(-2j * np.pi * k * fase[c]) * (1 - 0.4 * np.exp(-2j * np.pi * f * run[c]))
    X *= escape_H(f, dsl)
    Xe = X / (np.sqrt(np.sum(np.abs(X) ** 2) / 2) + 1e-12)
    # admisión pulsante (con carga): la caja de aire y el colector de admisión resuenan a ~500-700 Hz
    adm = np.zeros(H, complex)
    for c in range(4):
        adm += a_c[c] * np.exp(-2j * np.pi * k * (fase[c] + 0.31))
    adm *= hp2(f, 160) * lp2(f, 1800, 0.8) * pk(f, 620 if not dsl else 520, 2, 7)
    adm /= np.sqrt(np.sum(np.abs(adm) ** 2) / 2) + 1e-12
    g_adm = carga * (0.10 + 0.45 * x ** 1.4) * (1.0 if not dsl else 0.55)
    Y = Xe + g_adm * adm
    # diésel: golpe de combustión (presión que sube de golpe a cada inyección), banda 1,2-4 kHz
    if dsl:
        cl = np.zeros(H, complex)
        for c in range(4):
            cl += (1 + rng_c['a'][c] * 2) * np.exp(-2j * np.pi * k * (fase[c] - 0.012))
        cl *= hp2(f, 1200, 0.8) * lp2(f, 4200, 0.7) * pk(f, 2200, 2.5, 6) / (1 + 1j * 2 * np.pi * f * 0.12e-3)
        cl /= np.sqrt(np.sum(np.abs(cl) ** 2) / 2) + 1e-12
        Y = Y + (0.42 * carga + 0.10) * (1.0 - 0.6 * x) * cl
    # gasolina de inyección directa: el "tic" de los inyectores de alta presión a cada inyección (más claro a ralentí)
    if not dsl:
        tk = np.zeros(H, complex)
        for c in range(4):
            tk += np.exp(-2j * np.pi * k * (fase[c] + 0.42))
        tk *= hp2(f, 2600, 0.8) * lp2(f, 6500, 0.8) * pk(f, 4200, 3, 5)
        tk /= np.sqrt(np.sum(np.abs(tk) ** 2) / 2) + 1e-12
        Y = Y + 0.16 * carga * (1.0 - 0.7 * min(x, 1.0)) * tk     # con corte de inyección (retención) no hay tic
    # vibración del 2º orden (fuerzas libres de 2º orden de un 4 en línea): un poco de "bum" al 2º orden del cigüeñal
    Y[3] += 0.25 * (0.6 + 0.4 * carga) * np.exp(-0.7j)
    spec = np.zeros(N // 2 + 1, complex); spec[1:H + 1] = Y
    w = np.fft.irfft(spec, N)
    w /= np.sqrt(np.mean(w ** 2)) + 1e-12      # RMS 1: el nivel (rpm, carga) lo pone el juego (MotorSintesis._nivel)
    # envolvente de explosiones (para modular los ruidos): un pulso por explosión que decae
    te = np.arange(NE) / NE / f0                 # s dentro del ciclo
    T = 1 / f0
    env = np.zeros(NE)
    for c in range(4):
        dt = (te - fase[c] * T) % T
        env += a_c[c] * np.exp(-dt / (2.2e-3 + 0.12 * T / 4))
    env = 0.35 + 0.65 * env / env.max()
    return w.astype(np.float32), env.astype(np.float32)

def ruido(L, H, rng):
    r = np.fft.rfft(rng.standard_normal(L)) * H
    y = np.fft.irfft(r, L)                    # circular: el bucle cierra sin costura
    return (y / np.sqrt(np.mean(y ** 2))).astype(np.float32)

def main():
    os.makedirs(OUT, exist_ok=True)
    man = {'fs': FS, 'n': N, 'ne': NE, 'motores': {}, 'ruidos': {}}
    for nom, m in MOT.items():
        rng = np.random.default_rng(sum(map(ord, nom)))
        rng_c = {'a': np.array([0.0, -0.06, 0.05, -0.03]), 'd': np.array([0.0, 0.0035, -0.0025, 0.0015])}
        tab = []; env = []
        for r in m['rejilla']:
            for carga in (0.0, 1.0):
                w, e = ciclo(m, r, carga, rng_c); tab.append(w); env.append(e)
        np.concatenate(tab + env).astype('<f4').tofile(os.path.join(OUT, f'motor_v2_{nom}.bin'))
        man['motores'][nom] = {'rejilla': m['rejilla'], 'ralenti': m['ralenti'], 'corte': m['corte'], 'diesel': m['diesel'],
                               'orden': 'tablas[rpm][carga 0 retención,1 plena][N] y luego envolventes[rpm][carga][NE]'}
    rng = np.random.default_rng(11)
    L = FS                                      # 1 s por bucle de ruido
    f = np.fft.rfftfreq(L, 1 / FS)
    ru = {
        'flujo_tsi': hp2(f, 120) * lp2(f, 1500, 0.7) * pk(f, 420, 1.5, 3),
        'flujo_tdi': hp2(f, 100) * lp2(f, 950, 0.7) * pk(f, 300, 1.5, 3),
        'admision': hp2(f, 300, 0.8) * lp2(f, 2600, 0.8) * pk(f, 700, 2, 6),
        'turbo': hp2(f, 1900, 0.8) * lp2(f, 7500, 0.8) * pk(f, 4300, 2, 6),
        'soplo': hp2(f, 800, 0.8) * lp2(f, 6000, 0.7) * pk(f, 2500, 1.4, 5),
    }
    sal = []
    for i, (k, H) in enumerate(ru.items()):
        sal.append(ruido(L, H, rng)); man['ruidos'][k] = i
    np.concatenate(sal).astype('<f4').tofile(os.path.join(OUT, 'ruidos_v2.bin'))
    man['nota'] = 'Generado por pipeline/sonido_motor_v2.py (síntesis propia). Leído por scripts/motor_sintesis.gd.'
    json.dump(man, open(os.path.join(OUT, 'motor_v2.json'), 'w'), ensure_ascii=False, indent=1)
    print('ok', {k: os.path.getsize(os.path.join(OUT, f'motor_v2_{k}.bin')) for k in MOT})

if __name__ == '__main__':
    main()
