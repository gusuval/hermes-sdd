#!/usr/bin/env bash
# Fidelidad (hsdd_fidelidad.py): tests congelados que se cambian sin que una persona lo autorice, señales de
# debilitamiento, ejemplos que se contradicen y el OCR de una captura. Casos sacados de sala (12-13/11/2026).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HERMES_SDD_HOME="$T/home"; mkdir -p "$HERMES_SDD_HOME"
F="$ROOT/plugin/hermes-sdd/hsdd_fidelidad.py"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
R="$T/r"; mkdir -p "$R/tests" "$R/requirements" "$R/.sdd"; cd "$R"
git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false

cat > tests/reglas.test.js <<'J'
it('REQ-F-003 AC1 dos reservas por semana', () => {
  expect(limite(2)).toBe(true)
  expect(limite(1)).toBe(false)
})
J
git add -A; git commit -qm "test: reglas"; git tag fase-0-accepted

# 1. en una FASE posterior, sin pregunta que lo autorice: se quita la cita del criterio y una aserción, y se salta
cat > tests/reglas.test.js <<'J'
it.skip('dos reservas por semana', () => {
  expect(limite(2)).toBe(true)
})
J
git commit -qam "test(reglas): ajuste"
o=$(python3 "$F" congelados "$R" --json)
echo "$o" | jq -e '.congelados[0] | .autorizado == false and .grave and (.debilitamiento | any(test("deja de citar REQ-F-003 AC1"))) and (.debilitamiento | any(test("saltado"))) and (.debilitamiento | any(test("quita 1 aserción")))' >/dev/null \
  && ok "test congelado cambiado sin autorizar: deja de citar el criterio, quita una aserción y se salta" || bad "congelados: $o"

# 2. autorizado por una persona → autorizado; por Jev → no
printf '## Q-task-implementer-001 [ANSWERED]\nQuestion: ¿Se ajusta?\nAnswer: A — elegida por Ana (Cliente) (2026-11-13)\n\n## Q-task-implementer-002 [ANSWERED]\nQuestion: ¿Y este?\nAnswer: A — elegida por Jev (jev-1.14.0) (Agente automático (modo auto)) (2026-11-13)\n' > .sdd/questions-task-implementer.md
git tag fase-1-accepted
printf "it('REQ-F-003 AC1 x', () => { expect(limite(2)).toBe(true) })\n" > tests/reglas.test.js
git commit -qam "test(reglas): localizador exacto" -m "Autoriza: Q-task-implementer-001 (REQ-F-003)"
o=$(python3 "$F" congelados "$R" --json)
echo "$o" | jq -e '[.congelados[] | select(.asunto | test("localizador"))][0] | .autorizado and (.autorizacion | test("Ana"))' >/dev/null \
  && ok "con una pregunta contestada por una persona, el cambio está autorizado (REQ-F-003 no se confunde con una pregunta)" || bad "autorizado: $o"
git tag fase-2-accepted
printf "it('REQ-F-003 AC1 y', () => { expect(limite(3)).toBe(true) })\n" > tests/reglas.test.js
git commit -qam "test(reglas): otro" -m "Autoriza: Q-task-implementer-002"
o=$(python3 "$F" congelados "$R" --json)
echo "$o" | jq -e '[.congelados[] | select(.asunto | test("otro"))][0] | .autorizado == false and (.autorizacion | test("Jev"))' >/dev/null \
  && ok "Jev no puede autorizar editar un test (art. 12)" || bad "jev: $o"

# 3. coherencia: un ejemplo que dice tener 8 caracteres y tiene 7, y un día de la semana que no es
printf '### REQ-NF-003: Contraseñas\n- GIVEN la contraseña «haya-27» (8 caracteres) THEN entra\n- GIVEN el jueves 2026-11-13 THEN nada\n' > requirements/REQUIREMENTS.md
o=$(python3 "$F" coherencia "$R" --json)
echo "$o" | jq -e '[.coherencia[].detalle] | (any(test("«haya-27» dice tener 8 caracteres y tiene 7"))) and (any(test("2026-11-13 no es jueves")))' >/dev/null \
  && ok "coherencia: «haya-27» (8 caracteres) y «jueves 2026-11-13» no cuadran" || bad "coherencia: $o"

