# Ansible — Plan de implementación (definitivo)

**Repo:** build-your-infra · **Alcance:** automatizar **exactamente lo que ya está hecho a mano** en `self-managed`, en cada destino donde se aplicó (VM local y/o EC2). Monitorización (Prometheus + Grafana) queda fuera de este plan.
**Idioma:** este plan es interno (español). Todo lo que se escriba en el repo (docs de módulos y entornos, README, configs, YAML, comentarios) va en inglés. `AGENTS.md`, `decision-log.md` y este plan están en español.
**Decisiones:** cerradas y registradas en `decision-log.md` (sección "Decisiones de Ansible"). Este plan no las reabre.
**Fuente de la matriz:** `snapshots/README.md` (registro documental de lo desplegado a mano).

---

## 0. Reparto de trabajo

| Quién | Qué hace |
| --- | --- |
| Autor | Ejecuta manualmente cada paso de los `.md` en la VM y en EC2, reporta errores y aprende. Revisa y mergea los PR. |
| Asistente (arquitecto) | Genera los `.md` de implementación y los prompts del agente. Corrige los docs con los errores reportados. |
| Agente Flash (Antigravity) | Trabaja en ramas, hace commits y abre PR. Ejecuta tareas mecánicas: scaffolding, roles, tareas y handlers con comentarios, jobs de CI, enlaces. Ejecuta la estructura del decision-log; no la decide. Nunca hace push a `main` ni merge. |

Ciclo por módulo: **rol + sección del doc → ejecución manual en cada destino donde aplica → errores al doc → hito por destino → siguiente módulo.**

---

## 1. Decisiones aplicadas (resumen)

| Tema | Decisión |
| --- | --- |
| Alcance | Se automatiza lo ya aplicado a mano, por destino (sección 4). Sin funcionalidad nueva; las limitaciones conocidas se reproducen. |
| Nivel | Ansible solo a nivel de stack, como el Terraform de self-managed. Los módulos self-managed no tienen carpeta `automation/`. |
| Ubicación | Todo en `stacks/full-infra/self-managed/automation/ansible/`: `ansible.cfg`, `requirements.txt`, `inventories/`, `playbooks/`, `roles/<module>/`. |
| Roles | Un rol por módulo, con `tasks/`, `handlers/`, `defaults/`, `templates/`, `meta/` y un `README.md` corto. Un rol sirve a ambos destinos. |
| Doc | `self-managed-automation.md` del stack, con una sección por módulo (What was done / Why / Verification). |
| Selección de módulos | Grupos de inventario + tags. Hardening siempre primero; cada módulo comprueba que hardening está aplicado. |
| Fuente de configs | `configs/` de cada módulo; los roles las leen desde el nodo de control (`configs_root`) y sustituyen placeholders con variables de inventario. |
| Nodo de control | Mac, Ansible nativo en `venv`, versiones fijadas en `requirements.txt`. |
| Partida | Desde cero en ambos entornos, sin depender de snapshots ni AMIs. VM nueva con `local-vm-setup.md`; EC2 lanzada por Terraform desde Ubuntu 24.04 ARM64 base, pasando su AMI en la variable `ami_id` existente. El acceso SSH inicial se abre con una variable de Terraform (CIDR de bootstrap). |
| Desarrollo | Incremental: un módulo por fase sobre el mismo host. Reconstrucción completa desde cero al cerrar hardening y en el cierre. |
| Orden | hardening → file-transfer → dns → web-server → directory → dhcp. |
| Pruebas | `ansible-lint` + `--syntax-check` en CI; `--check --diff` y 0 `changed` en la segunda pasada; verificaciones del módulo; Lynis ≥ 88 (VM) / ≥ 90 (EC2). Sin Molecule. |
| Privilegios y secretos | `--ask-become-pass`; sin secretos en el repo; claves de WireGuard solo en su host. |
| Fuera de Ansible | Security Groups y SSM. |
| VM actual | Intacta y apagada hasta cerrar Ansible y pasar a monitorización. |

