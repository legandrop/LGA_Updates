# LGA Updates

Manifiesto de versiones de las apps y tools de LGA. Este repo **no tiene codigo de producto**:
solo un JSON con la ultima version publicada de cada uno, y el workflow que lo mantiene.

**URL que consumen las apps:**

```
https://legandrop.github.io/LGA_Updates/versions.json
```

## Para que existe

El card de LGA Updates de PipeSync le preguntaba a la API de GitHub, una consulta por producto,
en cada arranque de la app. Sin token esa API permite **60 requests por hora y por IP**: un
estudio entero detras de un mismo NAT se quedaba sin cuota en el primer minuto de la manana, y
las filas quedaban en rojo con un error que el usuario no podia resolver.

Ahora la consulta a la API la hace **una** maquina autenticada —el workflow de este repo— y las
apps leen un archivo estatico servido por GitHub Pages, que no tiene limite de requests. De paso
las apps pasaron de ~9 requests por arranque a **1**.

## Como funciona

1. `repos.json` lista los repos de RELEASE de cada producto.
2. `build_manifest.sh` le pregunta a cada uno cual es su ultimo release y arma `versions.json`.
3. `.github/workflows/refresh_versions.yml` lo corre cada 30 minutos y commitea **solo si
   alguna version cambio**.
4. GitHub Pages sirve `versions.json` desde la raiz de `main`.

## Formato de `versions.json`

```json
{
    "schemaVersion": 1,
    "checkedAt": "2026-08-10T18:00:00Z",
    "generatedAt": "2026-08-10T18:00:00Z",
    "products": {
        "legandrop/LGA_ToolPack-for_Nuke": {
            "tag": "v2.60",
            "publishedAt": "2026-07-01T12:00:00Z",
            "assets": [
                {
                    "name": "LGA_ToolPack_v2.60.zip",
                    "digest": "sha256:4d9a6e78...",
                    "size": 26310201
                }
            ],
            "assetLatest": [
                {
                    "tag": "v2.60",
                    "publishedAt": "2026-07-01T12:00:00Z",
                    "name": "LGA_ToolPack_v2.60.zip",
                    "digest": "sha256:4d9a6e78...",
                    "size": 26310201
                }
            ]
        }
    },
    "missing": ["legandrop/LGA_MediaTools_Release"]
}
```

- **`checkedAt` es el LATIDO**: cuando corrio el workflow, cambie o no algo. Se refresca al menos
  una vez por dia. **`generatedAt` es otra cosa**: cuando cambio por ultima vez alguna version, y
  se preserva mientras nada se mueva. Los dos hacen falta: sin `checkedAt`, "hace 30 dias que no
  sacas un release" (sano) y "hace 30 dias que esto no corre" (roto) son indistinguibles, y es
  exactamente lo que las apps miran para avisar.
- La clave de cada producto es el **slug del repo de release**, y tiene que coincidir exacto con
  el `repoSlug` que declara el catalogo de PipeSync.
- **`assetLatest` es el asset mas nuevo de CADA familia de artefacto**, y no siempre sale del
  release de `tag`. Existe porque `releases/latest` puede no traer artefacto para todas las
  plataformas: el Shot Player publico v0.065, v0.090 y v0.093 solo para Windows, asi que un
  usuario de macOS quedaba ciego a la v0.055 —que si es suya— y su updater le decia que no habia
  instalable. Lo que corresponde ver en cada plataforma es la ultima version **que existe para
  ella**, sin importar si otra plataforma va mas adelante.
  El manifiesto no sabe que es "Windows" o "macOS": agrupa por el nombre del asset con la version
  borrada y se queda con el mas nuevo de cada grupo. Quien elige cual le toca es cada app, con el
  patron de asset que ya tiene. Se mira dentro de los ultimos 100 releases del repo.
- La URL de descarga no se guarda porque es derivable
  (`github.com/<repo>/releases/download/<tag>/<asset>`) y guardarla seria un segundo lugar donde
  el mismo dato puede quedar viejo.
- El **`digest`** no es decorativo: la auto-actualizacion de FileManager S3 y de PipeSync
  verifica el SHA-256 de lo que bajo antes de ejecutarlo. Si dejara de venir en el manifiesto,
  esa verificacion se perderia sin que nadie se entere.
