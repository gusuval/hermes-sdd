#!/usr/bin/env bash
# Aceptar más barata sin perder garantías (club, 11/2026: la ronda adversarial fue el 70 % del coste de aceptar):
# la primera ronda de cada FASE es completa; las siguientes (tras el arreglo, re-aceptaciones) solo re-verifican los
# criterios cuya evidencia cambió; sin nada que re-verificar no se lanza ningún ejecutor; cada ronda consta en
# etapas.jsonl (completa | incremental, criterios, verificados); los veredictos usan el modelo barato del perfil y la
# ronda adversarial el de la etapa. Sobre la práctica todo-app reproducida, con el ejecutor falso en aceptar.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HERMES_SDD_HOME="$T/home" HERMES_SDD_SIN_KANBAN=1 HSDD_MUT_NICE=0; mkdir -p "$HERMES_SDD_HOME"
jq -n --arg u "$USER" '{yo:{nombre:"Alumna", rol:"Cliente", canales:{local:$u}}}' > "$HERMES_SDD_HOME/aprobadores.json"
fail=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; fail=1; }
R="$T/practica"; bash "$ROOT/practicar.sh" "$ROOT/grabaciones/todo-app" "$R" --sin-kanban >/dev/null || { echo "FAIL practicar"; exit 1; }
git -C "$R" config user.email a@a; git -C "$R" config user.name Alumna
paso() { local o p v; o=$(bash "$ROOT/etapa.sh" "$R" "$@" | tail -1); p=$(echo "$o" | jq -r '.puerta // empty'); [ -n "$p" ] || return 0
  v=${V:-acepto}; [ "$1" = ruta ] && v=$(jq -r '[.opciones[] | select(.auto == true) | .verbo][0] // [.opciones[] | select(.verbo | startswith("ruta-")) | .verbo][0]' "$HERMES_SDD_HOME/puertas/$p.json")
  bash "$ROOT/decidir.sh" "$p" "$v" >/dev/null; }
paso requisitos; paso ruta; paso plan; V=conforme paso tareas; paso implementar 0
[ -f "$R/plan/fases/FASE-0-"*.md ] 2>/dev/null || ls "$R"/plan/fases/FASE-0* >/dev/null 2>&1 || { echo "FAIL sin FASE-0 en la práctica"; exit 1; }

# Aceptar con el ejecutor falso (registra cada llamada: sub-paso, modelo, prompt)
jq '.ejecutores.aceptar = "../tests/ejecutor-falso" | del(.modelos)' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
export FALSO_LOG="$T/llamadas.jsonl"
aceptar() { : > "$FALSO_LOG"; bash "$ROOT/etapa.sh" "$R" aceptar 0 | tail -1 > "$T/res"; tail -1 "$R/.sdd/hermes/etapas.jsonl" > "$T/linea"; }
adversariales() { jq -s '[.[] | select(.prompt | test("--adversarial"))] | length' "$FALSO_LOG"; }

# 1. primera aceptación de la FASE: ronda completa, y su plan queda de base para la siguiente
aceptar
r=$(jq -c '.rondas_adversariales' "$T/linea")
[ "$(jq -r '.[0].tipo' <<< "$r")" = completa ] && [ "$(jq -r '.[0].criterios > 0 and .[0].verificados == .[0].criterios' <<< "$r")" = true ] \
  && ok "primera aceptación de la FASE: ronda completa ($(jq -r '.[0].verificados' <<< "$r") criterios) en etapas.jsonl" || bad "primera ronda: $r $(cat "$T/res")"
[ "$(adversariales)" = 1 ] && ! jq -r .prompt "$FALSO_LOG" | grep -q "INCREMENTAL" && ok "la ronda completa no pide nada incremental" || bad "prompt completa"
[ -s "$R/.sdd/hermes/adversarial-FASE-0.json" ] && [ ! -e "$R/.sdd/hermes/adversarial-FASE-0.ronda.json" ] \
  && ok "el plan de la ronda queda como base (.sdd/hermes/adversarial-FASE-0.json)" || bad "sin base: $(ls "$R/.sdd/hermes")"

# 2. modelos: veredictos con el barato del perfil (Haiku en «equilibrado»), la ronda adversarial con el de la etapa
P="$ROOT/plugin/hermes-sdd/hsdd_proyectos.py"
[ "$(python3 "$P" modelo aceptar-veredictos claude)/$(python3 "$P" modelo aceptar claude)" = haiku/sonnet ] \
  && ok "perfil equilibrado: veredictos con haiku, aceptar (la ronda adversarial) con sonnet" || bad "perfil: $(python3 "$P" modelo aceptar-veredictos claude)"
