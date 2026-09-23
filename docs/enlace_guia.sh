#!/usr/bin/env bash
#
# ¿EL ENLACE A LA GUÍA DE PUERTAS APUNTA A ALGO QUE EXISTE?
#
# Un enlace roto a la guía de puertas sería el chiste final: el documento que
# dice «una puerta verde afirma dos cosas» colgando de un 404 que nadie
# comprueba.
#
# QUÉ HACE, y en este orden:
#   1. busca el enlace a `docs/puertas-y-alcance.md` en los .md de este repo;
#   2. resuelve el fichero en el clon de `proyectos` que haya al lado —el del
#      PIN si el repo lo clona por pin, que es lo que lo hace verificable
#      desde fuera y no sólo legible—;
#   3. si no hay clon, lo trae con `--depth 1` (proyectos es PÚBLICO: 2 s).
#
# CÓDIGOS, la convención de siempre:
#   0  hay enlace Y el documento existe en el pin
#   1  no hay enlace, o lo hay y apunta a algo que no está
#   2  no se ha podido comprobar (sin red y sin clon al lado)
#
# Y publica su ALCANCE —cuántos .md ha mirado, cuántos enlaces ha encontrado—
# porque esta guardia se rige por el documento que vigila.
#
#   bash docs/enlace_guia.sh          # desde la raíz del repo
set -u
DOC="docs/puertas-y-alcance.md"
RAIZ="${1:-.}"
cd "$RAIZ" || exit 2

# ── 1 · el alcance: qué .md se han mirado ────────────────────────────────
mds=$(ls -1 *.md 2>/dev/null | wc -l)
enlaces=$(grep -l "puertas-y-alcance" *.md 2>/dev/null | tr '\n' ' ')
n_enl=$(echo "$enlaces" | wc -w)
echo "alcance: $mds ficheros .md mirados · $n_enl con enlace a la guía${enlaces:+ ($enlaces)}"

if [ "$n_enl" = "0" ]; then
  echo "ROJO · ningún .md de este repo enlaza la guía de puertas."
  echo "       Añade una línea a TRASPASO.md o README.md apuntando a"
  echo "       proyectos/$DOC — un solo original, enlaces desde cada repo."
  exit 1
fi

# ── 2 · el original, en el clon del pin si lo hay ────────────────────────
for c in ../proyectos ../Proyectos; do
  if [ -f "$c/$DOC" ]; then
    echo "el documento existe en $c/$DOC   (clon al lado, el del pin si el repo lo fija)"
    exit 0
  fi
  if [ -d "$c" ]; then
    echo "ROJO · hay un clon en $c y NO trae $DOC"
    echo "       o el documento se ha movido, o el pin apunta a un commit anterior a él."
    exit 1
  fi
done

# ── 3 · sin clon al lado: se trae, y si no se puede, rc = 2 ──────────────
tmp=$(mktemp -d)
if git clone --depth 1 -q https://github.com/IMoriana3/proyectos.git "$tmp/p" 2>/dev/null; then
  if [ -f "$tmp/p/$DOC" ]; then
    echo "el documento existe en proyectos (clonado al vuelo)"
    rm -rf "$tmp"; exit 0
  fi
  echo "ROJO · proyectos NO trae $DOC: el enlace de este repo está roto."
  rm -rf "$tmp"; exit 1
fi
rm -rf "$tmp"
echo "SIN COMPROBAR: no hay clon de proyectos al lado y no se ha podido clonar."
echo "El enlace puede estar bien o roto. Esto NO es un verde."
exit 2