---

## 2. Estándar de ficheros Ansible

Reglas completas en `AGENTS.md` ("Convenciones de Ansible"). Cabecera de cada fichero YAML (en inglés):

```yaml
# Deploy to:   <host group>
# Apply:       ansible-playbook playbooks/<file>.yml --tags <tag> [--check --diff]
# Module:      <module>
# Requires:    <rol/bloque previo, o "none">
#
# <one-line description>
# Why:         <motivo breve; el detalle va en el .md>
# Doc ref:     <module>-self-managed.md — Step N
# Targets:     <vm | ec2 | both>
```

Cada tarea lleva un comentario con qué hace, por qué y a qué Step corresponde. Las tareas con riesgo de lockout llevan `# WARNING:`. Las diferencias VM/EC2 llevan `# VM only` / `# EC2 only`.

---

## 3. Layout objetivo

```
modules/<m>/self-managed/
├── configs/                                  (fuente única, sin cambios)
└── <m>-self-managed.md                       (flujo manual, especificación del estado deseado)

stacks/full-infra/self-managed/automation/
├── self-managed-automation.md                (una sección por módulo)
├── terraform/                                (existente; la variable de AMI se añade en Fase 1)
└── ansible/
    ├── ansible.cfg
    ├── requirements.txt
    ├── requirements.yml
    ├── inventories/
    │   ├── hosts.yml.example                 (grupos vm / ec2 + grupos por módulo; sin IPs reales)
    │   └── group_vars/ · host_vars/
    ├── playbooks/
    │   ├── bootstrap.yml                     (Step 0, puerto 22)
    │   ├── site.yml                          (importa módulos con tags)
    │   └── <module>.yml
    └── roles/<module>/
        ├── README.md                         (inputs, tags, requisitos, ficheros compartidos, destinos)
        ├── defaults/main.yml
        ├── tasks/main.yml
        ├── handlers/main.yml
        ├── templates/                        (solo si la sustitución de placeholders no basta)
        └── meta/main.yml
```

Ficheros con IPs, usuarios o rutas reales llevan su pareja `*.example`, y el real va en `.gitignore`.

---

## 4. Matriz, puntos de partida y diferencias

### 4.1 Qué se automatiza y dónde

| Módulo | VM local | EC2 | Diferencias que el rol respeta |
| --- | --- | --- | --- |
| hardening | Sí (Lynis 88) | Sí (Lynis 90) | Step 2 (Netplan) solo VM; Step 3.1 (SSM) fuera de Ansible; cloud-init solo EC2 |
| file-transfer (SFTP) | Sí | Sí | Comparte `sshd_config` con hardening |
| dns (BIND9) | No | Sí (hub, `lab.internal`) | Netplan overlay para coexistir con el DNS de la VPC |
| web-server (Nginx) | Sí | Sí | VM: autofirmado. EC2: Let's Encrypt vía Certbot (`tls_mode`) |
| directory (Samba 4 AD DC) | No | Sí (`multilab.internal`) | DNS `SAMBA_INTERNAL`; Kerberos verificado; SMB2 bloqueado por bug de Samba 4.19.5 en aarch64 (fuera de alcance) |
| dhcp (Kea) | Sí (`192.168.1.0/24`, pool `.100–.200`, reserva por MAC, opción DNS `172.16.0.1`) | No | Solo local |

Grupos de inventario: `vm`, `ec2`, `dns_servers` (EC2), `directory_servers` (EC2), `dhcp_servers` (VM). Los módulos comunes se aplican a `vm:ec2`.

### 4.2 Puntos de partida (desde cero)

| Destino | Cómo se parte | Punto de retorno |
| --- | --- | --- |
| VM | VM nueva creada siguiendo `environments/local/local-vm-setup.md` (el doc termina en la primera conexión SSH). | Snapshot local de seguridad antes del bloque 2B. No es una dependencia. |
| EC2 | Terraform (`stacks/full-infra/self-managed/`) lanza Ubuntu 24.04 ARM64 base pasando su AMI en `ami_id`. Una variable de bootstrap abre el puerto 22 en el security group solo mientras hace falta. | Terminar la instancia y relanzar. Opcional: un único AMI `multi-lab-aws-ansible-hardening` tras hardening, solo por comodidad. |

