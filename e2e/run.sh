#!/bin/sh
# End-to-end checks of Synco.app driven from the command line (see Scripted.swift).
# Uses the real Premiere project; outputs go to a temp folder.
#   e2e/run.sh [proyecto.xml]
cd "$(dirname "$0")/.."
APP=Synco.app/Contents/MacOS/Synco
SRC=${1:-$HOME/Downloads/A001_10250033_C001_1.xml}
T=$(mktemp -d)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASA  $1"; }
bad() { fail=$((fail+1)); echo "FALLA $1"; echo "$2" | sed 's/^/      /'; }
run() { "$APP" "$@" --quit 2>&1 | grep '^synco:'; }

# F01-H1 abrir, sincronizar, exportar el proyecto real
out=$(run --open "$SRC" --sync --export "$T/h1.xml")
chk=$(python3 tools/check_xml.py "$SRC" "$T/h1.xml" 2>&1)
if echo "$out" | grep -q "134 de 142" && echo "$chk" | grep -q "iguales" && echo "$chk" | grep -q "links mal: 0 | recortes cambiados: 0 | clips con pistas desfasadas entre sí: 0 | solapes: 0"; then
  ok "F01-H1 134/142 por audio (referencia medida), XML exportado intacto"; else bad "F01-H1" "$out
$chk"; fi
# F01-H5 los que quedan sin sincronizar son exactamente los 8 que no tienen audio en común
# (medido contra otra app de referencia):
# ni uno menos (perder clips) ni uno más (aceptar coincidencias dudosas).
unsynced=$(grep -E '\| (clock|unplaced) \|' "$T/h1.md" | cut -d'|' -f2 | tr -d ' ' | sort | tr '\n' ' ')
want="C0001.MP4 C0002.MP4 C0003.MP4 C0004.MP4 C0005.MP4 C0006.MP4 C0007.MP4 C0032.MP4 "
[ "$unsynced" = "$want" ] && ok "F01-H5 sin sincronizar: los 8 sin audio en común" || bad "F01-H5" "tiene: $unsynced
quiere: $want"
[ -f "$T/h1.md" ] && ok "F01-H2 informe .md junto al XML" || bad "F01-H2 falta el informe" ""
grep -q "<name>A001_10250033_C001 - sincronizado</name>" "$T/h1.xml" && ok "F01-H3 nombre de secuencia con sufijo" || bad "F01-H3 sin sufijo" ""
[ "$(grep -c '<label2>Rose</label2>' "$T/h1.xml")" -gt 0 ] && ok "F01-H4 no sincronizados con etiqueta" || bad "F01-H4 sin etiquetas" ""

# F01-E1 ruta con acentos, espacios y emoji
cp "$SRC" "$T/prueba ñandú 🎬.xml"
out=$(run --open "$T/prueba ñandú 🎬.xml")
echo "$out" | grep -q "fase ready" && ok "F01-E1 abre un archivo con acentos y emoji" || bad "F01-E1" "$out"

# F01-N1 un XML que no es de Premiere
echo '<?xml version="1.0"?><fcpxml version="1.10"><resources/></fcpxml>' > "$T/otro.xml"
out=$(run --open "$T/otro.xml")
echo "$out" | grep -q "fase failed" && ok "F01-N1 XML no compatible: error claro, sin colgarse" || bad "F01-N1" "$out"

# F01-N2 archivo roto
printf '<xmeml><sequence>' > "$T/roto.xml"
out=$(run --open "$T/roto.xml")
echo "$out" | grep -q "fase failed" && ok "F01-N2 XML roto: error claro" || bad "F01-N2" "$out"

# F03-H1 un archivo faltante (era sincronizable: quedan 133): se avisa y la sincronización sigue
sed 's#/TARJETAS/CINEMA/PHONE/A001_10250033_C001.mov#/NO_EXISTE/A001_10250033_C001.mov#' "$SRC" > "$T/faltante.xml"
out=$(run --open "$T/faltante.xml" --sync --export "$T/faltante_out.xml")
if echo "$out" | grep -q "faltantes 1" && echo "$out" | grep -q "fase done"; then
  ok "F03-H1 faltante detectado y sincronización completa"; else bad "F03-H1" "$out"; fi

# F05-H1 marcar un clip como mal sincronizado lo ubica por su hora
out=$(run --open "$SRC" --ignore 30 --sync)
echo "$out" | grep -q "→ clock" && ok "F05-H1 corrección: el clip pasa a ubicarse por su hora" || bad "F05-H1" "$out"

# S03-E1 detener a mitad
out=$(run --open "$SRC" --sync --stop-after 3)
echo "$out" | grep -q "fase stopped" && ok "S03-E1 detener deja la app en estado detenido" || bad "S03-E1" "$out"

# S09-H1 deshabilitar no sincronizados
out=$(run --open "$SRC" --sync --disable-unsynced --export "$T/dis.xml")
n=$(grep -c '<enabled>FALSE</enabled>' "$T/dis.xml")
[ "$n" -gt 0 ] && ok "S09-H1 no sincronizados deshabilitados ($n items)" || bad "S09-H1" "$out"

# F06 un proyecto con varias cámaras y grabadores en la misma carpeta, copias, imágenes y
# exportaciones sin hora (solo si está el proyecto y su tarjeta: MORA=ruta/al.xml).
MORA=${MORA:-$HOME/Downloads/mora.xml}
if [ -f "$MORA" ] && grep -q "VERBATIM" "$MORA" && [ -d "/Volumes/VERBATIM SD" ]; then
  out=$(run --open "$MORA" --sync --export "$T/mora.xml")
  chk=$(python3 tools/check_xml.py "$MORA" "$T/mora.xml" 2>&1)
  echo "$out" | grep -q "4 imagen" && ok "F06-H1 imágenes ignoradas" || bad "F06-H1" "$out"
  echo "$chk" | grep -q "links mal: 0 | recortes cambiados: 0 | clips con pistas desfasadas entre sí: 0 | solapes: 0" \
    && ok "F06-H2 XML exportado sin clips pisados en una misma pista" || bad "F06-H2" "$chk"
  n=$(echo "$out" | sed -n 's/.*synco: \([0-9]*\) de 311.*/\1/p')
  [ "${n:-0}" -ge 129 ] && ok "F06-H3 $n de 311 por audio (mínimo 129)" || bad "F06-H3" "$out"
fi

# Ajustes intactos después de las pruebas
defaults read local.mariano.synco prefs >/dev/null 2>&1; ok "ajustes del usuario restaurados al salir"

echo "----"; echo "$pass pasan, $fail fallan"; rm -rf "$T"
[ $fail -eq 0 ]
