# Petdex — verificación del contrato (Companion Fase B, Bloque 2)

**Fecha de verificación**: 2026-06-25
**Método**: sondeo HTTP de solo lectura (`curl -I`, `curl`, inspección de HTML/JSON
y de un ZIP descargado a un scratchpad temporal). **Sin** `npx`, sin CLI de
Petdex, sin ejecutar scripts, sin descargar nada al almacenamiento de la app.

## Resumen ejecutivo

- **URL canónica verificada**: `https://petdex.dev` (HTTP 200).
  - `https://petdex.crafter.run` → **308** redirect a `https://petdex.dev`.
  - En consecuencia `kPetdexUrlVerified` pasa a `true` y el enlace externo
    "Ver Petdex" queda habilitado (abre el navegador externo).
- **NO existe API pública de listado/búsqueda en JSON.** Todos los endpoints
  probados (`/api/pets`, `/api/companions`, `/api/v1/pets`, `/api/search`,
  `/api/registry`, `/pets.json`, `/api/trpc/pets.list`, …) devuelven **404**.
  El catálogo solo está disponible *server-rendered* dentro del HTML (payload
  RSC de Next.js) → obtenerlo programáticamente sería **scraping frágil** y sin
  versionar.
- **La instalación directa in-app NO es segura** con el contrato actual (ver
  "Por qué no se puede instalar").

## Infraestructura observada (de la CSP de petdex.dev)

| Recurso | Host |
|---|---|
| App / SSR | `petdex.dev` (Next.js sobre Cloudflare) |
| Assets / media | `assets.petdex.dev` (Cloudflare R2) |
| Auth (solo publicar) | `clerk.petdex.dev` (Clerk) |

## Layout de assets (HTTPS directo, público, con ETag)

- **Curated** (mascotas destacadas):
  - `https://assets.petdex.dev/curated/<slug>/pet.json` → 200 `application/json`
  - `https://assets.petdex.dev/curated/<slug>/spritesheet.webp` → 200 `image/webp`
  - (no hay `zip.zip` para curated)
  - Slugs reales observados: `boba`, `noir-webling`.
- **User pets** (subidas por usuarios):
  - `https://assets.petdex.dev/pets/<id-hash>/sprite.webp` → 200 `image/webp`
  - `https://assets.petdex.dev/pets/<id-hash>/zip.zip` → 200 (`pet.json` + `spritesheet.webp`)
  - `https://assets.petdex.dev/pets/<id-hash>/preview.webp`
  - IDs reales observados: `2-fortnight-afb6630b6fa3`, `11-8115f64f9fbf`.

El `zip.zip` descargado para inspección contenía exactamente:

```
pet.json            243 bytes
spritesheet.webp    ~1.77 MB   (RIFF…WEBP VP8L — WebP lossless válido)
```

## Esquema real de `pet.json` (curated y user — idéntico)

```json
{
  "id": "2-fortnight",
  "displayName": "2-Fortnight",
  "description": "…",
  "spritesheetPath": "spritesheet.webp"
}
```

### Campos que NO trae el `pet.json` de Petdex

- `frameWidth`, `frameHeight`, `cols`, `rows`, `fps` (geometría de la rejilla).
- `states` (mapa idle/run/waiting/wave/failed/jump → fila/frames/loop).
- `author`, `license`.

Esa geometría (`width`, `height`, `states`, `frames`) **solo aparece en el RSC
del HTML** de cada página de mascota, no en ningún manifiesto estable.

## Por qué NO se puede instalar de forma segura (Bloques 3 y 4 saltados)

El modelo `Companion` de Fase A **requiere** `frameWidth`, `frameHeight`, `cols`,
`rows`, `fps` y el mapa `states{}` para poder cortar el spritesheet y animarlo,
y las reglas de seguridad de instalación exigen `author`/`license`/`slug`
válidos. El contrato de Petdex:

1. **Incumple el schema** del Companion (faltan geometría y `states`).
2. **Carece de `author`/`license`** en los assets.
3. **No ofrece API de listado** → el catálogo solo se obtendría por scraping
   frágil del RSC de Next.js (se rompe en cualquier deploy).

