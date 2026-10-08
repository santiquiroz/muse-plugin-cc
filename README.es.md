# muse-plugin-cc

Delega tareas de código acotadas desde [Claude Code](https://claude.com/claude-code)
a la CLI de Muse Code (`muse`) en modo headless.

Claude Code sigue siendo el orquestador: define el contrato, conserva las
decisiones de dominio y revisa los cambios. Usa este plugin para una spec
acotada, un renombre, boilerplate, una corrección, una investigación enfocada
o una segunda opinión de solo lectura. Muse es lento: una tarea trivial de
tres pasos tardó unos cuatro minutos.

> Read this in English: [README.md](README.md)

## Cuándo conviene

- **Suscripción de tarifa fija:** las corridas delegadas se cargan a tu
  suscripción de Muse, así que delegar trabajo acotado no agrega costo
  por llamada.
- **Tareas acotadas:** una spec, un renombre, boilerplate, una corrección o
  una investigación enfocada; trabajo con un contrato claro que no necesita
  el contexto de la conversación.
- **Segundas opiniones de solo lectura:** `--read-only` revisa código pegado
  o un diff sin tocar archivos ni ejecutar comandos de shell.
- **Corridas largas desacopladas:** los procesos se desacoplan y corren hasta
  45 minutos por defecto mientras sigues trabajando; una espera interrumpida
  puede retomarse después con el id del proceso.
- **Costo honesto:** Muse es lento. Mantén las tareas delegadas autocontenidas
  y no lo uses para respuestas rápidas.

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

## Configuración inicial

Una vez por máquina:

```text
/muse:setup
```

Si hace falta, inicia sesión con `muse login` en una terminal normal. En
Windows también se requiere ejecutar `muse sandbox windows setup` desde una
terminal elevada. El comando setup verifica estas condiciones sin mostrar
credenciales.

## Uso

```text
/muse:rescue --background add unit tests for src/utils/money.ts covering rounding and negative amounts
/muse:rescue --read-only review this pasted diff for race conditions: <diff>
/muse:rescue --model muse-spark-1.3-contributor --reasoning-effort high diagnose this focused build failure
/muse:rescue --max-model-steps 30 implement the single acceptance criterion below
```

`/muse:rescue` invoca automáticamente el subagente `muse-rescue`, reenvía la
solicitud tal cual como su prompt y devuelve su salida verbatim, incluidas las
líneas `[muse-rescue] WARNING:`. Pon los flags antes de la tarea:

- `--wait` — predeterminado; ejecuta el subagente en foreground. Espera un
  proceso Muse desacoplado mediante tramos de `wait`. Si se interrumpe,
  conserva el id para usar `wait` o `cancel` después: el proceso sigue.
- `--background` — ejecuta el subagente en background y entrega su salida al
  terminar. Estos flags de ejecución se eliminan del prompt antes de
  reenviarlo; las llamadas Bash del forwarder siguen siendo foreground.
- `--model <slug>` — opcional; si se omite, Muse usa el modelo predeterminado
  de la cuenta. El slug se valida antes de ejecutar.
- `--reasoning-effort <tier>` — `none`, `minimal`, `low`, `medium`, `high`,
  `xhigh`, `max` o `ultra`. Si se omite, Muse usa su valor predeterminado.
- `--max-model-steps <N>` — entero positivo; predeterminado: 60.
- `--read-only` — agrega `--disable-write --disable-shell` y restricciones de
  solo lectura. Pega el código o diff a revisar; el delegado no puede ejecutar
  comandos de shell ni inspeccionar archivos.

Esta versión no incluye `--continue`; no se ha verificado reanudar sesiones
exec.

### Corridas largas

Las ejecuciones duran hasta `MUSE_RESCUE_MAX_SECONDS` (predeterminado:
2700 segundos, 45 minutos). `start` desacopla el proceso y `wait <id>` espera
en tramos de 480 segundos (`--slice <segundos>` acepta hasta 540). Cada tramo
es una llamada Bash foreground independiente con timeout 600000 ms; el código
75 indica que sigue corriendo. El presupuesto es
`1 + 1 + ceil(MAX/480) + 1`. Si se interrumpe el subagente, el proceso sigue:
conserva su id para usar `wait <id>` o `cancel <id>` después. Cancelar termina
con código 130; esperar pasada la fecha límite mata el árbol de procesos y
termina con código 124. Las ediciones permanecen en el árbol de trabajo.
`run` conserva el límite corto predeterminado de 540 segundos
(`MUSE_RESCUE_TIMEOUT` cambia los segundos). El forwarder envía la tarea y sus restricciones en un archivo
temporal `--prompt-file`, no en los argumentos del proceso.

### Qué ejecuta el forwarder

El subagente `muse-rescue` llama a `preflight`, luego `start` y repite
`wait <id>` mientras termine con código 75. Cada llamada es foreground. El
script desacopla Muse con `nohup`, background y `disown`; guarda los archivos
del proceso en `${MUSE_RESCUE_HOME:-$HOME/.muse-rescue}/jobs/<id>/`. Crea un
archivo de prompt temporal con la solicitud y sus restricciones, y ejecuta
el equivalente a:

```bash
muse exec --json --prompt-file <ruta temporal nativa> \
  --workspace <directorio actual nativo> \
  --approval-mode never --approval-judge off --no-foreign-personal-context \
  --user-input-auto-resolve --max-model-steps 60 \
  [--model <slug>] [--reasoning-effort <tier>]
```

`--read-only` además pasa `--disable-write --disable-shell`. El proceso hijo
recibe `GIT_TERMINAL_PROMPT=0`,
`GIT_SSH_COMMAND="ssh -o BatchMode=yes"`, sin overrides de conversión de rutas
MSYS y con stdin cerrado. Cuando existe `cygpath -w`, se usa para convertir las
rutas.

El filtro JSONL muestra el progreso y la respuesta terminal una sola vez,
oculta los fragmentos de respuesta mientras llegan e informa fallos de
herramientas y reintentos. El resumen incluye duración, ID de sesión y modelo
configurado cuando Muse los proporciona. Los códigos de salida se conservan;
al vencer el plazo se muestra un aviso explícito y se termina con código 124.
Cada espera muestra solamente el progreso nuevo.

## Modelo de seguridad

El comportamiento predeterminado depende del **sandbox propio del SO de Muse**,
que limita las escrituras al workspace. La red predeterminada del sandbox está
limitada al proxy de Muse (`--sandbox-network proxy-only`); el forwarder no
desactiva el sandbox ni habilita la red. `--approval-mode never` y
`--approval-judge off` significan que nada se aprueba automáticamente ni se
solicita aprobación. Una escritura fuera del workspace se deniega. El modo
`--read-only` también desactiva escrituras y herramientas de shell.

`--no-foreign-personal-context` es obligatorio: sin él, Muse puede cargar las
instrucciones y skills personales de Claude Code del usuario e invitar a una
delegación recursiva.

Las restricciones de la tarea prohíben hacer commit, push, reset, checkout,
clean, cambiar de rama y borrar archivos, pero las restricciones del prompt no
son un sandbox: el delegado aún puede hacer commit dentro del workspace. Antes
y después, el forwarder compara `HEAD`, rama, stash, git config y hooks, e
imprime `[muse-rescue] WARNING:` si detecta cambios. Revisa cada aviso y el
diff del árbol de trabajo antes del siguiente comando git. El forwarder rechaza
`--yolo`, `--disable-sandbox`, `--disable-approval`, `--trust-workspace` y
`--sandbox-network enabled`; cualquier opción desconocida termina con código 64.

## Configuración

| Variable | Predeterminado | Propósito |
|---|---|---|
| `MUSE_BIN` | descubrimiento del launcher | Reemplaza la selección del launcher de Muse (también lo usan las pruebas) |
| `META_API_KEY` | ninguna | Autenticación; tiene prioridad sobre el archivo de auth |
| `MUSE_RESCUE_HOME` | `$HOME/.muse-rescue` | Los archivos de cada proceso viven bajo `jobs/<id>/` |
| `MUSE_RESCUE_MAX_SECONDS` | `2700` (45 minutos) | Fecha límite de corridas desacopladas para `start`/`wait` |
| `MUSE_RESCUE_TIMEOUT` | `540` | Límite corto del comando `run`, en segundos |
| `MUSE_RESCUE_PS` | `powershell.exe` | Comando de inventario de procesos para limpieza de huérfanos (pruebas herméticas) |
| `MUSE_RESCUE_KILL` | `taskkill` | Comando para matar árboles de procesos (pruebas herméticas) |
| `MUSE_RESCUE_FORCE_WINDOWS` | `0` | Trata el host como Windows (pruebas) |

## Solución de problemas

- **Sin credenciales (código 70):** `META_API_KEY` tiene prioridad. Si no
  existe, setup comprueba `~/.config/muse/auth.json` para verificar un
  provider `meta` con `access_token` o `api_key` no vacío, sin imprimir el
  archivo. Si no encuentra ninguno, ejecuta `muse login` una vez en una
  terminal normal y luego `/muse:setup`.
- **Sandbox de Windows no listo (código 78):** `muse sandbox windows check`
  debe informar `status=ready`. De lo contrario, ejecuta
  `muse sandbox windows setup` desde una terminal elevada. Esta comprobación
  se omite en otros sistemas.
- **Falta la CLI o Node (código 127):** instala Muse Code o verifica que
  `muse` esté en `PATH`; instala Node.js y verifica que `node` esté en `PATH`
  para el filtro JSONL. En Windows, el `muse.cmd` de la instalación por
  usuario es un launcher; este plugin prefiere el binario versionado que está
  junto a él. `MUSE_BIN` reemplaza la selección del launcher. Ejecuta
  `/muse:setup` de nuevo.
- **Workspace bajo AppData se cuelga:** el shell del sandbox de Muse se queda
  colgado sin error si el workspace es privado al usuario con sesión iniciada,
  por ejemplo bajo `%USERPROFILE%\AppData\Local\Temp`. Las herramientas de
  archivos aún pueden funcionar. Usa un repositorio fuera del perfil, en una
  carpeta legible por Authenticated Users. El forwarder advierte si el
  workspace está bajo AppData del perfil, pero continúa la ejecución.
- **Workers huérfanos del sandbox:** en Windows, el vencimiento, la
  cancelación y el timeout corto de `run` matan todo el árbol con
  `taskkill /T /F /PID` mientras el padre sigue vivo. De otro modo, los
  workers del sandbox quedan huérfanos y retienen el lock global
  `Global\TbhWindowsSandboxAclPublication`: las siguientes ejecuciones fallan
  tras 120 segundos con un timeout del lock de publicación de ACL. El
  preflight de Windows revisa comandos e ids de padre de los workers del
  sandbox y mata solo aquellos cuyo padre ya no existe. Muestra
  `[muse-rescue] killed N orphan Muse sandbox worker(s) left by an interrupted run`.
  Los workers de una sesión interactiva con padre vivo permanecen intactos.
- **`dubious ownership` de git:** cada hijo recibe `safe.directory` para el
  workspace mediante `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_N` y
  `GIT_CONFIG_VALUE_N`, con barras normales. Se agrega al final de la
  configuración existente y no cambia el git config global. El usuario distinto
  del sandbox de Windows puede usar git sin el error
  `detected dubious ownership`.
- **Cuota o rate limit:** ante salidas que mencionen `rate limit`, `429`,
  `quota`, `usage limit`, `limit reached` o `insufficient`, detente e
  infórmalo para que quien llama elija otra vía; nunca reintentes Muse. La
  suscripción básica de Muse no ofrece un medidor de uso headless. Ante
  salidas `401`, `unauthorized` o `login`, ejecuta `muse login` en una
  terminal normal y luego `/muse:setup`.
- **Subagente interrumpido:** un subagente interrumpido deja el proceso
  desacoplado corriendo. Conserva su id para usar `wait <id>` o `cancel <id>`
  después. Cancelar termina con código 130; esperar pasada la fecha límite
  mata el árbol de procesos y termina con código 124. Las ediciones permanecen
  en el árbol de trabajo.
- **Reanudar sesiones:** esta versión no incluye `--continue`; no se ha
  verificado reanudar sesiones exec de Muse.

## Con otros delegados

Si usas varios plugins de delegación, decide su orden en tu `CLAUDE.md`;
este plugin no asume ninguno. Ante señales de cuota, rate limit o
autenticación se detiene y lo informa, para que quien llama elija otra vía.

Proyectos relacionados: [deepseek-plugin-cc](https://github.com/santiquiroz/deepseek-plugin-cc), [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc), [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc), [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc), [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc).

## Archivos y pruebas

| Ruta | Propósito |
|---|---|
| `agents/muse-rescue.md` | Subagente forwarder delgado, solo Bash |
| `scripts/muse-forward.sh` | Launcher, preflight, invocación segura, timeout y avisos git |
| `scripts/stream-filter.js` | Convierte Muse JSONL en progreso y respuesta |
| `tests/run.sh` | Suite hermética con una CLI falsa de Muse |
| `/muse:rescue`, `/muse:setup` | Comandos de delegación y preflight |
| `docs/delegation-guide.md` | Seguridad y fallback de delegación |
| `docs/claude-md-snippet.md` | Guía de delegación lista para pegar |

La suite se ejecuta con `bash tests/run.sh`. CI corre en Ubuntu y Windows.

## Licencia

[MIT](LICENSE)

**No está afiliado con Meta ni Anthropic.**
