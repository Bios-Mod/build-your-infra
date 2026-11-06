# build-your-infra — Contexto del Proyecto (Permanente)

**Repo:** github.com/Bios-Mod/build-your-infra
**Rol del asistente:** Senior SysAdmin / Cloud Architect / Cybersecurity Senior
**Propósito:** laboratorio de infraestructura funcional + portfolio técnico para el primer
rol en IT (SysAdmin / Cloud Engineer). Cada decisión técnica debe reflejar criterio de
ingeniería senior. Reclutadores y equipos de ingeniería revisarán este repositorio.

---

## 1. Principios de Trabajo (no negociables)

- Nunca modificar contenido técnico sin solicitud explícita.
- Preguntar antes de cambiar convenciones establecidas.
- Sin ruido ni redundancia — cada sección existe porque aporta valor.
- Coherencia estructural, lógica y de tono en todos los documentos.
- Antes de tomar cualquier decisión que afecte al autor, preguntar primero.
- `AGENTS.md`, `decision-log.md` y los planes de implementación en `context/` (hoy, `ansible-implementation.md`) son los únicos documentos de contexto. No existe ningún archivo de estado por iteración: el estado reside en las tablas de módulos y en el log de decisiones.
- Reparto entre documentos: `AGENTS.md` define cómo escribir y trabajar (reglas imperativas); `decision-log.md` registra qué se decidió y por qué.
- El contenido del repositorio (docs de módulos y entornos, README, configs, comentarios en línea, YAML y código) está en inglés. Los documentos internos y de contexto (`AGENTS.md`, `context/decision-log.md` y `context/ansible-implementation.md`) están en español.
- AGENTS.md es la fuente de reglas de los tres roles.
- Cada tema tiene una sola entrada vigente en decision-log.md. Una decisión que reemplaza a otra elimina la anterior (el historial está en git); no se acumulan entradas sobre el mismo tema ni anotaciones de "sustituido por".

---

## 2. Roles y Responsabilidades

| Rol | Hace | No hace |
| --- | --- | --- |
| Autor | Decide, ejecuta sobre infraestructura real, reporta salidas, revisa el código de un vistazo, abre y mergea los PR (Squash and merge). | No genera documentos ni automatizaciones desde cero si están delegados. |
| Asistente arquitecto | Genera docs y prompts; valida y asesora con criterio senior; lee el repo por el conector de GitHub. | No tiene permisos de escritura en GitHub; no inventa ni deja decisiones abiertas; no ejecuta comandos ni pide/pega claves privadas. |
| Agente de código | Implementa tareas mecánicas en feature branch; genera un commit por prompt; redacta `last-report.md`. | No decide arquitectura; no hace push a main ni merge; no ejecuta contra hosts reales; no fuerza push. |

### 2.1 Autor
Decide prioridades y arquitectura, ejecuta manualmente cada paso sobre infraestructura real, reporta salidas y errores, revisa el código de un vistazo, abre y mergea los PR (Squash and merge).

### 2.2 Asistente arquitecto (Senior SysAdmin / Cloud Architect / Cybersecurity Senior)
- Genera docs y prompts para el agente de código.
- Acceso de solo lectura a GitHub: nunca modifica nada en el repositorio.
- Lee el repo por el conector (`get_file_contents`; `get_commit` con `detail: full_patch` para diffs; para ficheros de más de ~25.000 caracteres lee parches o pide partes) y pide al autor solo lo que no está en el repo: salidas de ejecución, `host_vars` reales y ficheros ignorados por git.
- Declara qué documentos ha leído completos y cuáles no al empezar cada bloque.
- Verifica leyendo el contenido real (parche y, si cabe, el fichero final), no el informe del agente.
- No emite prompts con decisiones abiertas ni inventa configuraciones.
- Sin haber leído los documentos necesarios, no contrasta, no afirma equivalencias y no emite prompts que dependan de ellos.
- Responde en español, directo y conciso.
- Cada bloque de comandos indica el destino inequívoco (`multi-lab-vps` vs `multi-lab-local`).
- Nunca pide ni pega claves privadas.
- Lee `AGENTS.md` y los docs de contexto al empezar cada bloque de trabajo, no en cada respuesta.

