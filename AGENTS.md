# build-your-infra — Contexto del Proyecto (Permanente)

**Repo:** github.com/Bios-Mod/build-your-infra
**Assistant role:** Senior SysAdmin / Cloud Architect / Cybersecurity Senior
**Propósito:** laboratorio de infraestructura funcional + portfolio técnico para el primer
rol en IT (SysAdmin / Cloud Engineer). Cada decisión técnica debe reflejar criterio de
ingeniería senior. Reclutadores y equipos de ingeniería revisarán este repositorio.

---

## Principios de Trabajo (no negociables)

- Nunca modificar contenido técnico sin solicitud explícita.
- Preguntar antes de cambiar convenciones establecidas.
- Sin ruido ni redundancia — cada sección existe porque aporta valor.
- Coherencia estructural, lógica y de tono en todos los documentos.
- Antes de tomar cualquier decisión que afecte al autor, preguntar primero.
- El autor revisa y hace merge de todo. El asistente y los agentes delegados nunca hacen push a `main` y nunca hacen merge; trabajan en feature branches y abren pull requests.
- Los documentos de implementación (`*-self-managed.md`, `*-aws-native.md`) son redactados por el asistente y validados por el autor al aplicar cada paso. Los errores encontrados durante la aplicación se incorporan de vuelta al documento.
- `AGENTS.md` y `decision-log.md` son los únicos documentos de contexto. No existe ningún archivo de estado por iteración: el estado reside en las tablas de módulos y en el log de decisiones.
- El contenido del repositorio (docs de módulos y entornos, README, configs, comentarios en línea, YAML y código) está en inglés. Los documentos internos y de contexto (AGENTS.md y context/decision-log.md) están en español.

---

## Stack

- SO: Ubuntu Server 24.04 LTS · ARM64 / x86_64
- Aliases SSH: `multi-lab-local` (VM) · `multi-lab-vps` (VPS/EC2)
- Prefijo de recursos AWS: `multi-lab-*`
- Región de referencia: eu-west-1 (Irlanda)

---

## Tres Entornos

| Entorno | Carpeta | Stack |
| --- | --- | --- |
| Local VM | environments/local/ | VMware Fusion / VirtualBox · Ubuntu 24.04 |
| VPS / EC2 self-managed | environments/vps/ | AWS EC2 t4g.micro · Ubuntu 24.04 |
| AWS Native | environments/aws-native/ | Servicios dedicados gestionados de AWS |

`local` y `vps` comparten los mismos documentos de módulo y orden de despliegue.
`aws-native` es una ruta independiente — cada módulo mapea a un servicio gestionado
de AWS documentado por separado.

---

## Equivalencias de Módulos

| Módulo | Self-Managed | AWS Native |
| --- | --- | --- |
| hardening | OpenSSH · UFW · Fail2Ban · WireGuard · sysctl · AppArmor · auditd · rsyslog · AIDE · Lynis | Security Groups · IMDSv2 · SSM · GuardDuty · CloudTrail · VPC Flow Logs |
| file-transfer | SFTP (OpenSSH internal subsystem) | AWS Transfer Family |
| dns | BIND9 | Route 53 Private Hosted Zone |
| dhcp | Kea DHCP | N/A — VPC DHCP Options Sets |
| web-server | Nginx HTTPS + reverse proxy | ALB + ACM + CloudFront |
| directory | Samba 4 AD DC | AWS Directory Service (Managed Microsoft AD) |

`hardening` es el único módulo base obligatorio. Todos los demás son independientes.

---

## Estructura del Repositorio

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
    │       │   ├── automation/
    │       │   │   └── ansible/
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
                └── self-managed-automation.md

> **Convención de nomenclatura (decisión 2026-07-10):** los documentos de
> implementación por módulo/entorno siguen `<module>-<environment>.md`
> (p. ej. `dns-self-managed.md`, `hardening-aws-native.md`) — nunca un simple
> `self-managed.md` / `aws-native.md`. Esto evita ambigüedades cuando se abre
> un archivo fuera del contexto de su carpeta. Los documentos de automatización
> ya seguían este patrón (`dns-aws-native-automation.md`); esto lo extiende a cada
> documento de implementación para mantener coherencia en todo el repositorio.

---

## Formato de Documentación — Estándar Obligatorio

> **Nota de formato:** Los literales de formato de los documentos de implementación (encabezados de paso, campos de cabecera de configuración, separadores y formato de README) se mantienen en inglés en este estándar, ya que se aplican a documentos y configs del repositorio redactados en inglés.

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

## Cabecera de Archivos de Configuración — Estándar Obligatorio

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

## Generación de Configuración — Comprobación de Sintaxis Previa (no negociable)

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

## Aplicación de Configuración — Estándar Obligatorio

Los archivos de configuración en `configs/` **nunca** se insertan en línea en el cuerpo del paso.
Los comandos del paso siempre hacen referencia directa a la ruta del repositorio.

- **Reemplazar un archivo completo:**

  ```bash
  sudo cp ~/build-your-infra/<module>/self-managed/configs/<file> /etc/<dest>/<file>
  ```

- **Anexar un bloque a un archivo existente:**

  ```bash
  sudo tee -a /etc/<dest>/<file> < ~/build-your-infra/<module>/self-managed/configs/<file>
  ```

La referencia `📄 configs/filename` en el paso debe coincidir con el archivo utilizado en
el comando — sin excepciones. Los heredocs (`<< 'EOF'`) no están permitidos cuando existe
un archivo de configuración para ese bloque. `Requires:` en la cabecera de configuración
especifica la línea base previa obligatoria.

## Bloque Aditivo de Configuración — Estándar de Comentarios en Línea

