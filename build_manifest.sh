#!/usr/bin/env bash
#
# Genera versions.json preguntandole a cada repo de release cual es su ultimo release.
#
# Corre DENTRO de GitHub Actions, que es el punto de todo esto: la consulta a la API de
# GitHub la hace una maquina autenticada y no las 20 instalaciones de PipeSync. Sin token
# el limite de la API es de 60 requests por hora Y POR IP, o sea que un estudio entero
# detras de un NAT lo agotaba en el primer minuto de la manana.
#
# Se puede correr a mano para probar, con `GH_TOKEN=$(gh auth token) ./build_manifest.sh`.

set -euo pipefail

REPOS_FILE="repos.json"
OUT_FILE="versions.json"

if [[ ! -f "$REPOS_FILE" ]]; then
    echo "ERROR: no se encontro $REPOS_FILE" >&2
    exit 1
fi

mapfile -t REPOS < <(jq -r '.repos[]' "$REPOS_FILE")

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "ERROR: $REPOS_FILE no declara ningun repo" >&2
    exit 1
fi

products="{}"
missing="[]"
failed=0

for repo in "${REPOS[@]}"; do
    echo "Consultando $repo ..."

    # `|| true` para NO cortar el build por un repo: un 404 —repo sin releases todavia, o
    # privado y fuera del alcance del token— tiene que dejar pasar a los demas. Un repo que
    # falla queda listado en `missing` y el consumidor lo muestra como "sin version remota",
    # que es exactamente lo que pasa.
    release_json="$(gh api "repos/${repo}/releases/latest" 2>/dev/null || true)"

    if [[ -z "$release_json" ]] || ! jq -e '.tag_name' <<<"$release_json" >/dev/null 2>&1; then
        echo "  sin release accesible"
        missing="$(jq --arg repo "$repo" '. + [$repo]' <<<"$missing")"
        failed=$((failed + 1))
        continue
    fi

    tag="$(jq -r '.tag_name' <<<"$release_json")"
    published="$(jq -r '.published_at // ""' <<<"$release_json")"
    # Solo los NOMBRES de los assets. La URL de descarga no se guarda porque es derivable
    # (github.com/<repo>/releases/download/<tag>/<asset>) y guardarla seria un segundo lugar
    # donde el mismo dato puede quedar viejo.
    assets="$(jq -c '[.assets[]?.name]' <<<"$release_json")"

    echo "  $tag ($(jq -r 'length' <<<"$assets") assets)"

    products="$(jq \
        --arg repo "$repo" \
        --arg tag "$tag" \
        --arg published "$published" \
        --argjson assets "$assets" \
        '.[$repo] = {tag: $tag, publishedAt: $published, assets: $assets}' \
        <<<"$products")"
done

# Si NINGUN repo respondio, algo esta roto de verdad (token, red, la API caida) y publicar un
# manifiesto vacio dejaria a todas las filas del card sin version remota. Mejor fallar y que
# quede el manifiesto anterior, que aunque este viejo sigue siendo util.
if [[ $failed -eq ${#REPOS[@]} ]]; then
    echo "ERROR: ningun repo respondio. No se reescribe $OUT_FILE." >&2
    exit 1
fi

jq -n \
    --argjson products "$products" \
    --argjson missing "$missing" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
        schemaVersion: 1,
        generatedAt: $generated,
        products: $products,
        missing: $missing
    }' > "$OUT_FILE"

echo "Listo: $OUT_FILE con $(jq '.products | length' "$OUT_FILE") productos y $(jq '.missing | length' "$OUT_FILE") sin release."