La VM actual (con sus snapshots `sftp`, `web-server`, `dhcp`) se conserva intacta y apagada hasta cerrar Ansible. No se usa para nada del plan.

`snapshots/README.md` es un registro documental: sus columnas `State` no implican que el snapshot/AMI exista hoy.

### 4.3 Coste en EC2

Sin AMIs, el gasto es el de la instancia mientras esté encendida y el del volumen EBS mientras exista. La instancia se apaga entre sesiones y se destruye en el cierre (Fase 9), tras la reconstrucción final.

### 4.4 Diferencias VM / EC2 y su gestión

| Diferencia | Gestión |
| --- | --- |
| Netplan (Step 2) | `when: not is_cloud` |
| cloud-init puede reescribir red y claves | `when: is_cloud` |
| SSM (3.1) | Fuera de Ansible |
| Security Group (quitar puerto 22, abrir `51820/udp`) | Fuera de Ansible (Terraform/consola); paso manual previo en cada hito EC2 |
| TLS | `tls_mode: self_signed` (VM) / `letsencrypt` (EC2). Certbot con `creates:` y entorno `staging` en los ensayos para no agotar los límites de emisión |
| Rango de WireGuard | `172.16.0.0/24` en ambos |
| Conexión inicial | EC2: `ubuntu` + Elastic IP; VM: usuario del instalador + IP de la LAN. Tras 2B: IP de `wg0`, puerto 22222 (variable `connection_mode` pre/post por host) |

---

## 5. Fases e hitos

Cada hito es una **puerta**: no se pasa a la siguiente fase sin cumplirlo.

### Fase 0 — Alineación de contexto

- **Entregables:** `AGENTS.md`, `decision-log.md` y este plan en `context/`; eliminación de las carpetas `automation/` de los módulos self-managed y de sus referencias; ajustes en README raíz, `continuous-integration.md` y `stacks/full-infra/README.md` (incluido su enlace roto a `self-managed-automation.md`).
- **Hito:** PR mergeado y CI en verde.

### Fase 1 — Análisis de hardening + scaffolding

- **Entregables (agente):**
  - `ANALYSIS.md` de hardening: pasos (archivos, método de aplicación, clasificación automatizable/manual/riesgo de lockout), módulo Ansible candidato, handlers, orden, dependencias y diferencias VM/EC2. Mapeo definitivo de los pasos 6–12 y de los placeholders de `configs/`.
  - `ansible.cfg`, `requirements.txt`, `requirements.yml`, `hosts.yml.example` (grupos de 4.1), `group_vars` comentados, `playbooks/ping.yml`, esqueleto del rol `hardening`.
- **Pasos manuales (autor):** crear la VM nueva con `local-vm-setup.md`; `venv` en el Mac; copiar `hosts.yml.example` a `hosts.yml`; `ansible all -m ping`.
- **Hito:** versiones de Ansible = `requirements.txt`; `ping` correcto en la VM; `ansible-lint` y `--syntax-check` pasan; preguntas abiertas de `ANALYSIS.md` resueltas y registradas.

### Fase 2 — Hardening

**2A — Preparación (VM, bajo riesgo)**

- Alcance: Step 0 (usuario admin, `bootstrap.yml`, puerto 22), Step 1 (updates + unattended-upgrades + debsums), Step 2 (Netplan, solo VM).
- **Hito 2A:** `--check --diff` revisado; ejecución real; 0 `changed` en la segunda pasada; verificaciones de Step 1–2.

**2B — Cadena de acceso (VM, alto riesgo de lockout)**

