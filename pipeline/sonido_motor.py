#!/usr/bin/env python3
"""Genera los bucles del sonido del motor (juego/datos/sonido/*.ogg + motor.json) por síntesis procedural.
4 cilindros en línea (orden 1-3-4-2), gasolina TSI y diésel TDI, bandas de rpm con carga y en retención.
Uso: python3 pipeline/sonido_motor.py   (necesita numpy, scipy y ffmpeg con libvorbis)"""
import json, os, subprocess, numpy as np, scipy.io.wavfile as wavf

FS = 32000
AQUI = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(AQUI, '..', 'juego', 'datos', 'sonido')
WRK = '/tmp/sonido_motor_wrk'
MOTORES = {"tsi": {"idle": 700, "corte": 6500, "bands": [700, 1000, 1400, 1900, 2500, 3200, 4000, 4900, 5800, 6800], "diesel": False}, "tdi": {"idle": 800, "corte": 5000, "bands": [800, 1100, 1500, 2000, 2600, 3300, 4100, 5200], "diesel": True}}

def freqs(L): return np.fft.rfftfreq(L, 1 / FS)
def lowpass2(f, fc, q=0.707):
    s = 1j * f / fc; return 1 / (s * s + s / q + 1)
def highpass2(f, fc, q=0.707):
    s = 1j * f / fc; return (s * s) / (s * s + s / q + 1)
def peak(f, f0, q, g):  # resonancia (filtro de pico en frecuencia)
    s = 1j * f / f0; return 1 + (10 ** (g / 20) - 1) * (s / q) / (s * s + s / q + 1)
def circ_noise(L, rng): return rng.standard_normal(L)
def apply_H(x, H): return np.fft.irfft(np.fft.rfft(x) * H, len(x))

def render(m, rpm_nom, carga, seed, dur=2.0):
    rng=np.random.default_rng(seed)
    ciclo=120.0/rpm_nom
    K=max(4,int(round(dur/ciclo)))
    L=int(round(K*ciclo*FS)); L+=L%2
    rpm=K*120.0/(L/FS)            # rpm real del bucle (ciclos enteros)
    T=L/FS; f=freqs(L)
    dsl=m['diesel']
    x_rel=max(0.0,(rpm-m['idle'])/(m['corte']-m['idle']))
    intervalo=30.0/rpm            # 4 cilindros: una explosión cada 180° de cigüeñal
    orden=[0,2,3,1]               # 1-3-4-2
    # variación fija por cilindro (inyector, colector) y aleatoria por ciclo
    a_cil=1+np.array([0.0,-0.07,0.05,-0.03])*(1.6 if carga<0.5 else 1.0)
    t_cil=np.array([0.0,0.012,-0.008,0.006])*intervalo
    sig_a={True:0.05,False:0.16}[carga>0.5] if not dsl else {True:0.04,False:0.09}[carga>0.5]
    sig_a*=1.0+1.5*max(0,0.3-x_rel)   # más irregular a ralentí
    sig_t=0.004*intervalo*(1+2*max(0,0.3-x_rel))
    n=K*4
    tk=[];ak=[];ck=[]
    for i in range(n):
        c=orden[i%4]
        tk.append((i*intervalo+t_cil[c]+rng.normal(0,sig_t))%T)
        ak.append(a_cil[c]*max(0.2,rng.normal(1,sig_a)))
        ck.append(c)
    tk=np.array(tk); ak=np.array(ak); ck=np.array(ck)
    # --- escape: pulso de apertura de válvula (forma gamma) por cilindro con su rebote en el colector ---
    tau=(0.45e-3 if not dsl else 0.55e-3)*(1.0 if carga>0.5 else 1.4)
    P=1/(1+1j*2*np.pi*f*tau)**2                  # pulso gamma (t·e^{-t/τ})
    esc=np.zeros_like(f,complex)
    d_run=[1.6e-3,2.1e-3,1.9e-3,1.5e-3]
    for c in range(4):
        sel=ck==c
        D=np.exp(-2j*np.pi*np.outer(f,tk[sel]))@ak[sel]
        esc+=D*P*(1-0.45*np.exp(-2j*np.pi*f*d_run[c]))
    # tubo de escape: peine con realimentación (resonancias del tubo) + silenciosos
    Dp=2*3.2/470.0
    Hpipe=1/(1+0.42*np.exp(-2j*np.pi*f*Dp))
    if not dsl:
        Hm=lowpass2(f,950,0.8)*highpass2(f,35)*peak(f,95,3,4)*peak(f,180,4,3)*peak(f,420,3,-4)*peak(f,1600,2,3)
    else:
        Hm=lowpass2(f,620,0.7)*highpass2(f,35)*peak(f,80,3,4)*peak(f,240,3,2)*peak(f,900,2,-3)
    escape=np.fft.irfft(esc*Hpipe*Hm,L)
    escape/=np.sqrt(np.mean(escape**2))+1e-12
    # envolvente de explosiones (para modular ruidos)
    E=np.exp(-2j*np.pi*np.outer(f,tk))@ak
    env=np.fft.irfft(E/(1+1j*2*np.pi*f*(1.5e-3+0.25*intervalo*0.2)),L)
    env=np.maximum(env,0); env/=env.max()+1e-12
    # --- ruido de flujo en el escape (turbulencia), crece con rpm ---
    nz=circ_noise(L,rng)
    flujo=apply_H(nz,lowpass2(f,1400 if not dsl else 900,0.7)*highpass2(f,120))*(0.35+0.65*env)
    flujo/=np.sqrt(np.mean(flujo**2))
    g_flujo=(0.10+0.45*x_rel**1.5)*(1.0 if carga>0.5 else 0.6)
    y=escape+g_flujo*flujo
    # --- admisión (gasolina con carga: rugido de la caja de aire) ---
    if carga>0.5:
        nz2=circ_noise(L,rng)
        adm=apply_H(nz2*(0.25+0.75*np.roll(env,int(0.25*intervalo*FS))),highpass2(f,350,0.9)*lowpass2(f,2600,0.9)*peak(f,700,2,5))
        adm/=np.sqrt(np.mean(adm**2))
        y+=(0.08+0.35*x_rel**1.3)*(1.0 if not dsl else 0.5)*adm
    # --- diésel: traqueteo de la combustión (golpe de presión a cada inyección) ---
    if dsl:
        nz3=circ_noise(L,rng)
        golpe=np.fft.irfft(E/(1+1j*2*np.pi*f*0.7e-3),L); golpe=np.maximum(golpe,0); golpe/=golpe.max()
        cl=apply_H(nz3*golpe**1.5,highpass2(f,1300,0.8)*lowpass2(f,4500,0.7)*peak(f,2300,3,6))
        cl/=np.sqrt(np.mean(cl**2))
        g_cl=(0.55 if carga>0.5 else 0.06)*(1.0-0.55*x_rel)
        y+=g_cl*cl
    # --- mecánica (distribución, cadena/correa): ruido fino débil ---
    nz4=circ_noise(L,rng)
    mec=apply_H(nz4*(0.5+0.5*np.cos(2*np.pi*np.arange(L)/FS*rpm/60*4)),highpass2(f,2500)*lowpass2(f,7000))
    mec/=np.sqrt(np.mean(mec**2))
    y+=0.035*(0.5+x_rel)*mec
    # nivel: más fuerte con rpm y con carga
    db=-25+13*x_rel**0.8
    if carga<0.5: db-= (6 if not dsl else 7) - 2*x_rel
    y*=10**(db/20)/np.sqrt(np.mean(y**2))
    return y.astype(np.float32), rpm


