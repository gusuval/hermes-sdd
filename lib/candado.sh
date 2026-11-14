# Candado del repo (se carga con «source»): nunca dos etapas, ni una etapa y una firma, a la vez en el mismo proyecto.
#
#   <repo>/.sdd/hermes/lock/   pid (dueño) · quien (etapa | firma | ejecutor) · run (lo que hace) · desde (epoch)
#
# Lo toma etapa.sh para TODA la etapa (antes se tomaba por cada ejecución de Claude y, entre una y otra, otra etapa
# podía colarse) y firmar.sh mientras firma. Los ejecutores (executors/claude.sh, hermes.sh) lo reutilizan si su dueño
# es la etapa que los lanzó (SDD_CANDADO_PID); a mano, lo toman ellos. vigilar.sh y el encargado lo respetan.
# Robar un candado huérfano (su dueño murió) se hace con un segundo mkdir como exclusión: antes, «rm -rf; mkdir» dejaba
# que dos procesos lo robaran a la vez.
#
#   candado_tomar <repo> <quien> <run>   0: tomado (o reutilizado) · 1: ocupado (deja el dueño en CANDADO_OTRO)
#   candado_soltar                       lo suelta solo si es nuestro (no si se reutilizó el de la etapa)
#   candado_vivo <repo>                  0 si alguien vivo lo tiene (deja su «quien» en CANDADO_QUIEN)

CANDADO_DIR=""; CANDADO_PROPIO=false; CANDADO_OTRO=""; CANDADO_QUIEN=""

_candado_pid_vivo() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
_candado_edad() {  # segundos desde que se creó el directorio $1
  local m; m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

candado_vivo() {
  local l="$1/.sdd/hermes/lock" pid
  [ -d "$l" ] || return 1
  pid=$(cat "$l/pid" 2>/dev/null || true)
  CANDADO_QUIEN=$(cat "$l/quien" 2>/dev/null || echo etapa)
  if [ -z "$pid" ]; then [ "$(_candado_edad "$l")" -lt 60 ]; return; fi   # recién creado: aún escribe su pid
  _candado_pid_vivo "$pid"
}

candado_tomar() {
  local repo=$1 quien=$2 run=${3:-} l="$1/.sdd/hermes/lock" pid
  mkdir -p "$repo/.sdd/hermes"
  CANDADO_DIR=$l; CANDADO_PROPIO=false; CANDADO_OTRO=""
  # Lo tiene la etapa que nos lanzó: se usa el suyo
  pid=$(cat "$l/pid" 2>/dev/null || true)
  if [ -n "${SDD_CANDADO_PID:-}" ] && [ "$pid" = "$SDD_CANDADO_PID" ] && _candado_pid_vivo "$pid"; then
    [ -n "$run" ] && echo "$run" > "$l/run"
    return 0
  fi
  if ! mkdir "$l" 2>/dev/null; then
    if candado_vivo "$repo"; then
      CANDADO_OTRO="$(cat "$l/quien" 2>/dev/null || echo etapa) $(cat "$l/run" 2>/dev/null), pid $(cat "$l/pid" 2>/dev/null)"
      return 1
    fi
    # Huérfano: lo roba quien consiga crear «lock.robo» (uno solo); el resto, ocupado
    [ -d "$l.robo" ] && [ "$(_candado_edad "$l.robo")" -gt 60 ] && rmdir "$l.robo" 2>/dev/null
    mkdir "$l.robo" 2>/dev/null || { CANDADO_OTRO="otro proceso está recuperando el candado"; return 1; }
    if candado_vivo "$repo"; then rmdir "$l.robo"; CANDADO_OTRO="$(cat "$l/run" 2>/dev/null)"; return 1; fi
    rm -rf "$l"
    if ! mkdir "$l" 2>/dev/null; then rmdir "$l.robo"; CANDADO_OTRO="otro proceso lo tomó"; return 1; fi
    rmdir "$l.robo"
  fi
  echo $$ > "$l/pid"; echo "$quien" > "$l/quien"; echo "$run" > "$l/run"; date +%s > "$l/desde"
  CANDADO_PROPIO=true
  return 0
}

candado_soltar() {
  [ "$CANDADO_PROPIO" = true ] && [ -n "$CANDADO_DIR" ] || return 0
  [ "$(cat "$CANDADO_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$CANDADO_DIR"
  CANDADO_PROPIO=false
  return 0
}