- Alcance: Step 3 (SSH 22 → 22222), Step 4 (UFW), Step 5 (WireGuard + `ufw route`), y Fail2Ban (Step 6).
- Antes de empezar: snapshot local de seguridad de la VM.
- Puntos críticos:
  - La conexión cambia de puerto e IP (LAN → `wg0`): `validate: sshd -t`, `meta: flush_handlers`, `meta: reset_connection` + `wait_for_connection`, y cambio de `connection_mode`.
  - UFW: abrir `51820/udp` y la regla por `wg0` **antes** de borrar `limit 22222/tcp`.
  - Túnel del Mac activo y segunda sesión abierta.
- **Hito 2B:** sin pérdida de acceso; verificaciones de Step 3–5 (`sshd -T`, `ufw status verbose`, `wg show`); el acceso persiste tras reiniciar; 0 `changed`.

**2C — Resto de capas (VM, pasos 6–12)**

- Alcance provisional: sysctl, AppArmor, superficie, auditd, rsyslog, AIDE, Lynis. Definitivo en `ANALYSIS.md`.
- A confirmar: auditd con reglas inmutables (`-e 2`) y su efecto en la idempotencia; AIDE se inicializa una vez (`creates:`); orden entre `/etc/ufw/sysctl.conf` y `/etc/sysctl.d/`.
- **Hito 2C:** Lynis ≥ **88**; 0 `changed`; **reconstrucción desde cero** de la VM solo con `bootstrap.yml` + el rol hardening.

**2D — Hardening en EC2**

- **Preparación de Terraform (agente, antes de lanzar la instancia):** actualizar la descripción de `ami_id` en `variables.tf`; añadir una variable de CIDR de bootstrap SSH que habilite de forma condicional el ingreso al puerto 22 en `multi-lab-sg` (vacía = cerrado); actualizar `main.tf.example` y `terraform.tfvars.example`; documentar en `self-managed-automation.md` la ruta greenfield (sin ciclo de import).
- **Pasos manuales previos (autor, fuera de Ansible):** lanzar la instancia con Terraform desde Ubuntu base con el CIDR de bootstrap definido; `51820/udp` ya abierto por el stack; tras el bloque 2B, vaciar la variable y aplicar de nuevo para cerrar el puerto 22.
- **Hito 2D:** puertas 2A–2C superadas en EC2; Lynis ≥ **90**.

### Fase 3 — Ansible en el CI

- **Entregables (agente):** un único filtro y un job en `modules-ci.yml` sobre `stacks/full-infra/self-managed/automation/ansible/**` (`ansible-lint` + `--syntax-check`); no se tocan `push-ci.yml` ni `pull-request.yml`. Actualizar `continuous-integration.md`.
- **Hito:** un PR de prueba que modifica solo el rol de hardening dispara el job de Ansible y pasa; un error de sintaxis deliberado lo hace fallar; se revierte.

### Fases 4–8 — Módulos

Todos requieren hardening. Cada módulo se añade sobre el mismo host: rol → sección del doc → ejecución → **hito por cada destino donde aplica**.

| Fase | Módulo | Destinos | Puntos críticos | Hito específico (además del estándar) |
| --- | --- | --- | --- | --- |
| 4 | file-transfer | VM + EC2 | Bloque `Match Group` en `sshd_config`, usuarios y chroot; comparte fichero con hardening: `blockinfile` con marcador propio o drop-in | Login SFTP enjaulado; SSH de administración intacto; 0 `changed` en `sshd_config` |
| 5 | dns | EC2 | Netplan overlay con el DNS de la VPC; `validate:` con `named-checkconf`/`named-checkzone`; zonas con `;`; regla UFW 53 | `dig` resuelve `lab.internal` en EC2 y desde la VM por el túnel (`172.16.0.1`) |
| 6 | web-server | VM + EC2 | `tls_mode`; plantillas de vhost/proxy (`<upstream_port>`); `validate: nginx -t`; Certbot con `creates:` y `staging` en ensayos | VM: `curl -k` OK. EC2: certificado válido emitido y renovación probada con `--dry-run` |
| 7 | directory | EC2 | `samba-tool domain provision` no es idempotente: `creates:`; `SAMBA_INTERNAL` frente a BIND9 (revisar el módulo DNS); limitación SMB2 documentada | `samba-tool domain level show`, `testparm -s`, `kinit` y `_ldap._tcp` OK; 0 `changed` sin reprovisionar |
| 8 | dhcp | VM | Interfaz como variable de host (el CI usa `ens160` ficticia); opción DNS `172.16.0.1` | `kea-dhcp4 -t` OK; `nmap --script broadcast-dhcp-discover` entrega las opciones correctas |