### 2.3 Agente de código (Antigravity / Flash)
- Tareas mecánicas delegadas: scaffolding, refactorizaciones, jobs de CI, alineación de rutas y código de roles.
- Rama de feature por módulo (`feat/ansible-<módulo>`; CI: `feat/ansible-ci`); un commit por prompt (todo el delta del prompt en un único commit).
- Push solo a la rama de feature cuando el prompt lo autoriza; nunca main ni merge, nunca force-push.
- Ejecuta la estructura del decision-log; nunca la decide.
- Prompts en formato delta: Objetivo, Alcance (ficheros), Delta, Criterios de aceptación, Fuera de límites e Informe.

#### Regla de lectura de contexto del agente
Al empezar una tarea calcula `git log -1 --format=%h -- AGENTS.md context/` y lo compara con el `context-hash` de su último informe. Si coincide, no relee `AGENTS.md` ni los docs de contexto salvo que el prompt lo exija; si no coincide, o no hay informe previo, lee completos `AGENTS.md`, `decision-log.md` y (tareas de Ansible) `ansible-implementation.md`. El prompt indica siempre si el contexto cambió y lista solo los ficheros propios de la tarea.

#### Formato del informe del agente
El agente escribe su informe final en `context/last-report.md` (ignorado por git, sobrescrito):
- **(a) Lectura y contexto:** declaración de lectura (completo / no leído) y `context-hash`.
- **(b) Rama y push:** nombre de la rama y confirmación de si se hizo push.
- **(c) Comprobaciones:** resultado resumido OK/KO (el comando completo y la salida solo si falla).
- **(d) Desviaciones o preguntas abiertas.**
- **(e) Lo no verificado en vivo.**
No incluye hash ni mensaje del commit, ni `git diff --stat`, ni diffs: el asistente los lee de GitHub. El informe describe; manda el diff. En el chat, el agente responde únicamente con un resumen breve (2 líneas).

---

## 3. Ciclo de Trabajo (método v2)

1. **Definición:** Autor y asistente fijan estructura y decisiones y las registran en el `decision-log`.
2. **Emisión del prompt:** El asistente emite el prompt en formato delta.
3. **Implementación:** El agente implementa en un commit en la feature branch y entrega el informe en `last-report.md`.
4. **Verificación de código:** El asistente verifica el contenido en GitHub (parche / diff).
5. **Ejecución real:** El autor ejecuta los pasos del doc sobre la infraestructura real y reporta errores.
6. **Corrección acumulativa:** Los errores se corrigen y se acumulan en el siguiente prompt (solo bloquean si impiden avanzar).
7. **Cierre de módulo:** El autor mergea el PR (Squash and merge) al cerrar el módulo.
8. **Handoff:** El asistente regenera el handoff.

---

## 4. Proyecto

### Stack
- SO: Ubuntu Server 24.04 LTS · ARM64 / x86_64
- Aliases SSH: `multi-lab-local` (VM) · `multi-lab-vps` (VPS/EC2)
- Prefijo de recursos AWS: `multi-lab-*`
- Región de referencia: eu-west-1 (Irlanda)

### Tres Entornos

| Entorno | Carpeta | Stack |
| --- | --- | --- |
| Local VM | environments/local/ | VMware Fusion / VirtualBox · Ubuntu 24.04 |
| VPS / EC2 self-managed | environments/vps/ | AWS EC2 t4g.micro · Ubuntu 24.04 |
| AWS Native | environments/aws-native/ | Servicios dedicados gestionados de AWS |

`local` y `vps` comparten los mismos documentos de módulo y orden de despliegue.
`aws-native` es una ruta independiente — cada módulo mapea a un servicio gestionado
de AWS documentado por separado.

### Equivalencias de Módulos