Por las reglas duras del sprint ("no instalar si el JSON no cumple schema", "no
instalar si falta licencia/autor", "no usar scraping frágil"), **no se
implementa**:

- **Bloque 3** (galería con listado en vivo): dependería de scraping frágil.
- **Bloque 4** (instalación directa desde Petdex): geometría y licencia ausentes.

## Qué SÍ se implementa

- **Enlace externo "Ver Petdex"** (US5) habilitado con la URL verificada. Abre el
  navegador del sistema; no descarga nada.
- **Importación LOCAL de un ZIP descargado de Petdex.** Aunque el `pet.json` de
  Petdex es mínimo, su spritesheet sigue el **estándar de rejilla de Fase A**
  (frame 192×208; los dos samples reales — `noir-webling` y `2-fortnight` — miden
  1536×1872 = 8×9). Por eso `CompanionImportService` incluye un **adaptador**: si
  el `pet.json` no trae `grid`/`states`, sintetiza el manifiesto Fase A completo
  infiriendo `cols = ancho/192`, `rows = alto/208` (leídos de la cabecera WebP/PNG,
  sin decodificar) y aplicando el mapa de estados estándar
  (idle/run/waiting/wave/failed). `author`="Petdex", `license`="unknown (Petdex)".
  Si las dimensiones no son múltiplo de 192×208, se rechaza con un aviso claro.
  Así el usuario puede descargar una mascota de petdex.dev e importarla **localmente**
  (sin que la app haga red ni instale por API).

## Dialecto ZIP admitido por la importación local

El importador acotado (`BoundedCompanionZip`) acepta **solo** ZIP32 de un único
disco, **sin cifrar**, con entradas **STORE (0) o DEFLATE (8)**, nombres UTF-8 y
data descriptors opcionales. El `zip.zip` real de Petdex (`pet.json` +
`spritesheet.webp`) cumple este dialecto. Se rechazan deliberadamente, sin
inflar ningún dato: cifrado (tradicional/fuerte), ZIP64, varios discos/volúmenes
y cualquier otro códec (bzip2, LZMA, zstd…). Límites: 12 MiB, 256 entradas.

La UI de Mascotas distingue estos casos (`UnsupportedCompanionZipException` →
`CompanionImportException.unsupportedZipFormat`) y muestra el aviso localizado
`petImportUnsupportedZip` (es/en) con la acción: volver a descargar el ZIP de
Petdex o recrearlo sin contraseña y con compresión estándar. Un ZIP corrupto o
malformado sigue mostrando el error genérico. Alcance: fuente/tests; sin
afirmación de ejecución en dispositivo Android.

## Reevaluación futura (Fase C, solo si Petdex publica contrato estable)

Para habilitar instalación in-app de forma segura, Petdex necesitaría exponer un
manifiesto **estable y versionado** por mascota que incluya, además del
spritesheet: geometría de rejilla (`frameWidth/frameHeight/cols/rows/fps`), el
mapa de `states`, y `author`/`license`. Mientras eso no exista como API pública
documentada, la instalación directa queda fuera de alcance.

La vía segura y bajo control del usuario para obtener mascotas nuevas es la
**importación local** (un ZIP con un `pet.json` que cumpla el schema completo de
Fase A), validado estrictamente y sin red — ver Bloque 5.

## Re-verificación 2026-06-26 (sondeo read-only con `curl`)

Re-sondeo nocturno (modo desatendido, feature 006) para confirmar de nuevo si
Petdex publica ya un contrato seguro para galería/instalación in-app.
**Resultado: SIN cambios — sigue sin contrato seguro.**

- API JSON de listado: **sigue inexistente**. `https://petdex.dev/api/pets`,
  `/pets.json`, `/api/v1/pets` → todos `404`.
- `pet.json` curado (`assets.petdex.dev/curated/boba/pet.json`) → `200` pero
  **sigue mínimo**: solo `id`, `displayName`, `description`, `spritesheetPath`.
  **Sin** `frameWidth/frameHeight/cols/rows/fps`, **sin** `states`, **sin**
  `author`/`license`.

**Conclusión:** condición del árbol de decisión (Fase 4) **NO cumplida**. Galería
remota e instalación por slug permanecen **FUERA de alcance**. Se mantienen las
dos vías seguras: **enlace externo** ("Ver Petdex") e **importación local** del
ZIP descargado por el usuario. En esta pasada se mejoró además el **microcopy de
la pantalla Mascotas** para dejar explícito el flujo "descarga el ZIP en el
navegador → vuelve e impórtalo; la app no descarga ni instala por sí misma".
Reconsiderar solo si Petdex publica el manifiesto estable+versionado descrito
en "Reevaluación futura".

## Re-verificación 2026-06-25 (sondeo read-only con `curl`)

Re-sondeo para confirmar si Petdex publica ya un contrato que permita una galería
in-app. **Resultado: sigue SIN contrato seguro para galería/instalación remota.**

- `https://petdex.dev/` → `200`; `https://petdex.crafter.run/` → `308` → petdex.dev.
- API JSON de listado: **inexistente**. `/api/pets`, `/api/companions`, `/api/v1/pets`,
  `/api/search`, `/pets.json`, `/api/registry` → todos `404`. `robots.txt` hace
  `Disallow: /api/`.
- **NUEVO**: existe `sitemap.xml` (`200`) que **enumera todas las mascotas** como
  rutas web `https://petdex.dev/pets/<slug>` (~10.4k entradas). Es un **listado XML**,
  no una API: sin paginación, sin búsqueda, sin metadata por mascota (solo `loc` +
  `lastmod`).
- **El slug NO mapea de forma determinista al asset.** `curated/boba/pet.json` y
  `curated/boba/spritesheet.webp` existen (`200`), pero mascotas de usuario como
  `aang`, `2-fortnight`, `ada-lovelace` **no** resuelven en `curated/<slug>` ni en
  `pets/<slug>`. El asset real vive bajo un **id hasheado** que solo aparece
  scrapeando el HTML de detalle, p. ej.
  `assets.petdex.dev/pets/aang-71d06f672df2/sprite.webp` (+ `zip.zip`).
- El `pet.json` curado sigue siendo **mínimo** (`id`, `displayName`, `description`,
  `spritesheetPath`): **sin** `frameWidth/frameHeight/cols/rows/fps`, **sin** `states`,
  **sin** `author`/`license`.

**Conclusión (árbol de decisión, Fase 4):** condición NO cumplida. Una galería in-app
exigiría (a) scraping frágil del HTML de detalle para resolver el id hasheado del
asset y (b) inferir la geometría (no la publica el manifiesto). Eso no es un
"endpoint estable + pet.json directo validable" → **galería remota e instalación por
slug quedan FUERA de alcance**. Se mantienen como vías seguras el **enlace externo**
("Ver Petdex") y la **importación local** del ZIP descargado por el usuario (que ya
infiere geometría 192×208 y detecta frames por fila). Reconsiderar solo si Petdex
publica el manifiesto estable+versionado descrito arriba.
