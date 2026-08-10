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
            ]
        }
    },
    "missing": ["legandrop/LGA_MediaTools_Release"]
}
```

- La clave de cada producto es el **slug del repo de release**, y tiene que coincidir exacto con
  el `repoSlug` que declara el catalogo de PipeSync.
- La URL de descarga no se guarda porque es derivable
  (`github.com/<repo>/releases/download/<tag>/<asset>`) y guardarla seria un segundo lugar donde
  el mismo dato puede quedar viejo.
- El **`digest`** no es decorativo: la auto-actualizacion de FileManager S3 y de PipeSync
  verifica el SHA-256 de lo que bajo antes de ejecutarlo. Si dejara de venir en el manifiesto,
  esa verificacion se perderia sin que nadie se entere.
- `missing` son los repos que no respondieron: sin releases todavia, privados, o renombrados.
  Estan listados a proposito — un producto que desaparece del manifiesto en silencio es
  indistinguible de uno que nunca estuvo.

## Agregar un producto

Agregar su repo de release a `repos.json` y correr el workflow a mano (pestana **Actions** →
*Refresh versions manifest* → **Run workflow**) para no esperar al cron. Del lado de la app, la
entrada del catalogo tiene que declarar el mismo slug.

## Si el manifiesto deja de actualizarse

**GitHub apaga los workflows programados despues de 60 dias sin actividad en el repo** y le
avisa por mail al owner. Es la falla mas probable de todo esto. Revisar la pestana Actions: si
el cron esta deshabilitado, se reactiva con un click.

El campo `generatedAt` dice cuando fue la ultima corrida que **cambio** algo, no la ultima
corrida: un manifiesto que no cambia hace meses puede estar perfectamente sano si no hubo
releases nuevos.

## Quien lo consume

- **PipeSync** — el card de LGA Updates del Tools tab (`src/services/updates/UpdateProbe.cpp`).
- **FileManager S3** — su auto-actualizacion (`src/services/FM_UpdateService.cpp`).