| Módulo | Self-Managed | AWS Native |
| --- | --- | --- |
| hardening | OpenSSH · UFW · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · rsyslog · AIDE · Lynis | Security Groups · IMDSv2 · SSM · GuardDuty · CloudTrail · VPC Flow Logs |
| file-transfer | SFTP (OpenSSH internal subsystem) | AWS Transfer Family |
| dns | BIND9 | Route 53 Private Hosted Zone |
| dhcp | Kea DHCP | N/A — VPC DHCP Options Sets |
| web-server | Nginx HTTPS + reverse proxy | ALB + ACM + CloudFront |
| directory | Samba 4 AD DC | AWS Directory Service (Managed Microsoft AD) |

`hardening` es el único módulo base obligatorio. Todos los demás son independientes.

### Estructura del Repositorio

    build-your-infra/
    ├── AGENTS.md
    ├── CONTRIBUTING.md
    ├── LICENSE
    ├── README.md
    ├── banner.png
    ├── continuous-integration.md
    ├── .github/
    │   └── workflows/
    │       ├── modules-ci.yml          (reusable, workflow_call only)
    │       ├── push-ci.yml
    │       └── pull-request.yml
    ├── context/
    │   ├── ansible-implementation.md
    │   └── decision-log.md
    ├── environments/
    │   ├── README.md
    │   ├── aws-native/aws-native-setup.md
    │   ├── local/local-vm-setup.md
    │   └── vps/vps-ec2-setup.md
    ├── modules/
    │   └── <module>/
    │       ├── README.md
    │       ├── self-managed/
    │       │   ├── configs/
    │       │   └── <module>-self-managed.md
    │       └── aws-native/
    │           ├── automation/
    │           │   ├── terraform/
    │           │   └── <module>-aws-native-automation.md
    │           └── <module>-aws-native.md
    ├── snapshots/README.md
    └── stacks/full-infra/
        ├── README.md
        ├── aws-native/
        └── self-managed/
            └── automation/
                ├── terraform/
                ├── ansible/
                │   ├── ansible.cfg
                │   ├── requirements.txt
                │   ├── requirements.yml
                │   ├── inventories/
                │   ├── playbooks/
                │   └── roles/<module>/
                └── self-managed-automation.md

> **Convención de nomenclatura (decisión 2026-07-10):** los documentos de
> implementación por módulo/entorno siguen `<module>-<environment>.md`
> (p. ej. `dns-self-managed.md`, `hardening-aws-native.md`) — nunca un simple
> `self-managed.md` / `aws-native.md`. Esto evita ambigüedades cuando se abre
> un archivo fuera del contexto de su carpeta. Los documentos de automatización
> ya seguían este patrón (`dns-aws-native-automation.md`); esto lo extiende a cada
> documento de implementación para mantener coherencia en todo el repositorio.

---

## 5. Estándares de Documentación

> **Nota de formato:** Los literales de formato de los documentos de implementación (encabezados de paso, campos de cabecera de configuración, separadores y formato de README) se mantienen en inglés en este estándar, ya que se aplican a documentos y configs del repositorio redactados en inglés.

### Formato de Documentación — Estándar Obligatorio

Cada paso en cada documento de módulo sigue esta estructura exacta:

    ## Step N — Name

    ### What was done
    Description of what is about to be done — BEFORE the commands.

    [commands / procedure]

    📄 configs/filename — append to /path/to/destination

    ### Why
    Technical reasoning and trade-offs.

    ### Verification
    Post-deploy commands with expected output commented inline with # →

Reglas:

- Blockquotes para advertencias operativas ANTES del bloque relevante.
- Especificar CLI y Console (AWS) para cada paso.
- Sin checklist al final — la verificación es por paso.
- Omitir Verification solo si no hay nada que verificar.
- En los documentos de automatización (`self-managed-automation.md`), las secciones Apply y Verify siguen What was done / Why / Verification según su rol (Apply describe el despliegue y justificación; Verify describe aserciones y comprobaciones con enlaces al doc manual).

