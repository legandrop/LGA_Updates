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
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

if [[ ! -f "$REPOS_FILE" ]]; then
    echo "ERROR: no se encontro $REPOS_FILE" >&2
    exit 1
fi

mapfile -t REPOS < <(jq -r '.repos[]' "$REPOS_FILE")

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "ERROR: $REPOS_FILE no declara ningun repo" >&2
    exit 1
fi

# El manifiesto ANTERIOR, si existe. Se usa para no perder una entrada buena cuando un repo
# falla por algo transitorio (un 5xx, un corte de red, un rate limit). Sin esto, un hipo de la
# API en una sola corrida publicaba un manifiesto sin ese producto, y el consumidor lo mostraba
# como "sin version remota" — un diagnostico falso, y encima pisando el dato bueno anterior.
previous="{}"
if [[ -f "$OUT_FILE" ]]; then
    previous="$(jq -c '.products // {}' "$OUT_FILE" 2>/dev/null || echo '{}')"
fi

products="{}"
missing="[]"
failed=0

for repo in "${REPOS[@]}"; do
    echo "Consultando $repo ..."

    # El stderr de `gh` NO se descarta: es lo unico que dice POR QUE fallo, y sin eso el log de
    # esta corrida no sirve para diagnosticar nada. `set +e` alrededor porque el script corre con
    # `set -e` y un repo que falla no tiene que cortar a los demas.
    set +e
    release_json="$(gh api "repos/${repo}/releases/latest" 2>"$ERR_FILE")"
    set -e
    gh_error="$(tr -d '\r' < "$ERR_FILE" | head -3 | tr '\n' ' ')"

    if [[ -z "$release_json" ]] || ! jq -e '.tag_name' <<<"$release_json" >/dev/null 2>&1; then
        failed=$((failed + 1))

        # 404 es PERMANENTE y esperado: el repo no tiene releases todavia, o es privado y esta
        # fuera del alcance del token. Cualquier otra cosa (5xx, rate limit, corte de red) es
        # transitoria, y ahi se conserva la entrada del manifiesto anterior: un release viejo es
        # mucho mas util que ninguno, y el proximo ciclo del cron lo corrige solo. Sin esta
        # distincion, un hipo de la API publicaba un manifiesto sin ese producto y las apps lo
        # mostraban como "todavia no tiene releases", que es un diagnostico falso.
        if [[ "$gh_error" != *"HTTP 404"* ]] \
            && jq -e --arg repo "$repo" '.[$repo]' <<<"$previous" >/dev/null 2>&1; then
            echo "  fallo transitorio, se conserva la entrada anterior — $gh_error"
            products="$(jq --arg repo "$repo" --argjson prev "$previous" \
                '.[$repo] = $prev[$repo]' <<<"$products")"
            continue
        fi

        echo "  sin release accesible — ${gh_error:-sin detalle}"
        missing="$(jq --arg repo "$repo" '. + [$repo]' <<<"$missing")"
        continue
    fi

    tag="$(jq -r '.tag_name' <<<"$release_json")"
    published="$(jq -r '.published_at // ""' <<<"$release_json")"

    # Nombre, digest y tamano de cada asset.
    #
    # La URL de descarga NO se guarda: es derivable
    # (github.com/<repo>/releases/download/<tag>/<asset>) y guardarla seria un segundo lugar
    # donde el mismo dato puede quedar viejo.
    #
    # El `digest` SI, y no es opcional: la auto-actualizacion de FileManager S3 y PipeSync
    # verifica el SHA-256 de lo que bajo antes de ejecutarlo. Sin este campo esa verificacion
    # se perderia en silencio, que es exactamente el tipo de proteccion que no se puede perder
    # sin que nadie se entere.
    assets="$(jq -c '[.assets[]? | {name: .name, digest: (.digest // ""), size: (.size // 0)}]' <<<"$release_json")"

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

# `generatedAt` es cuando cambio el CONTENIDO por ultima vez, asi que se preserva del manifiesto
# anterior mientras ninguna version se mueva. Si se pisara en cada corrida, seria indistinguible
# de `checkedAt` y no habria forma de saber hace cuanto que no sale una version nueva.
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
generated="$now"
if [[ -f "$OUT_FILE" ]]; then
    prev_generated="$(jq -r '.generatedAt // ""' "$OUT_FILE" 2>/dev/null || echo "")"
    prev_content="$(jq -S -c '{products, missing}' "$OUT_FILE" 2>/dev/null || echo '{}')"
    new_content="$(jq -S -c -n --argjson p "$products" --argjson m "$missing" \
        '{products: $p, missing: $m}')"
    if [[ -n "$prev_generated" && "$prev_content" == "$new_content" ]]; then
        generated="$prev_generated"
    fi
fi

# `checkedAt` es el LATIDO: cuando corrio el workflow, cambie o no algo. Es lo unico que permite
# distinguir "hace 30 dias que no sacas un release" (sano) de "hace 30 dias que esto no corre"
# (roto), y las apps avisan cuando se enfria. El workflow lo publica al menos una vez por dia
# aunque no haya novedades — ver el step de commit.
jq -n \
    --argjson products "$products" \
    --argjson missing "$missing" \
    --arg generated "$generated" \
    --arg checked "$now" \
    '{
        schemaVersion: 1,
        checkedAt: $checked,
        generatedAt: $generated,
        products: $products,
        missing: $missing
    }' > "$OUT_FILE"

echo "Listo: $OUT_FILE con $(jq '.products | length' "$OUT_FILE") productos y $(jq '.missing | length' "$OUT_FILE") sin release."