# 4. normalización para el OCR: «2ºB» y lo que lee el OCR («2°B»), guiones y tildes
python3 - "$ROOT/plugin/hermes-sdd" <<'PY' && ok "normalización: «2ºB» = «2°B», «18:00–19:00» = «18:00-19:00», tildes" || bad "normalización"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
assert F.norm("Vivienda 2ºB") == F.norm("Vivienda 2°B")
assert F.norm("18:00–19:00") == F.norm("18:00-19:00")
assert F.norm("Día Cancelada") == "dia cancelada"
PY

# 4b. mutantes: el texto se cambia en el código, nunca en los comentarios (sala: «5ºC» solo estaba en un comentario)
python3 - "$ROOT/plugin/hermes-sdd" <<'PY' && ok "mutantes: cambian el texto en el código y no en los comentarios" || bad "mutar"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
src = "// «5ºC» y «5ºc» son distintas\nconst t = 'Ocupada';\n  * Ocupada en el comentario\n"
m = F._muta(src, "Ocupada")
assert "const t = 'MUTANTE'" in m and "* Ocupada en el comentario" in m, m
assert F._visibles("GIVEN «4ºA» WHEN «2ºB» abre esa semana THEN el usuario ve la celda con la etiqueta «Ocupada»") == ["Ocupada"]
v = F._visibles('GIVEN "Iniciación" has 3 socios WHEN the socio "pablo" signs up THEN the user sees "Te has apuntado a Iniciación" (the same text as for "lucia"), and WHEN "pablo" signs up again THEN the user sees the message "Ya te habías apuntado a esta clase"')
assert v == ["Te has apuntado a Iniciación", "Ya te habías apuntado a esta clase"], v
assert F._visibles('GIVEN "carmen" has noviembre 2026 unpaid WHEN the administrador downloads that CSV THEN "carmen" does not appear') == []
assert F._visibles('GIVEN pablo WHEN abre Socios THEN ve el mensaje «No tienes permiso para hacer esto»') == ["No tienes permiso para hacer esto"]
PY

# 4c. criterios sin «Se ve» (los de antes): la negación subordinada solo quita lo que viene detrás; ENTONCES; un
# literal corto («No») no se da por visto por estar dentro de otra palabra del OCR
python3 - "$ROOT/plugin/hermes-sdd" <<'PY' && ok "visibles: negación subordinada, ENTONCES y literales cortos en el OCR" || bad "visibles"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
v = F._visibles('GIVEN "Iniciación" has 4 socios WHEN "pablo" tries to sign up THEN the user sees the message "La clase está completa", which does not list "pablo"')
assert v == ["La clase está completa"], v
assert F._visibles('DADO «lucia» CUANDO abre «Clases» ENTONCES el usuario ve «Iniciación»') == ["Iniciación"]
assert F._visibles('DADO «lucia» CUANDO abre «Socios» ENTONCES el usuario no ve «Dar de baja»') == []
assert not F.en_texto("No", "Nombre y noviembre")
assert F.en_texto("No", "No tienes permiso")
assert F.en_texto("Te has apuntado a Iniciación", "Clases · Tehasapuntado a Iniciación ·")   # el OCR junta palabras
PY