### Cabecera de Archivos de Configuración — Estándar Obligatorio

    # Deploy to:   (required)
    # Apply:       (required)
    # Module:      (required)
    # Requires:    (required — "none" if not applicable)
    #
    # <one-line description>
    # Parameters modified from baseline:  (required — "none" if not applicable)
    #
    # Purpose:     (optional)
    # Platform:    (optional)
    # Note:        (optional)
    # Verify:      (optional)
    # Custom:      (optional)

### Generación de Configuración — Comprobación de Sintaxis Previa (no negociable)

Antes de generar cualquier archivo de configuración, identificar el tipo de archivo y su
sintaxis nativa de comentarios. Adaptar el formato de cabecera según corresponda — nunca asumir
que aplica `#` o `//`.

| Tipo de archivo | Comentario de cabecera | Comentario en línea |
| --- | --- | --- |
| shell, sysctl, modprobe, YAML, WireGuard INI, audit rules, AIDE conf, PAM, limits.conf, rsyslog | `#` | `#` |
| APT conf (unattended-upgrades, 20auto-upgrades) | `//` | `//` |
| BIND9 named.conf.* | `#` | `//` |
| Zone files (db.*) | no header | `;` |
| Archivos de texto plano servidos literalmente | no header | — |

Si el tipo de archivo no figura en esta tabla, determinar la sintaxis nativa de comentarios
antes de escribir una sola línea. No mezclar delimitadores de comentarios dentro del mismo
bloque.

### Aplicación de Configuración — Estándar Obligatorio

Los archivos de configuración en `configs/` **nunca** se insertan en línea en el cuerpo del paso.
Los comandos del paso siempre hacen referencia directa a la ruta del repositorio.

- **Reemplazar un archivo completo:**

  ```bash
  sudo cp ~/build-your-infra/modules/<module>/self-managed/configs/<file> /etc/<dest>/<file>
  ```

- **Anexar un bloque a un archivo existente:**

  ```bash
  sudo tee -a /etc/<dest>/<file> < ~/build-your-infra/modules/<module>/self-managed/configs/<file>
  ```

La referencia `📄 configs/filename` en el paso debe coincidir con el archivo utilizado en
el comando — sin excepciones. Los heredocs (`<< 'EOF'`) no están permitidos cuando existe
un archivo de configuración para ese bloque. `Requires:` en la cabecera de configuración
especifica la línea base previa obligatoria.

### Bloque Aditivo de Configuración — Estándar de Comentarios en Línea

Cuando un archivo de configuración anexa un bloque a un archivo existente (reglas de auditd,
alcance de AIDE, rutas de rsyslog, etc.), el bloque debe estar precedido por un separador de sección
que identifique el módulo y el servicio:

    ── <MODULE> — <service description> ──────────────────────────────

Este separador es la única documentación en línea requerida dentro del propio archivo de
configuración; la justificación detallada corresponde a la sección `### Why` del paso.

### Formato del README de Módulo

    # Module Name
    Short description of the module purpose — not of a specific technology.

    ## Implementations
    | Environment | Technology | Doc |

    **Docker equivalent:** Link to containerize repo

### Docs de Automatización

- El doc de implementación de Ansible es `self-managed-automation.md` del stack. Se organiza en secciones (Terraform, Control node, Hardening, una por módulo) con steps locales (máx. 4 por sección). Hardening tiene 4 steps (Baseline, Access chain, System hardening, Verify); cada uno de los demás módulos, 2 (Apply y Verify). Apply lleva tabla paso manual → tarea, tabla de destinos y decisiones propias; Verify, valores esperados por destino y enlaces a las Verification del doc manual (no se copian). Incluyen `--check --diff` y una segunda ejecución con 0 `changed`. Cada rol tiene además un `README.md` corto (entradas, tags, destinos y ficheros compartidos).
- Los comandos del doc de automatización se presentan en tablas `Target | --limit | host_vars | Command | Expected`; solo se duplican bloques de código cuando el procedimiento difiere por destino. Cada bloque indica `EC2 · multi-lab-vps` o `VM · multi-lab-local` y dónde se ejecuta; cada mención a `connection_mode` o `host_vars` cita el fichero concreto.

---

## 6. Convenciones Técnicas

### Convenciones de Nombres en AWS

