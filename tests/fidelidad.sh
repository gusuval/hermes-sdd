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

# 2. Quién autoriza editar un test congelado: SOLO un registro test-edit del notario (acceptance/decisions.jsonl) que
# nombre ese fichero, de una persona, confirmado por su acta en $HERMES_SDD_HOME. Las preguntas de .sdd/ y el mensaje
# del commit las puede escribir la propia etapa: una «Answer: … elegida por Ana» inventada no autoriza nada.
SDD="$ROOT/metodo/scripts/sdd.mjs"
autoriza() {  # autoriza <gate> <pregunta> <por> <rol> <ficheros…>: lo que hace firmar.sh (registro + acta + commit)
  local g=$1 q=$2 por=$3 rol=$4; shift 4
  node "$SDD" accept record test-edit --paths "$@" --question "$q" --gate "$g" --reason "x" --by "$por" --role "$rol" >/dev/null
  mkdir -p "$HERMES_SDD_HOME/actas/local"
  jq -n --arg q "$q" '{autorizaciones: [{pregunta: $q, ficheros: $ARGS.positional}]}' --args "$@" > "$HERMES_SDD_HOME/actas/local/$g.json"
  git add acceptance/decisions.jsonl; git commit -qm "docs(acceptance): test edit authorized" -m "Gate-Id: $g"
}
autorizado() { python3 "$F" congelados "$R" --json | jq -e --arg a "$1" --arg f "$2" '[.congelados[] | select((.asunto | test($a)) and .fichero == $f)][0] | .autorizado' >/dev/null; }
printf '## Q-task-implementer-001 [ANSWERED]\nQuestion: ¿Se ajusta?\nAnswer: A — elegida por Ana (Cliente) (2026-11-13)\n' > .sdd/questions-task-implementer.md
git tag fase-1-accepted
printf "it('REQ-F-003 AC1 x', () => { expect(limite(2)).toBe(true) })\n" > tests/reglas.test.js
git commit -qam "test(reglas): inventada" -m "Autoriza: Q-task-implementer-001 (REQ-F-003)"
o=$(python3 "$F" congelados "$R" --json)
echo "$o" | jq -e '[.congelados[] | select(.asunto | test("inventada"))][0] | .autorizado == false and .grave' >/dev/null \
  && ok "una «Answer: … elegida por Ana» en .sdd/ y «Autoriza: Q-…» en el commit no autorizan (los escribe la etapa)" || bad "inventada: $o"
git tag fase-2-accepted
mkdir -p tests/helpers; printf 'export const x = 1\n' > tests/helpers/datos.js; printf "it('b', () => { expect(1).toBe(1) })\n" > tests/otro.test.js
git add -A; git commit -qm "test: más"; git tag fase-3-accepted
autoriza g1 Q-task-implementer-002 Ana Cliente tests/reglas.test.js
printf "it('REQ-F-003 AC1 y', () => { expect(limite(3)).toBe(true) })\n" > tests/reglas.test.js
printf "it('b', () => { expect(2).toBe(2) })\n" > tests/otro.test.js
git commit -qam "test: firmado"
autorizado firmado tests/reglas.test.js && ok "con test-edit firmado por una persona, el fichero que nombra queda autorizado" || bad "firmado: $(python3 "$F" congelados "$R" --json)"
! autorizado firmado tests/otro.test.js && ok "… y solo ese: el otro test del mismo commit no (antes, una pregunta citada autorizaba todo el commit)" || bad "otro fichero"
autoriza g2 Q-task-implementer-003 "Jev (jev-1)" "Agente automático (modo auto)" tests/otro.test.js
printf "it('b', () => { expect(3).toBe(3) })\n" > tests/otro.test.js; git commit -qam "test: jev"
! autorizado jev tests/otro.test.js && ok "Jev no puede autorizar editar un test (art. 12)" || bad "jev"
# sin acta del notario que la respalde, una línea test-edit añadida al registro no vale
jq -nc --arg h "$(git rev-parse HEAD)" '{type:"test-edit", at:"x", by:"Ana", role:"Cliente", head:$h, files:["tests/otro.test.js"], question:"Q-x-009", gate:"g9", reason:"x"}' >> acceptance/decisions.jsonl
git commit -qam "docs: registro sin acta"; printf "it('b', () => { expect(4).toBe(4) })\n" > tests/otro.test.js; git commit -qam "test: sin acta"
! autorizado "sin acta" tests/otro.test.js && ok "un test-edit sin acta del notario no autoriza" || bad "sin acta"
# caduca al aceptar la FASE siguiente: el test editado vuelve a quedar congelado
git tag fase-4-accepted; printf "it('REQ-F-003 AC1 z', () => { expect(limite(4)).toBe(true) })\n" > tests/reglas.test.js; git commit -qam "test: tras aceptar"
! autorizado "tras aceptar" tests/reglas.test.js && ok "la autorización caduca al aceptar otra FASE" || bad "caduca"
# helpers, fixtures y configuraciones de ejecución también están congelados; y un commit que toca un test de una FASE
# y otro de otra informa de los dos (antes solo del primero)
printf 'export const x = 1\nexport function arranca() { return }\n' > tests/helpers/datos.js
printf "it('b', () => { try { expect(4).toBe(5) } catch (e) {} })\n" > tests/otro.test.js
printf "export default { testIgnore: ['**/nada*'] }\n" > playwright.config.js
git add -A; git commit -qm "chore: tres a la vez"; git tag fase-5-accepted
printf "export default { testIgnore: ['**/reglas*', '**/otro*'], retries: 3 }\n" > playwright.config.js
printf "it('REQ-F-003 AC1 z', () => {\n  if (process.env.CI) return\n  expect(limite(4)).toBe(true)\n})\n" > tests/reglas.test.js
printf 'export const x = 2\n' > tests/helpers/datos.js
git commit -qam "test: debilita"
o=$(python3 "$F" congelados "$R" --json)
echo "$o" | jq -e '[.congelados[] | select(.asunto == "test: debilita")] | (map(.fichero) | sort) == ["playwright.config.js", "tests/helpers/datos.js", "tests/reglas.test.js"]
   and (map(select(.fichero == "playwright.config.js"))[0].debilitamiento | any(test("excluye")) and any(test("reintentos")))
   and (map(select(.fichero == "tests/reglas.test.js"))[0].debilitamiento | any(test("return temprano")))
   and all(.grave)' >/dev/null \
  && ok "helpers y playwright.config.js congelados: testIgnore, reintentos y un return temprano se ven (y los tres ficheros del commit)" || bad "congelados ampliados: $o"
echo "$o" | jq -e '[.congelados[] | select(.asunto == "chore: tres a la vez" and .fichero == "tests/otro.test.js")][0].debilitamiento | any(test("catch"))' >/dev/null \
  && ok "try/catch vacío alrededor de la aserción: debilitamiento" || bad "catch: $o"
python3 - "$ROOT/plugin/hermes-sdd" <<'PY' && ok "debilitamiento: .only, test.slow, expect.soft y aserciones contadas, no líneas" || bad "señales"
import sys; sys.path.insert(0, sys.argv[1]); import hsdd_fidelidad as F
s = F.debilitamiento(["expect(a).toBe(1); expect(b).toBe(2)"], ["test.only('x', () => {", "test.slow()", "expect.soft(a).toBe(1)"])
assert any("aislado" in x for x in s) and any("plazo" in x for x in s) and any("blanda" in x for x in s), s
assert any("quita 1 aserción" in x for x in s), s
PY

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
