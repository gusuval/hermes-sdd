"""Qué hallazgos de fidelidad (.sdd/hermes/fidelidad-<N>.json) puede arreglar la pasada de arreglo de etapa.sh.

Un error de `sdd lint --captures` es grave y lanza la pasada de arreglo. Pero si la captura mala está en un test que ya
existía al aceptar una FASE (existe en el último tag fase-*-accepted: congelado, art. 12) y nadie ha firmado permiso
para editarlo, el implementador no puede tocarlo: la pasada solo servía para que escribiera una pregunta [OPEN]. Esos
casos no cuentan para la pasada: llegan a la puerta como pregunta propuesta (.sdd/questions-fidelidad.md) con
«efecto: editar-test <fichero>», y la persona decide. Los de tests nuevos siguen yendo a la pasada de arreglo.

    hsdd_hallazgos.py arreglables <repo> <fase>   cuántos graves puede arreglar la pasada (y deja las preguntas)
    hsdd_hallazgos.py lineas <repo> <fase>        una línea por hallazgo arreglable, para el implementador
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

FICHERO_Q = Path(".sdd") / "questions-fidelidad.md"


def _git(repo: Path, *args: str) -> str:
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def ultima_aceptacion(repo: Path) -> str:
    return _git(repo, "describe", "--tags", "--abbrev=0", "--match", "fase-*-accepted").strip()


def _autorizados(repo: Path, tag: str) -> set:
    """Ficheros con permiso firmado (test-edit en acceptance/decisions.jsonl) desde la última aceptación."""
    antes = set(_git(repo, "show", f"{tag}:acceptance/decisions.jsonl").splitlines())
    out = set()
    for l in _git(repo, "show", "HEAD:acceptance/decisions.jsonl").splitlines():
        if l in antes:
            continue
        try:
            r = json.loads(l)
        except ValueError:
            continue
        if r.get("type") == "test-edit":
            out.update(r.get("files") or [])
    return out


def congeladas(repo: Path, res: dict) -> list[dict]:
    """Los errores de sdd lint --captures en tests ya aceptados y sin permiso para editarlos."""
    tag = ultima_aceptacion(repo)
    if not tag:
        return []
    ya = set(_git(repo, "ls-tree", "-r", "--name-only", tag).splitlines())
    permiso = _autorizados(repo, tag)
    return [{**x, "congelado_en": tag} for x in res.get("lint_capturas", [])
            if x.get("grave") and x.get("fichero") in ya and x.get("fichero") not in permiso]


def _leer(repo: Path, fase: str) -> dict:
    try:
        return json.loads((repo / ".sdd" / "hermes" / f"fidelidad-{fase or 'global'}.json").read_text())
    except (OSError, ValueError):
        return {}


def arreglables(repo: Path, fase: str) -> int:
    res = _leer(repo, fase)
    return max(0, int(res.get("graves") or 0) - len(congeladas(repo, res)))


def lineas(repo: Path, fase: str) -> list[str]:
    r = _leer(repo, fase)
    fuera = {(x["fichero"], x.get("linea"), x.get("codigo")) for x in congeladas(repo, r)}
    out = []
    for x in r.get("congelados", []):
        if x.get("grave"):
            out.append(f"- test ya aceptado cambiado ({x['fichero']}, {x['commit']}): {x['autorizacion']}; {', '.join(x['debilitamiento'])}")
    for x in r.get("capturas", []):
        if x.get("grave"):
            out.append(f"- {x['req']} AC{x['ac']}: la captura {', '.join(x['capturas'])} no enseña {', '.join(x['no_se_ve'])}")
    for x in r.get("lint_capturas", []):
        if x.get("grave") and (x.get("fichero"), x.get("linea"), x.get("codigo")) not in fuera:
            out.append(f"- {x['fichero']}{':' + str(x['linea']) if x.get('linea') else ''} [{x['codigo']}]: {x['mensaje']}")
    for x in r.get("mutantes", []):
        if x.get("grave"):
            out.append(f"- {x['req']} AC{x['ac']}: si «{x['texto']}» cambia en {', '.join(x.get('en', []))}, ningún test lo nota")
    return out


def _titulos(repo: Path) -> dict:
    try:
        t = (repo / "requirements" / "REQUIREMENTS.md").read_text()
    except OSError:
        return {}
    return {m.group(1): m.group(2).strip() for m in re.finditer(r"^###\s+(REQ-[A-Z]+-\w+)\s*:?\s*(.*)$", t, re.M)}


def preguntas(repo: Path, fase: str) -> list[str]:
    """Una pregunta [OPEN] por test congelado con capturas mal tomadas, si no se ha hecho ya para esa aceptación
    (una respuesta «se queda como está» no se repite hasta la aceptación siguiente). Devuelve los ids escritos."""
    malas = congeladas(repo, _leer(repo, fase))
    if not malas:
        return []
    f = repo / FICHERO_Q
    texto = f.read_text() if f.exists() else "# Questions — fidelidad\n"
    todas = "".join(p.read_text() for p in sorted((repo / ".sdd").glob("questions-*.md")) if p != f)
    nnn = max([int(n) for n in re.findall(r"^## Q-fidelidad-(\d{3})", texto, re.M)] or [0])
    titulos = _titulos(repo)
    por_fichero: dict = {}
    for x in malas:
        por_fichero.setdefault(x["fichero"], []).append(x)
    escritas = []
    for fichero, xs in por_fichero.items():
        tag = xs[0]["congelado_en"]
        ya = re.search(rf"^## Q-fidelidad-\d{{3}} \[(?:OPEN|ANSWERED)\][^\n]*congelado={re.escape(tag)}\b[^\n]*\n(?:(?!^## ).*\n)*?\s+efecto: editar-test {re.escape(fichero)}\s*$",
                       texto, re.M)
        abierta_otra = re.search(rf"^## Q-[^\n]*\[OPEN\][^\n]*\n(?:(?!^## ).*\n)*?\s+efecto: editar-test [^\n]*{re.escape(fichero)}", todas, re.M)
        if ya or abierta_otra:
            continue
        nnn += 1
        qid = f"Q-fidelidad-{nnn:03d}"
        errores = "; ".join(f"{x.get('codigo')} line {x.get('linea')}" + (f" ({x['req']} AC{x['ac']})" if x.get("req") else "")
                            + f": {x.get('mensaje')}" for x in xs[:6]) + (f"; and {len(xs) - 6} more" if len(xs) > 6 else "")
        reqs = list(dict.fromkeys(titulos.get(x.get("req"), "") for x in xs if x.get("req")))
        de = (" (de «" + "», «".join(r for r in reqs[:3] if r) + "»)") if any(reqs[:3]) else ""
        texto = texto.rstrip("\n") + f"""