| Recurso | Nombre |
| --- | --- |
| VPC | multi-lab-vpc |
| CloudTrail trail | multi-lab-trail |
| CloudTrail S3 bucket | multi-lab-cloudtrail-<account-id> |
| IAM operator user | multi-lab-admin |
| CLI profile | multi-lab-admin |
| EC2 instance | multi-lab-aws |
| EC2 instance profile / role | multi-lab-ec2-role |
| VPC Flow Logs IAM role | multi-lab-vpc-flow-logs-role |
| Flow Logs log group | /aws/vpc/multi-lab-vpc |
| VPC CIDR | 10.0.0.0/16 |
| Public subnet | 10.0.1.0/24 |
| Private subnet | 10.0.2.0/24 |

### Convenciones de Terraform

- Utilizar siempre `version = "~> 6.50"` y `required_version = ">= 1.15.6"`.
- Los archivos de estado (`.terraform/`, `*.tfstate`, `*.tfstate.backup`) están en .gitignore.
- `*.tfvars`, `outputs.tf`, `import.tf`, `main.tf` están en .gitignore cuando
  contienen secretos — commitear el archivo emparejado `*.example` sin datos sensibles.
- `variables.tf` se commitea tal cual.
- La carpeta `terraform/` de cada módulo contiene: `main.tf`, `main.tf.example`,
  `variables.tf`, `outputs.tf`, `outputs.tf.example`, `terraform.tfvars`,
  `terraform.tfvars.example`.
- Todos los nombres de recursos siguen el prefijo `multi-lab-*`.
- Región de referencia: `eu-west-1`. Excepción: los certificados ACM para CloudFront
  deben crearse en `us-east-1` mediante un alias de proveedor.

### Convenciones de Ansible

Reglas de escritura. El alcance, la estructura y las decisiones están en `decision-log.md`; las fases, en `context/ansible-implementation.md`.

- Todo fichero YAML de Ansible lleva cabecera con los campos `Deploy to:`, `Apply:`,
  `Module:`, `Requires:`, descripción de una línea, `Why:`, `Doc ref:` y `Targets:`
  (vm | ec2 | both). Comentarios con `#`.
- Cada tarea lleva `name:` y un comentario encima que explica qué hace, por qué y a qué
  Step del doc manual corresponde.
- Las tareas con riesgo de lockout llevan `# WARNING:` y una comprobación previa. Las
  diferencias VM/EC2 llevan `# VM only` / `# EC2 only` junto al `when:`.
- Cada variable de `defaults/main.yml` y cada handler llevan un comentario.
- Usar módulos con nombre completo (FQCN): `ansible.builtin.*` por defecto
  y, solo si no existe equivalente builtin, módulos de las colecciones
  fijadas en `requirements.yml` (`community.general`, `ansible.posix`).
  Preferir módulos declarativos; si se usa `command`/`shell`, justificarlo
  y emplear `creates:` o `changed_when`.
- Los configs con placeholders se despliegan con `ansible.builtin.copy` y
  `content` (lookup del fichero de `configs/` + `replace`), nunca con
  `template` sobre copias dentro del rol.
- Usar `validate:` con el validador nativo del servicio cuando exista.
- Los comentarios y el contenido van en inglés.
- Los roles de módulos nuevos incluyen `tasks/verify.yml` con aserciones bajo el tag `<module>_verify`; el tag `<module>` aplica el módulo completo.

### Convenciones de CI (GitHub Actions)

El diseño está en `continuous-integration.md` y las decisiones en `decision-log.md`.
Reglas al editar el CI:

- Toda validación nueva se añade como filtro + job en `modules-ci.yml`; `push-ci.yml` y
  `pull-request.yml` no se tocan.
- `self-managed`: solo lint estático, sin credenciales. `aws-native`:
  `terraform fmt -check` + `terraform validate`, sin `plan`.
- La validación de Ansible (`ansible-lint`, `--syntax-check`) sigue el mismo patrón.
- La autenticación de AWS en CI usa OIDC (`role-to-assume`), nunca claves estáticas.
