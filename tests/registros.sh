#!/usr/bin/env bash
# Lo que el ejecutor añade a los registros (incidente del 13/10/2026): una medición de la CLI que no pudo commitear la
# commitea el arnés; una decisión humana fabricada o un registro reescrito paran la etapa sin commitear nada.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HERMES_SDD_HOME="$T/home" HERMES_SDD_SIN_KANBAN=1; mkdir -p "$HERMES_SDD_HOME"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
R="$T/practica"; bash "$ROOT/practicar.sh" "$ROOT/grabaciones/todo-app" "$R" --sin-kanban >/dev/null
git -C "$R" config user.email a@a; git -C "$R" config user.name Alumna
jq '.ejecutores.plan = "../tests/ejecutor-falso"' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
etapa() { FALSO_MODO=$1 bash "$ROOT/etapa.sh" "$R" plan | tail -1; }
D=acceptance/decisions.jsonl

h=$(git -C "$R" rev-parse HEAD); o=$(etapa medicion)
[ "$(git -C "$R" log -1 --format=%s)" = "docs(sdd): changes left uncommitted by the plan-architect stage" ] &&
  [ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ] &&
  echo "$o" | jq -r .reason | grep -vq "registros humanos" &&
  ok "medición de la CLI sin commitear → la commitea el arnés" || bad "medición: $o"

h=$(git -C "$R" rev-parse HEAD); o=$(etapa humano)
[ "$(echo "$o" | jq -r .outcome)" = failed ] && echo "$o" | jq -r .reason | grep -q "no son mediciones de la CLI" &&
  ok "decisión humana fabricada por el ejecutor → la etapa falla" || bad "humano: $o"
git -C "$R" reset -q --hard "$h"

o=$(etapa borra)
[ "$(echo "$o" | jq -r .outcome)" = failed ] && echo "$o" | jq -r .reason | grep -q "borradas o cambiadas" &&
  [ -n "$(git -C "$R" status --porcelain -- "$D")" ] && [ "$(git -C "$R" rev-parse HEAD)" = "$h" ] &&
  ok "registro reescrito → la etapa falla y no se commitea" || bad "borra: $o"
git -C "$R" checkout -q -- "$D"

# Un cambio de requisitos que no sube la versión: la etapa falla y no abre una puerta que el notario no podría firmar
# (practica-todo-2, INT-001: replay no trae la etapa «cambio»; la persona aprobó y chocó con el tag requirements-v1.0)
V=$(sed -n 's/^> \*\*Version:\*\* *//p' "$R/requirements/REQUIREMENTS.md" | head -1)
git -C "$R" tag -f "requirements-v${V:-1.0}" >/dev/null
mkdir -p "$R/intent" "$R/.sdd/hermes"; printf '# INT-001\n\n> otro cambio\n' > "$R/intent/INT-001.md"
git -C "$R" add intent && git -C "$R" commit -qm "docs(intent): INT-001"; echo INT-001 > "$R/.sdd/hermes/cambio-actual"
o=$(bash "$ROOT/etapa.sh" "$R" cambio 2>/dev/null | tail -1)
[ "$(echo "$o" | jq -r .outcome)" = failed ] && echo "$o" | jq -r .reason | grep -q "no subió la versión de los requisitos" &&
  ! ls "$R"/.sdd/hermes/puertas/*.json 2>/dev/null | xargs -r grep -l '"tipo": "requisitos"' | grep -q . &&
  ok "cambio sin subir la versión de los requisitos → la etapa falla sin abrir puerta" || bad "cambio sin versión: $o"
exit $fail
