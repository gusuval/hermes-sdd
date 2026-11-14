#!/usr/bin/env bash
# Canal LOCAL (plan B y pruebas): registra la decisión de una persona sentada en esta máquina y llama al notario.
#
#   decidir.sh <puerta> <verbo> [texto]      p. ej.  decidir.sh t_6c9eaff4 acepto
#
# La identidad es la del usuario del sistema ($USER), que debe figurar en aprobadores.json como canal "local".
# Queda registrado que la decisión no llegó por Telegram. La decisión pasa por el núcleo, como la de cualquier canal
# (hsdd_nucleo.py decidir: puerta abierta, un verbo que la puerta ofrece, su motivo si lo pide, con el cerrojo del
# índice), y el estado de la puerta solo cambia por sus transiciones (hsdd_nucleo.py transicion).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HOME_SDD="${HERMES_SDD_HOME:-$HOME/.hermes/hermes-sdd}"
GATE=$1; VERBO=$2; TEXTO=${3:-}
NUCLEO=(env HERMES_SDD_HOME="$HOME_SDD" python3 "$ROOT/plugin/hermes-sdd/hsdd_nucleo.py")
IDX="$HOME_SDD/puertas/$GATE.json"
[ -f "$IDX" ] || { echo "No conozco la puerta $GATE" >&2; exit 2; }
REPO=$(jq -r .repo "$IDX")
"${NUCLEO[@]}" decidir "$GATE" "$VERBO" "$TEXTO" local "$USER" "$(jq -nc --arg h "$(hostname -s)" '{host:$h}')" >/dev/null || exit 2
# El notario firma ahora (el gateway no firma el canal local). Si una etapa u otra firma tiene el repo (sale 75), espera.
avisado=false; rc=0
for _ in $(seq 1 720); do
  rc=0; OUT=$(bash "$ROOT/firmar.sh" "$REPO" "$GATE") || rc=$?
  [ "$rc" = 75 ] || break
  $avisado || { echo "El repo está ocupado (una etapa o una firma en marcha): espero para firmar…" >&2; avisado=true; }
  sleep "${HERMES_SDD_ESPERA_FIRMA_S:-5}"
done
if [ "$rc" = 0 ]; then
  printf '%s\n' "$OUT"
  "${NUCLEO[@]}" transicion "$GATE" firmada resultado="$(printf '%s\n' "$OUT" | tail -1)"
else
  "${NUCLEO[@]}" transicion "$GATE" error error="el notario rechazó la decisión local" || true
  exit "$rc"
fi
