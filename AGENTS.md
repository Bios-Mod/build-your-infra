# build-your-infra — Contexto del Proyecto (Permanente)

**Repo:** github.com/Bios-Mod/build-your-infra
**Rol del asistente:** Senior SysAdmin / Cloud Architect / Cybersecurity Senior
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
- `AGENTS.md`, `decision-log.md` y los planes de implementación en `context/` (hoy, `ansible-implementation.md`) son los únicos documentos de contexto. No existe ningún archivo de estado por iteración: el estado reside en las tablas de módulos y en el log de decisiones.
- Reparto entre documentos: `AGENTS.md` define cómo escribir y trabajar (reglas imperativas); `decision-log.md` registra qué se decidió y por qué.
- El contenido del repositorio (docs de módulos y entornos, README, configs, comentarios en línea, YAML y código) está en inglés. Los documentos internos y de contexto (`AGENTS.md`, `context/decision-log.md` y `context/ansible-implementation.md`) están en español.

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

## Convenciones de Ansible

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
- El doc de implementación de Ansible es `self-managed-automation.md` del stack, con una
  sección por módulo que sigue What was done / Why / Verification, incluyendo
  `--check --diff` y una segunda ejecución con 0 `changed`. Cada rol tiene además un
  `README.md` corto (entradas, tags, destinos y ficheros compartidos).

---

## Convenciones de CI (GitHub Actions)

El diseño está en `continuous-integration.md` y las decisiones en `decision-log.md`.
Reglas al editar el CI:

- Toda validación nueva se añade como filtro + job en `modules-ci.yml`; `push-ci.yml` y
  `pull-request.yml` no se tocan.
- `self-managed`: solo lint estático, sin credenciales. `aws-native`:
  `terraform fmt -check` + `terraform validate`, sin `plan`.
- La validación de Ansible (`ansible-lint`, `--syntax-check`) sigue el mismo patrón.
- La autenticación de AWS en CI usa OIDC (`role-to-assume`), nunca claves estáticas.

---

## Método de Trabajo

1. El autor y el asistente arquitecto definen primero la estructura y las decisiones, y las registran en `decision-log.md`.
2. El asistente genera los documentos de implementación (`.md`) siguiendo los estándares obligatorios de este archivo.
3. El autor sigue el documento paso a paso sobre infraestructura real,
   aprendiendo mientras lo aplica y reportando cada error encontrado.
4. Los errores se corrigen en el documento, de modo que termine reflejando lo que realmente se verificó.

### Delegación al agente de código

Las tareas mecánicas con mínimas decisiones pueden delegarse al agente de código (Antigravity): scaffolding de carpetas, migración de configs, actualización de enlaces, jobs de CI a partir de un patrón definido. Las decisiones de diseño, los documentos de implementación y las justificaciones (`### Why`) permanecen con el autor y el asistente.

- El agente trabaja en feature branches, puede crear y modificar archivos y commitea allí. Nunca hace push a `main` ni merge; el autor revisa y mergea cada pull request.
- Cada tarea indica: alcance de archivos, lectura obligatoria (`AGENTS.md`, `decision-log.md` y, para tareas de Ansible, `context/ansible-implementation.md`), criterios de aceptación y lo que queda fuera de límites.
- El agente ejecuta la estructura definida en `decision-log.md`; nunca la decide.
