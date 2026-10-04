#!/usr/bin/env bash
# Weitergebbares Archiv bauen: dist/bauleiter.tar.gz (Modul ohne .git).
#   bash paket.sh
set -euo pipefail
MODUL=$(cd "$(dirname "$0")" && pwd)

# Nichts Projektspezifisches mitgeben.
if grep -rn -e 'EnteEnteFuchs' -e 'memory/ops_' -e '/mnt/' "$MODUL/vorlage" "$MODUL"/*.md; then
  echo "paket: projektspezifische Stellen (oben) -- neutral formulieren" >&2; exit 1
fi
bash "$MODUL/vorlage/ds/bauleiter-sperre.sh" --test >/dev/null
for f in ds-worker.sh arbeiter-pruef.sh; do bash -n "$MODUL/vorlage/ds/$f"; done
bash -n "$MODUL/installieren.sh"
python3 -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' \
  "$MODUL/vorlage/ds/tokens.py" "$MODUL/vorlage/ds/plan.py"

mkdir -p "$MODUL/dist"
tar czf "$MODUL/dist/bauleiter.tar.gz" -C "$(dirname "$MODUL")" \
  --exclude=.git --exclude=dist --exclude=__pycache__ "$(basename "$MODUL")"
echo "paket: $MODUL/dist/bauleiter.tar.gz ($(du -h "$MODUL/dist/bauleiter.tar.gz" | cut -f1))"