La instancia EC2 se mantiene entre las fases 4 y 7 (apagada entre sesiones).

### Fase 9 — Orquestación y cierre

- **Entregables:** `site.yml` con tags; `self-managed-automation.md` completo; README raíz (quitar "in progress" y dejar la tabla de Automation definitiva), `continuous-integration.md` y decision-log; enlaces desde cada README de módulo; eliminar `ANALYSIS.md`.
- **Pasos manuales (autor):**
  1. Reconstrucción completa de la VM desde cero: `bootstrap.yml` + `site.yml` (módulos de la VM); luego `site.yml` por segunda vez.
  2. Reconstrucción completa de EC2 desde Ubuntu base con Terraform (módulos de EC2); segunda ejecución. Destruir la infraestructura al terminar.
- **Hito de cierre:** reconstrucciones sin intervención manual fuera de lo documentado; 0 `changed` en la segunda ejecución en ambos destinos; CI en verde; README sin "in progress" para Ansible.

---

## 6. Ciclo de verificación estándar

1. `ansible-lint` + `--syntax-check` sin errores.
2. `--check --diff`: revisar el diff.
3. Ejecución real, con segunda sesión SSH en bloques de riesgo.
4. Segunda ejecución: **0 `changed`**.
5. Verificaciones del `.md` manual del módulo (comandos con `# →`).
6. Fallos: se corrigen en el rol o, si el doc no refleja la realidad, en el doc (Método de Trabajo), y se registran con su causa en `self-managed-automation.md`.

---

## 7. Riesgos transversales

| Riesgo | Mitigación |
| --- | --- |
| Lockout al cambiar SSH/UFW/WireGuard | Bloque 2B con snapshot local, `validate:`, reconexión explícita, túnel activo y segunda sesión. UFW: abrir antes de cerrar. |
| Cambio de IP y puerto durante la ejecución | `connection_mode` pre/post por host y cambio de inventario documentado. |
| Contraseña de sudo | `--ask-become-pass`. |
| Recursos AWS fuera de Ansible (Security Group) | Paso manual previo en cada hito EC2. |
| Sin oráculo: el doc manual puede no reflejar el estado real | El doc es la especificación; los fallos se corrigen en el doc o en el rol y se registran. |
| | El stack de Terraform self-managed no abre el puerto 22 y apunta a un AMI inexistente | `ami_id` ya es variable; en 2D se añade el CIDR de bootstrap SSH condicional. |
| Límites de emisión de Let's Encrypt | `staging` en ensayos; emisión real una vez por entorno. |
| Samba 4.19.5 en aarch64 | Se reproduce el estado documentado; SMB2 fuera de alcance. |
| Ficheros compartidos entre roles (`sshd_config`) | Un rol dueño del fichero; el resto usa drop-ins o bloques con marcador propio. |
| Coste de EC2 | Apagar entre sesiones; destruir en el cierre. |
| Secretos en el repo | Sin claves, contraseñas ni IPs reales; pares `*.example` y `.gitignore`. |
| Afirmar en el README algo que aún no existe | Redacción "in progress" hasta el hito de cierre. |

---

## 8. Fuera de alcance

- Monitorización (Prometheus + Grafana).
- `aws-native` (no hay SO que configurar).
- Ansible en `containerize-your-infra`.
- Molecule, Vault y AWX/Tower.
- Diagramas de arquitectura (al final, una vez).
- Recursos AWS (VPC, SG, instancias): los cubre Terraform.
- Funcionalidad que no esté ya aplicada y verificada a mano.
