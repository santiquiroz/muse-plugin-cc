# muse-plugin-cc

Delega tareas de código acotadas desde [Claude Code](https://claude.com/claude-code)
a la CLI de Muse Code (`muse`) en modo headless.

Claude Code sigue siendo el orquestador: define el contrato, conserva las
decisiones de dominio y revisa los cambios. Muse es el **segundo carril**,
inmediatamente después de
[DeepSeek Harness](https://github.com/santiquiroz/deepseek-plugin-cc) y antes
de Codex, Copilot, Antigravity, Cursor y Ollama. Úsalo para una spec acotada,
un renombre, boilerplate, una corrección, una investigación enfocada o una
segunda opinión de solo lectura; no para trabajos largos de varios pasos.
Muse es lento: una tarea trivial de tres pasos tardó unos cuatro minutos.

Plugins hermanos:
[deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc),
[copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc),
[antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc),
[cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) y
[ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).
**No está afiliado con Meta, Anthropic, OpenAI, GitHub ni los proyectos hermanos.**

> Read this in English: [README.md](README.md)

## Posición en la cadena de delegación

| Orden | Carril | Para qué sirve |
|---|---|---|
| Primero | [DeepSeek Harness](https://github.com/santiquiroz/deepseek-plugin-cc) | Carril agéntico preferido |
| **Segundo (este plugin)** | **Muse Code** | Tareas acotadas y segundas opiniones de solo lectura |
| Siguiente | Codex, Copilot, Antigravity, Cursor, Ollama | Alternativa cuando Muse no está disponible, tiene límite o no está autenticado |
| Mantener inline | Claude Code | Lógica de dominio, reglas de negocio, arquitectura y tareas cuyo PORQUÉ vive en la conversación |

Instala solo los carriles que uses; este plugin también funciona por sí solo.

## Requisitos

- Claude Code; el forwarder se ejecuta mediante su herramienta Bash (Git Bash
  en Windows).
- CLI de Muse Code. Los datos verificados de este plugin corresponden a Muse
  Code **1.4.3 en Windows 11**.
- Node.js en `PATH`; `scripts/stream-filter.js` requiere `node`.
- Autenticación mediante `muse login` o la variable de entorno `META_API_KEY`.

En Windows, la instalación por usuario tiene
`%LOCALAPPDATA%\Programs\muse\muse.cmd`; el binario real está junto a él como
`muse-bin-<version>.exe`. El forwarder prefiere el binario indicado en
`.muse-version`, luego el binario coincidente más reciente y después `muse` en
`PATH` en macOS/Linux. `MUSE_BIN` reemplaza la selección del launcher (también
lo usan las pruebas).

## Instalación

En Claude Code:

```text
/plugin marketplace add santiquiroz/muse-plugin-cc
/plugin install muse@muse-plugin-cc
```

Luego, una vez por máquina:

```text
/muse:setup
```

Si hace falta, inicia sesión con `muse login` en una terminal normal. En
Windows también se requiere ejecutar `muse sandbox windows setup` desde una
terminal elevada. El comando setup verifica estas condiciones sin mostrar
credenciales.

## Uso

```text
/muse:rescue add unit tests for src/utils/money.ts covering rounding and negative amounts
/muse:rescue --read-only review this pasted diff for race conditions: <diff>
/muse:rescue --model muse-spark-1.3-contributor --reasoning-effort high diagnose this focused build failure
/muse:rescue --max-model-steps 30 implement the single acceptance criterion below
```

Pon los flags antes de la tarea:

- `--model <slug>` — opcional; si se omite, Muse usa el modelo predeterminado
  de la cuenta. El slug se valida antes de ejecutar.
- `--reasoning-effort <tier>` — `none`, `minimal`, `low`, `medium`, `high`,
  `xhigh`, `max` o `ultra`. Si se omite, Muse usa su valor predeterminado.
- `--max-model-steps <N>` — entero positivo; predeterminado: 60.
- `--read-only` — agrega `--disable-write --disable-shell` y restricciones de
  solo lectura. Pega el código o diff a revisar; el delegado no puede ejecutar
  comandos de shell ni inspeccionar archivos.

Esta versión no incluye `--continue`; no se ha verificado reanudar sesiones
exec. Cada ejecución tiene un límite de 9 minutos
(`MUSE_RESCUE_TIMEOUT` puede cambiar los segundos). Muse headless puede tardar:
las ediciones que alcanzó a hacer una ejecución interrumpida quedan en el árbol
de trabajo. El forwarder envía la tarea y sus restricciones en un archivo
temporal `--prompt-file`, no en los argumentos del proceso.

## Qué ejecuta el forwarder

El subagente `muse-rescue` hace una llamada foreground de preflight y, solo si
esta termina bien, una llamada foreground de ejecución. Crea un archivo de
prompt temporal con la solicitud y sus restricciones, y ejecuta el equivalente
a:

```bash
muse exec --json --prompt-file <ruta temporal nativa> \
  --workspace <directorio actual nativo> \
  --approval-mode never --approval-judge off --no-foreign-personal-context \
  --user-input-auto-resolve --max-model-steps 60 \
  [--model <slug>] [--reasoning-effort <tier>]
```

`--no-foreign-personal-context` es obligatorio: sin él, Muse puede cargar las
instrucciones y skills personales de Claude Code del usuario e invitar a una
delegación recursiva. El proceso hijo recibe `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, sin overrides de conversión de rutas
MSYS y con stdin cerrado. Cuando existe `cygpath -w`, se usa para convertir las
rutas.

El filtro JSONL muestra el progreso y la respuesta terminal una sola vez,
oculta los fragmentos de respuesta mientras llegan e informa fallos de
herramientas y reintentos. El resumen incluye duración, ID de sesión y modelo
configurado cuando Muse los proporciona. Los códigos de salida se conservan;
los estados de timeout `124`, `137` y `142` también generan un aviso explícito.

## Modelo de seguridad

El comportamiento predeterminado depende del **sandbox propio del SO de Muse**,
que limita las escrituras al workspace. La red predeterminada del sandbox está
limitada al proxy de Muse (`--sandbox-network proxy-only`); el forwarder no
desactiva el sandbox ni habilita la red. `--approval-mode never` y
`--approval-judge off` significan que nada se aprueba automáticamente ni se
solicita aprobación. Una escritura fuera del workspace se deniega. El modo
`--read-only` también desactiva escrituras y herramientas de shell.

Las restricciones del prompt no son un sandbox: el delegado aún puede hacer
commit dentro del workspace. Antes y después, el forwarder compara `HEAD`,
rama, stash, git config y hooks, e imprime `[muse-rescue] WARNING:` si detecta
cambios. Revisa cada aviso y el árbol de trabajo antes del siguiente comando
git. El forwarder rechaza `--yolo`, `--disable-sandbox`,
`--disable-approval`, `--trust-workspace` y
`--sandbox-network enabled`; cualquier opción desconocida termina con código 64.

**Trampa de AppData en Windows:** el shell del sandbox de Muse se queda
colgado sin error si el workspace es privado al usuario con sesión iniciada,
por ejemplo bajo `%USERPROFILE%\AppData\Local\Temp`. Las herramientas de
archivos aún pueden funcionar. Usa un repositorio fuera del perfil, en una
carpeta legible por Authenticated Users. El forwarder advierte si el workspace
está bajo AppData del perfil, pero continúa la ejecución.

### Preflight de autenticación y sandbox Windows

`META_API_KEY` tiene prioridad. Si no existe, setup comprueba
`~/.config/muse/auth.json` para verificar un provider `meta` con `access_token`
o `api_key` no vacío, sin imprimir el archivo. Si no encuentra ninguno, el
preflight termina con código 70 e indica ejecutar `muse login` una vez en una
terminal normal y luego `/muse:setup`.

En Windows, `muse sandbox windows check` debe informar `status=ready`. De lo
contrario, preflight termina con código 78 e indica ejecutar
`muse sandbox windows setup` desde una terminal elevada. Esta comprobación se
omite en otros sistemas.

## Archivos y pruebas

| Ruta | Propósito |
|---|---|
| `agents/muse-rescue.md` | Subagente forwarder delgado, solo Bash |
| `scripts/muse-forward.sh` | Launcher, preflight, invocación segura, timeout y avisos git |
| `scripts/stream-filter.js` | Convierte Muse JSONL en progreso y respuesta |
| `tests/run.sh` | Suite hermética con una CLI falsa de Muse |
| `/muse:rescue`, `/muse:setup` | Comandos de delegación y preflight |
| `docs/delegation-guide.md` | Carriles, seguridad y fallback |
| `docs/claude-md-snippet.md` | Guía de delegación lista para pegar |

La suite se ejecuta con `bash tests/run.sh`. CI corre en Ubuntu y Windows.

## Todavía no

- `--continue` / reanudación de sesión; no se ha verificado reanudar sesiones
  exec de Muse.
- Medidor de cuota; la suscripción básica de Muse no ofrece un medidor de uso
  headless. Ante cuota o rate limit, detente y usa el siguiente carril; no
  reintentes.

## Licencia

[MIT](LICENSE)