echo '{"perfil_modelos": "calidad"}' > "$HERMES_SDD_HOME/sdd.json"
[ "$(python3 "$P" modelo aceptar-veredictos claude)/$(python3 "$P" modelo aceptar claude)" = sonnet/opus ] \
  && ok "perfil calidad: veredictos con sonnet, aceptar con opus" || bad "calidad: $(python3 "$P" modelo aceptar-veredictos claude)"
rm -f "$HERMES_SDD_HOME/sdd.json"
modelos() { jq -r 'select(.prompt | test("Produce the per-requirement verdicts")) | .modelo' "$FALSO_LOG" | head -1
  jq -r 'select(.prompt | test("--adversarial")) | .modelo' "$FALSO_LOG" | head -1; }
jq '.modelos = {"aceptar-veredictos": "haiku", "aceptar": "opus"}' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
rm -f "$R/.sdd/hermes/adversarial-FASE-0.json"   # que haya ronda que mirar
aceptar
[ "$(modelos | tr '\n' /)" = "haiku/opus/" ] && ok "etapa.sh: veredictos con el modelo de «aceptar-veredictos», la ronda adversarial con el de «aceptar»" || bad "modelos: $(modelos | tr '\n' /)"
jq '.modelos = {"aceptar": "opus"}' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
aceptar
[ "$(modelos | head -1)" = opus ] && ok "un proyecto que fija el modelo de aceptar lo usa también en los veredictos" || bad "fijado: $(modelos | tr '\n' /)"
jq 'del(.modelos)' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
aceptar   # deja la base al día para el caso siguiente

# 3. re-aceptación sin cambios: incremental sin nada que re-verificar → ningún ejecutor adversarial
r=$(jq -c '.rondas_adversariales' "$T/linea")
[ "$(jq -r '.[0].tipo + " " + (.[0].verificados | tostring)' <<< "$r")" = "incremental 0" ] && [ "$(adversariales)" = 0 ] \
  && ok "re-aceptación sin cambios: ronda incremental con 0 criterios, sin lanzar ejecutor" || bad "sin cambios: $r · $(adversariales) llamadas"

# 4. re-aceptación tras cambiar un test que cita un criterio: solo ese criterio, y el prompt lo dice
f=$(cd "$R" && git grep -lE "AC-[0-9]{3}-[0-9]{2}|REQ-F-[0-9]+ AC[0-9]+" -- tests e2e 2>/dev/null | head -1)
l=$(cd "$R" && grep -nE "^\s*(test|it)\(.*(AC-[0-9]{3}-[0-9]{2}|REQ-F-[0-9]+ AC[0-9]+)" "$f" | head -1 | cut -d: -f1)
if [ -n "$f" ] && [ -n "$l" ]; then
  sed -i.bak "$((l + 1))s/^/  \/\/ revisado\n/" "$R/$f" && rm -f "$R/$f.bak"
  git -C "$R" commit -qam "test: comentario" --trailer "Task: TASK-F0-099"
  aceptar
  r=$(jq -c '.rondas_adversariales' "$T/linea")
  n=$(jq -r '.[0].criterios' <<< "$r"); v=$(jq -r '.[0].verificados' <<< "$r")
  [ "$(jq -r '.[0].tipo' <<< "$r")" = incremental ] && [ "$v" -ge 1 ] && [ "$v" -lt "$n" ] && [ "$(adversariales)" = 1 ] \
    && ok "re-aceptación con un test cambiado: incremental, $v de $n criterios" || bad "incremental: $r ($f:$l)"
  jq -r 'select(.prompt | test("--adversarial")) | .prompt' "$FALSO_LOG" | grep -q "INCREMENTAL ROUND.*adversarial-FASE-0.ronda.json" \
    && ok "el prompt incremental señala el plan con recheck" || bad "prompt incremental"
else bad "la práctica no tiene un test que cite un criterio ($f)"; fi

# 5. "ronda_incremental": false → todas completas
jq '.ronda_incremental = false' "$R/.sdd/hermes/hermes-sdd.json" > "$T/c" && cp "$T/c" "$R/.sdd/hermes/hermes-sdd.json"
aceptar
[ "$(jq -r '.rondas_adversariales[0].tipo' "$T/linea")" = completa ] && ok "ronda_incremental: false → ronda completa" || bad "forzar completa: $(cat "$T/linea")"
exit $fail