# 4d. capturas con el contrato «Se ve»: manda lo que el test comprobó en pantalla (el JSON del helper); el OCR es la
# segunda opinión; sin nada comprobable, «captura sin comprobar» (antes, silencio: 50 de 122 criterios del club)
mkdir -p "$R/evidencias/FASE-1"
printf 'png' > "$R/evidencias/FASE-1/REQ-F-013-AC1.png"
printf 'png' > "$R/evidencias/FASE-1/REQ-F-013-AC6.png"
printf '{"criterio":"REQ-F-013-AC1","test":"REQ-F-013 AC1 lucia","ve":["Te has apuntado a Iniciación"],"url":"/clases"}' > "$R/evidencias/FASE-1/REQ-F-013-AC1.json"
printf '{"criterio":"REQ-F-013-AC6","test":"REQ-F-013 AC6 pablo","ve":["Ya estás apuntada"]}' > "$R/evidencias/FASE-1/REQ-F-013-AC6.json"
python3 - "$ROOT/plugin/hermes-sdd" "$R" <<'PY' && ok "capturas: el JSON del helper frente a «Se ve:»; «captura sin comprobar»; «No visible» no se exige" || bad "capturas «Se ve»"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
from pathlib import Path
F.ocr = lambda p: ""          # sin OCR: solo cuenta lo comprobado por el test
img = lambda n: {"path": f"evidencias/FASE-1/{n}.png"}
crit = lambda n, text, sees, imgs: {"n": n, "text": text, "sees": sees, "shown_by": [i["path"] for i in imgs], "evidence": [], "tests": []}
acc = {"evidence_dir": "evidencias", "requirements": [{"id": "REQ-F-013", "priority": "Must", "criteria": [
  crit(1, 'GIVEN "Iniciación" has 3 socios WHEN "lucia" signs up THEN the user sees "Te has apuntado a Iniciación"',
       {"texts": [{"text": "Te has apuntado a Iniciación", "template": False}], "where": "Clases", "none": None}, [img("REQ-F-013-AC1")]),
  crit(6, 'GIVEN "Iniciación" has 3 socios WHEN "pablo" signs up THEN the user sees "Te has apuntado a Iniciación"',
       {"texts": [{"text": "Te has apuntado a Iniciación", "template": False}], "where": "Clases", "none": None}, [img("REQ-F-013-AC6")]),
  crit(7, 'GIVEN "lucia" dada de baja WHEN the date is 2032-11-12 THEN her payments are still available',
       {"texts": [], "where": None, "none": "lo comprueba el CSV"}, [img("REQ-F-013-AC1")]),
  crit(8, 'GIVEN "lucia" holds pista 2 WHEN "pablo" tries to cancel it THEN the system refuses and the reservation stays',
       None, [img("REQ-F-013-AC1")]),
]}]}
r = {(x["ac"]): x for x in F.capturas(Path(sys.argv[2]), acc)}
assert 1 not in r, r                                                   # el test afirmó el texto antes de capturar
assert r[6]["no_se_ve"] == ["Te has apuntado a Iniciación"] and r[6]["grave"], r[6]   # «apuntada» para pablo
assert 7 not in r, r                                                   # No visible: nada que exigir
assert r[8].get("sin_comprobar") and not r[8]["grave"], r[8]          # sin Se ve ni literales: se dice
F.ocr = lambda p: "Clases  Te has apuntado a Iniciación  4 de 4 plazas"
r = {(x["ac"]): x for x in F.capturas(Path(sys.argv[2]), acc)}
assert 6 not in r, r                                                   # el OCR como segunda opinión
PY

# 4e. vínculos con «Se ve»: «lucia» es dato del ejemplo (otro actor vale); «Hola, lucia» es un caso de la plantilla
python3 - "$ROOT/plugin/hermes-sdd" "$R" <<'PY' && ok "vínculos: con «Se ve» un test con otro actor (pablo) no «falta» el dato «lucia»" || bad "vínculos «Se ve»"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
from pathlib import Path
R = Path(sys.argv[2]); (R / "tests" / "clases.test.js").write_text("it('REQ-F-013 AC2 saludo', () => { expect(cabecera('pablo')).toBe(`Hola, ${u}`) })\n")
c = {"n": 2, "text": 'GIVEN "lucia" has a session WHEN she opens "Clases" THEN the user sees the heading "Hola, lucia"',
     "sees": {"texts": [{"text": "Hola, {usuario}", "template": True}], "where": "cabecera", "none": None},
     "tests": [{"file": "tests/clases.test.js", "name": "REQ-F-013 AC2 saludo"}]}
v = F.vinculos(R, {"requirements": [{"id": "REQ-F-013", "priority": "Must", "criteria": [c]}]})
assert v == [], v
c2 = dict(c, sees=None)
v = F.vinculos(R, {"requirements": [{"id": "REQ-F-013", "priority": "Must", "criteria": [c2]}]})
assert v and v[0]["faltan_then"] == ["Hola, lucia"], v                 # sin «Se ve», como antes
(R / "tests" / "clases.test.js").unlink()
PY