def main():
    os.makedirs(OUT, exist_ok=True); os.makedirs(WRK, exist_ok=True)
    allw = {}; manifest = {'fs': FS, 'motores': {}}
    for nom, m in MOTORES.items():
        bandas = []
        for i, b in enumerate(m['bands']):
            for carga, tag in ((1, 'carga'), (0, 'retencion')):
                y, r = render(m, b, carga, seed=(sum(map(ord, nom)) * 1000 + i * 7 + carga))
                allw[f'{nom}_{tag}_{i:02d}'] = y
            bandas.append(round(r, 2))
        manifest['motores'][nom] = {'rpm': bandas, 'ralenti': m['idle'], 'corte': m['corte']}
    rng = np.random.default_rng(7)
    L = 64000; f = freqs(L); t = np.arange(L) / FS
    ph = 2 * np.pi * 2800.0 * t + 0.9 * np.sin(2 * np.pi * 3 * t) + 0.4 * np.sin(2 * np.pi * 7 * t)
    whine = np.sin(ph) + 0.25 * np.sin(2 * ph) + 0.1 * np.sin(3 * ph)
    hiss = apply_H(rng.standard_normal(L), highpass2(f, 1800, 0.8) * lowpass2(f, 7000, 0.8) * peak(f, 4200, 2, 6))
    hiss /= np.sqrt(np.mean(hiss ** 2)); whine /= np.sqrt(np.mean(whine ** 2))
    turbo = 0.6 * whine + 0.8 * hiss; turbo *= 10 ** (-24 / 20) / np.sqrt(np.mean(turbo ** 2))
    allw['turbo'] = turbo.astype(np.float32)
    Ls = int(0.7 * FS); ts = np.arange(Ls) / FS; fs_ = freqs(Ls)
    s = apply_H(rng.standard_normal(Ls), highpass2(fs_, 900, 0.8) * lowpass2(fs_, 6000, 0.7) * peak(fs_, 2600, 1.5, 5))
    s *= (1 - np.exp(-ts / 0.012)) * np.exp(-ts / 0.17) * (1 + 0.25 * np.sin(2 * np.pi * 38 * ts) * np.exp(-ts / 0.1))
    s *= 10 ** (-14 / 20) / np.abs(s).max(); s[-200:] *= np.linspace(1, 0, 200)
    allw['soplo'] = s.astype(np.float32)
    G = 0.89 / max(np.abs(v).max() for v in allw.values())   # misma ganancia para todos: conserva los niveles
    for k, v in allw.items():
        w = f'{WRK}/{k}.wav'; wavf.write(w, FS, (v * G * 32767).astype(np.int16))
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', w, '-c:a', 'libvorbis', '-q:a', '4', f'{OUT}/{k}.ogg'], check=True)
    manifest['nota'] = 'Bucles generados por pipeline/sonido_motor.py (síntesis procedural). rpm = rpm exactas de cada bucle (ciclos enteros).'
    json.dump(manifest, open(f'{OUT}/motor.json', 'w'), ensure_ascii=False, indent=1)

if __name__ == '__main__':
    main()