## {qid} [OPEN] skill=hermes-sdd context=sdd-lint-captures FASE-{fase} congelado={tag}
Question: `sdd lint --captures --fase {fase}` reports errors in {fichero}, a test that already existed when {tag} was accepted (frozen, Art. 12): the implementer cannot fix it without a person's signed authorization. {errores}
Para el cliente: Algunas capturas de una prueba que ya aceptaste{de} no enseñan bien lo que dice su criterio, y esa prueba no se puede tocar sin tu permiso. ¿Dejas que se corrija?
Options:
  A) Authorize editing {fichero} so its captures are taken as sdd lint --captures asks (recommended)
     efecto: editar-test {fichero}
     cliente: Sí, que se corrija esa prueba (solo esa) para que sus capturas enseñen lo que dice el criterio
  B) Leave the accepted test as it is
     efecto: ninguno
     cliente: No, que se quede como está, aunque esas capturas sigan sin enseñar bien su criterio
Blocks: nothing (the captures stay wrong until a person authorizes the edit)
Answer:
"""
        escritas.append(qid)
    if escritas:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(texto, encoding="utf-8")
    return escritas


if __name__ == "__main__":
    accion, repo, fase = sys.argv[1], Path(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else "")
    if accion == "arreglables":
        preguntas(repo, fase)
        print(arreglables(repo, fase))
    elif accion == "lineas":
        print("\n".join(lineas(repo, fase)))
    else:
        sys.exit(f"acción desconocida: {accion}")