- `missing` son los repos **sin release alcanzable de forma permanente**: sin releases todavia,
  privados, o renombrados. Estan listados a proposito — un producto que desaparece del
  manifiesto en silencio es indistinguible de uno que nunca estuvo.
- Un repo que falla por algo **transitorio** (un 5xx, un corte de red) NO va a `missing`: se
  conserva su entrada del manifiesto anterior y el proximo ciclo del cron la corrige. El
  criterio es el status HTTP: 404 es permanente, todo lo demas se reintenta. Sin esto, un hipo
  de la API publicaba un manifiesto sin ese producto y las apps lo mostraban como "sin version
  remota", que es falso y encima pisaba el dato bueno.
- `schemaVersion` es el contrato con las apps. **Subirlo rompe a las versiones ya instaladas a
  proposito**: cada consumidor lo valida y prefiere no leer nada antes que malinterpretar
  campos que cambiaron de significado. Agregar campos nuevos no requiere subirlo.

## Cuando se publica una version nueva

**Los instaladores disparan el refresco solos.** Al terminar de publicar un release, cada uno
corre:

```
gh workflow run refresh_versions.yml --repo legandrop/LGA_Updates
```

Sin eso habria que esperar al cron —hasta 30 minutos— para que el card de PipeSync vea la version
nueva. Falla en silencio a proposito: si el disparo no sale, la release ya esta publicada igual y
el cron la levanta sola.

Lo hacen los siete puntos que publican: `instalador.bat` de PipeSync, FileManager S3, Media Tools
y el Shot Player; y del lado de macOS `github_release_mac.sh` de PipeSync y FileManager S3, mas
`deploy_player.sh` del Shot Player.

**Las tools de Nuke (ToolPack, NodePack, HieroTools, OpenInNukeX) todavia NO lo hacen**: se
publican desde `../LGA_Release`, que no se toco. Para esas hay que esperar al cron o correr el
workflow a mano.

Despues del disparo, el manifiesto tarda ~1 minuto en estar servido: lo que corre el workflow
(~15 s) mas la publicacion de Pages. **El `Cache-Control: max-age=600` de Pages no agrega
demora**, porque Pages purga su cache al publicar.

## Agregar un producto

Agregar su repo de release a `repos.json` y correr el workflow a mano (pestana **Actions** →
*Refresh versions manifest* → **Run workflow**) para no esperar al cron. Del lado de la app, la
entrada del catalogo tiene que declarar el mismo slug.

## Si el manifiesto deja de actualizarse

**PipeSync avisa solo.** Si el `checkedAt` publicado tiene mas de 30 dias, el card de LGA Updates
lo dice —al usuario con rol Master, que es el unico que puede arreglarlo— y ademas muestra un
aviso al arrancar, una vez por dia. No hace falta acordarse de mirar nada.

Ese aviso NO cubre solo el cron apagado: si el workflow se rompe por cualquier otra cosa (un
error del script, `gh` sin permisos, Pages caido), el latido tambien se corta y se detecta igual.

La causa mas probable sigue siendo que **GitHub apaga los workflows programados despues de 60
dias sin actividad en el repo**, avisando por mail al owner. Revisar la pestana Actions: si el
cron esta deshabilitado, se reactiva con un click.

**No confiar en el latido diario para evitar ese corte.** Los commits pusheados con el
`GITHUB_TOKEN` de Actions se reportan ampliamente como NO contabilizados para el contador de
inactividad —por eso quien busca ese efecto usa un PAT—, y no esta verificado. Lo que si funciona
es la deteccion: el aviso de la app salta igual, sin importar por que se corto el latido.

Al diagnosticar, mirar **`checkedAt`** y no `generatedAt`: el segundo es cuando cambio alguna
version por ultima vez, asi que un manifiesto que no cambia hace meses puede estar sano si no
hubo releases nuevos.

## Quien lo consume

- **PipeSync** — el card de LGA Updates del Tools tab (`src/services/updates/UpdateProbe.cpp`).
- **FileManager S3** — su auto-actualizacion (`src/services/FM_UpdateService.cpp`).