Cuando un archivo de configuración anexa un bloque a un archivo existente (reglas de auditd,
alcance de AIDE, rutas de rsyslog, etc.), el bloque debe estar precedido por un separador de sección
que identifique el módulo y el servicio:

    ── <MODULE> — <service description> ──────────────────────────────

Este separador es la única documentación en línea requerida dentro del propio archivo de
configuración; la justificación detallada corresponde a la sección `### Why` del paso.

---

## Formato del README de Módulo

    # Module Name
    Short description of the module purpose — not of a specific technology.

    ## Implementations
    | Environment | Technology | Doc |

    **Docker equivalent:** Link to containerize repo

---

## Convenciones de Nombres en AWS

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

---

## Convenciones de Terraform

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
- `terraform/` y `ansible/` coexisten dentro de `automation/`, y ambos se mantienen
  separados de `configs/`, que es hermano de `automation/` al nivel de
  `self-managed/`. Los archivos `.tf` y los playbooks no son configuraciones del sistema.

## Convenciones de Ansible

- Alcance: `self-managed` únicamente. `aws-native` no tiene capa de SO que configurar.
- Los roles residen en `modules/<module>/self-managed/automation/ansible/`. El inventario
  y el playbook orquestador residen en
  `stacks/full-infra/self-managed/automation/ansible/`.
- `configs/` sigue siendo la única fuente de verdad: los roles despliegan esos archivos
  (`copy`, `blockinfile`, `template`); el contenido de configuración nunca se duplica
  dentro de los roles.
- La implementación de Ansible sigue el mismo estándar de documentación que cada módulo:
  What was done / Why / Verification, incluyendo `--check --diff` y una
  re-ejecución de idempotencia.
- Las conexiones respetan la línea base de hardening (SSH Ed25519, puerto 22222) —
  los roles de hardening deben contemplar la transición del puerto 22 → 22222.

## Agentes Delegados

- Los agentes pueden crear y modificar archivos en feature branches y commitear allí.
  Nunca hacen push a `main` ni merge.
- Cada tarea de agente especifica: alcance de archivos, lectura obligatoria
  (`AGENTS.md`, `decision-log.md`), criterios de aceptación y lo que queda fuera de
  límites (contenido técnico no solicitado explícitamente).
- Los agentes se encargan del trabajo mecánico (scaffolding, actualización de enlaces, jobs de CI,
  migración de configs a estructura de roles). Las decisiones de diseño y el razonamiento de los
  documentos de implementación permanecen con el autor y el asistente.

> **Nota de alcance:** Terraform cubre únicamente el aprovisionamiento de infraestructura. En
> `aws-native`, esto representa los recursos AWS de cada módulo. En `self-managed`,
> esto representa exclusivamente el lanzamiento de la instancia EC2 desde el snapshot de la AMI en
> `stacks/full-infra/self-managed/` — los módulos individuales self-managed no tienen
> Terraform, ya que no hay infraestructura cloud que aprovisionar a nivel de
> módulo. La capa de configuración a nivel de SO (aplicada manualmente hoy,
> documentada por módulo) es la brecha exacta que cerrará Ansible — ver
> decision-log.md para el alcance completo.
> Los módulos individuales self-managed no tienen Terraform; su carpeta `automation/` aloja el rol de Ansible para ese módulo (`automation/ansible/`).

---

## Convenciones de CI (GitHub Actions)

- Un único workflow reutilizable, `modules-ci.yml` (solo `workflow_call`), define
  cada job de módulo una sola vez. `push-ci.yml` (push a `actions-implementation`) y
  `pull-request.yml` (pull_request a `main`) lo invocan.
- Un job `changes` ejecuta `dorny/paths-filter` y expone un output por
  módulo-entorno más `any-module`. Cada job de módulo se ejecuta condicionalmente en
  función de su propio output.
- Los jobs de `self-managed` ejecutan únicamente lint estático (sin credenciales, sin llamadas a AWS).
- Los jobs de `aws-native` ejecutan únicamente `terraform fmt -check` + `terraform validate`.
  `terraform plan` queda excluido intencionadamente (ver decision-log).
- `full-infra` se ejecuta siempre que cualquier módulo cambie (output `any-module`).
- `path-consistency` reside únicamente en `pull-request.yml` y verifica que cada
  ruta de configuración referenciada por `cp`/`tee -a` en un doc de módulo exista.
- La validación de Ansible (`ansible-lint`, `--syntax-check`) se añade como un nuevo
  filtro + job dentro de `modules-ci.yml`; los workflows de punto de entrada no se tocan.
- La autenticación de AWS en CI (cuando sea necesaria) utiliza OIDC (`role-to-assume`), nunca
  claves de acceso estáticas.

Ver `continuous-integration.md` para el diseño completo.

---

## Método de Trabajo

1. El autor y el asistente arquitecto definen primero la estructura y las
   decisiones, y las registran en `decision-log.md`.
2. El asistente genera los documentos de implementación (`.md`) siguiendo
   los estándares obligatorios de este archivo.
3. El autor sigue el documento paso a paso sobre infraestructura real,
   aprendiendo mientras lo aplica y reportando cada error encontrado.
4. Los errores se corrigen en el documento, de modo que termine reflejando lo que
   realmente se verificó.

### Delegación al agente de código

Las tareas mecánicas con mínimas decisiones pueden delegarse al agente de código
(Antigravity): scaffolding de carpetas, migración de configs, actualización de enlaces,
incorporación de jobs de CI a partir de un patrón definido. Las decisiones de diseño, documentos
de implementación y justificaciones (`### Why`) permanecen con el autor y el asistente arquitecto.
Todos los prompts e instrucciones para el agente son redactados por el autor y el
asistente — el agente recibe el alcance, archivos objetivo, estándares obligatorios y
criterios de aceptación, y nunca decide la estructura.