# 4f. mutantes sin ahogar la máquina: nice y pocos workers (configurable); lo que no se pudo hacer llega a la puerta
python3 - "$ROOT/plugin/hermes-sdd" <<'PY' && ok "mutantes: nice -n 10, --workers=2 / --maxWorkers=2, configurable por entorno" || bad "mutantes nice"
import os, sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
c = F._comando(["npx", "playwright", "test", "tests/e2e/a.spec.js"])
assert c == ["nice", "-n", "10", "npx", "playwright", "test", "--workers=2", "tests/e2e/a.spec.js"], c
assert F._comando(["npx", "vitest", "run", "x.test.js"])[-2:] == ["--maxWorkers=2", "x.test.js"]
os.environ["HSDD_MUT_WORKERS"] = "1"; os.environ["HSDD_MUT_NICE"] = "0"
assert F._comando(["npx", "playwright", "test"]) == ["npx", "playwright", "test", "--workers=1"]
PY
python3 - "$ROOT/plugin/hermes-sdd" "$T" <<'PY' && ok "revisión de la puerta: mutantes_error, textos «no está en el código», capturas sin comprobar y lint de capturas" || bad "revisión fidelidad"
import json, sys; sys.path.insert(0, sys.argv[1]); import hsdd_revision as V
from pathlib import Path
R = Path(sys.argv[2]) / "rev"; (R / ".sdd" / "hermes").mkdir(parents=True)
(R / ".sdd" / "hermes" / "fidelidad-7.json").write_text(json.dumps({
  "mutantes_error": "git worktree add: fatal: ya existe",
  "mutantes": [{"req": "REQ-F-013", "ac": 1, "texto": "Ya estás apuntada", "resultado": "no está en el código", "grave": False}],
  "capturas": [{"req": "REQ-F-023", "ac": 4, "capturas": ["a.png"], "no_se_ve": [], "sin_comprobar": True, "grave": False, "motivo": "x"}],
  "lint_capturas": [{"codigo": "C-03", "fichero": "tests/e2e/fase-0.journey.spec.js", "linea": 168, "req": "REQ-F-008", "ac": 4,
                     "mensaje": "the capture \"AC-008-04\" of REQ-F-008 AC4 is taken inside the test …", "grave": True}]}))
av = {a["codigo"]: a for a in V._fidelidad(R, "7")}
assert "ya existe" in av["mutantes-sin-hacer"]["texto"], av
assert "«Ya estás apuntada»" in av["texto-fuera-del-codigo"]["texto"], av
assert "REQ-F-023 AC4" in av["captura-sin-comprobar"]["texto"], av
assert av["captura-mal-tomada"]["grave"] and "fase-0.journey.spec.js:168" in av["captura-mal-tomada"]["texto"], av
PY

# 4g. lint de capturas desde fidelidad (lo que corre antes de aceptar): la captura de REQ-F-008 AC4 en un test.step
# de un recorrido que no cita el criterio (club, FASE-0) es grave
L="$T/lint"; mkdir -p "$L/requirements" "$L/tests/e2e"; ( cd "$L" && git init -q -b main )
printf '### REQ-F-008: Reservar\n- **Verification:** test\n- **Acceptance criteria:**\n  - GIVEN a WHEN b THEN the user sees "Reservada"\n  - GIVEN a WHEN c THEN the user sees "Ocupada"\n  - GIVEN a WHEN d THEN the user sees "Libre"\n  - GIVEN a WHEN e THEN the user sees "Esa pista ya está reservada a esa hora"\n' > "$L/requirements/REQUIREMENTS.md"
cat > "$L/tests/e2e/fase-0.journey.spec.js" <<'J'
test('WF-001 REQ-F-008 AC1 REQ-F-008 AC2 REQ-F-008 AC3 la socia reserva', async ({ page }, testInfo) => {
  await test.step('el reenvío da «Esa pista ya está reservada a esa hora»', async () => {
    await expect(page.getByRole('alert')).toHaveText('Esa pista ya está reservada a esa hora')
    await captura(page, testInfo, 'REQ-F-008-AC4')
  })
})
J
( cd "$L" && git add -A && git commit -qm init )
o=$(python3 "$F" lint_capturas "$L" --json)
echo "$o" | jq -e '.lint_capturas | any(.codigo == "C-03" and .req == "REQ-F-008" and .ac == 4 and .grave)' >/dev/null \
  && ok "lint de capturas: la captura de REQ-F-008 AC4 en un test.step de otro test es grave" || bad "lint_capturas: $o"

# 5. OCR de verdad (solo en macOS): una imagen con texto
if command -v swiftc >/dev/null && command -v sips >/dev/null; then
  cat > "$T/img.swift" <<'S'
import AppKit
let img = NSImage(size: NSSize(width: 420, height: 90)); img.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 420, height: 90).fill()
("Vivienda 2ºB · Ocupada" as NSString).draw(at: NSPoint(x: 10, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!; try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
S
  swift "$T/img.swift" "$T/c.png" 2>/dev/null
  python3 - "$ROOT/plugin/hermes-sdd" "$T/c.png" <<'PY' && ok "OCR: lee «Vivienda 2ºB» y «Ocupada» en una captura" || bad "ocr"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
from pathlib import Path
t = F.norm(F.ocr(Path(sys.argv[2])))
assert F.norm("Vivienda 2ºB") in t and "ocupada" in t, t
PY
fi
exit $fail
