# Log de Decisiones

Decisiones técnicas que están cerradas y no deben reabrirse sin solicitud explícita del autor.
Cada tema cuenta con una única entrada vigente. Las reglas de roles, ciclo de trabajo y estándares se rigen por `AGENTS.md`.

---

## Infraestructura y Entorno

- **Single AZ en multi-lab-vpc:** Coste frente a valor de aprendizaje evaluado y descartado. Una segunda AZ requiere un segundo NAT Gateway y costes de transferencia de datos entre AZs con cero valor de aprendizaje adicional para este laboratorio.
- **Regla del puerto 22 en multi-lab-sg:** Se elimina durante el Step 3 de hardening (no en setup de VPS). El doc de setup la referencia como temporal apuntando a hardening.
- **`apt update` en Step 1:** Corresponde al Step 1 de hardening, no a los documentos de setup de entorno, los cuales finalizan tras verificar la primera conexión SSH.

---

## AWS Native

- **Resolución DNS (`enableDnsSupport`):** Habilitada explícitamente en `multi-lab-vpc`. Requerida para SSM Session Manager y Route 53 Private Hosted Zones.
- **`AdministratorAccess` en `multi-lab-admin`:** Intencionado para la cuenta del operador del laboratorio. La reducción de privilegios (scope-down) aplica a los roles de servicio por módulo, no al operador.
- **MFA Delete opcional en CloudTrail S3:** Requiere credenciales de cuenta root (no IAM). Se documenta como opcional.
- **CloudTrail multi-región:** Intencionado para capturar eventos globales de IAM/STS que un trail mono-región perdería.
- **Aplicación de IMDSv2:** Laboratorio de una sola instancia EC2; la llamada de AWS CLI apunta a la instancia explícitamente sin necesidad de bucle.

---

## Hardening Self-Managed

- **`USERGROUPS_ENAB=no` en PAM:** El hallazgo AUTH-9328 de Lynis no aplica al no emplearse grupos privados por usuario. Documentado como desviación justificada en `custom.prf`.
- **Diferencia de puntuación Lynis (EC2 90 vs VM 88):** La mayor puntuación en EC2 se debe a controles inherentes de la plataforma AWS, no a configuraciones adicionales. No implica divergencia en los procedimientos de hardening.
- **Códigos de retorno en `rkhunter --update`:** Se aceptan códigos `[0, 1, 2]`. El código `2` indica actualización satisfactoria de ficheros de firmas (`[ Updated ]`), por lo que no constituye un error de ejecución.
- **Parada de demonios snapd antes de limpiar su estado en migraciones (EC2):** En la migración de `amazon-ssm-agent` de snap a deb, si `dpkg -i` se bloquea por estado previo, el demonio en memoria retiene el bloqueo. Se deben detener `snap.amazon-ssm-agent.amazon-ssm-agent.service`, `snapd.service` y `snapd.socket` antes de eliminar `/var/lib/snapd`.
- **Gestión de contraseñas y expiración (Step 9.2):** Se automatiza `chage -M 90 -m 1 -W 14` para el admin y los usuarios nuevos se crean con 65536 rondas SHA512. Se omite la fecha de expiración de cuenta (`chage -E`) para evitar bloqueos irreversibles, en coherencia con la supresión de AUTH-9282.
- **Tabla de Lynis del Step 12 alineada con `custom.prf`:** Se añade AUTH-9282 como desviación justificada y se retira NAME-4404 para reflejar con exactitud las reglas activas en el perfil de Lynis.

---

## Alcance del Repositorio

- **DHCP sin equivalente en AWS Native:** VPC DHCP Options Sets es una configuración de red, no un servicio gestionable. Tratado únicamente en el README del módulo DHCP.
- **DNS interno de Samba 4 AD DC:** Puede reemplazar o integrarse con BIND9; el módulo DNS debe revisarse antes de desplegar el módulo de directorio.
- **Supresión de badges y columnas de estado en docs:** El estado en tablas de READMEs queda obsoleto rápidamente; el estado real reside en git y en las tablas de módulos.
- **Topología DNS self-managed:** BIND9 se ejecuta exclusivamente en el hub EC2 (`172.16.0.1`); la VM local actúa como cliente peer y resuelve consultas reenviadas a través del túnel WireGuard.
- **Idioma del repositorio:** Contenido técnico (docs, configs, código, YAML, commits y comentarios) en inglés; documentación interna de contexto (`AGENTS.md`, `context/decision-log.md`, `context/ansible-implementation.md`) en español.
- **`snapshots/README.md` como registro documental:** Describe el estado histórico de los despliegues manuales; la automatización con Ansible y Terraform no depende de snapshots ni AMIs previas.
- **Cierre del repositorio:** El repositorio se cierra al completar la automatización de Ansible en todos los módulos self-managed y desplegar la monitorización (Prometheus + Grafana). El diagrama de arquitectura global se elaborará al cierre frente al stack definitivo.

---

## Nomenclatura y Convenciones de Configuración

- **Nomenclatura `<module>-<environment>.md`:** Ficheros nombrados unívocamente (p. ej. `dns-self-managed.md`, `dns-aws-native.md`) para evitar ambigüedades fuera de su carpeta, alineándose con los docs de automatización.
- **Comprobación de sintaxis de comentarios:** Identificar el tipo de archivo y su delimitador nativo antes de escribir cabeceras o comentarios; no asumir delimitadores `#` ni `//` en archivos que no los toleran.
- **Método de aplicación de configuraciones:** `cp` para reemplazo completo y `tee -a` para anexar bloques aditivos precedidos por el separador `── <MODULE> — <service description> ──`. Prohibido el uso de heredocs en el cuerpo del paso.
- **Indexación de arrays en AWS CLI (JMESPath):** Las respuestas `describe-*` devuelven arrays en el nodo raíz. Usar siempre `ResourceType[0].Field` (o `[*]` en consultas múltiples); nunca `ResourceType.Field`.

---

## Automatización — Decisiones de Terraform

- **Composición modular vs full-stack:** En `aws-native`, coexisten módulos individuales y stack compuesto. En `self-managed`, la automatización existe únicamente a nivel de stack (`stacks/full-infra/self-managed/automation/`).
- **Despliegue greenfield en self-managed:** El stack de Terraform self-managed lanza una instancia base Ubuntu Server 24.04 LTS ARM64 limpia (vía variable `ami_id`), configurando VPC, subredes, perfil IAM `multi-lab-ec2-role` con SSM, IMDSv2 obligatorio y Security Group con apertura condicional de bootstrap SSH (`ssh_bootstrap_cidr`) y puerto endurecido (`ssh_hardened_cidr`). La configuración de servicios del sistema operativo se delega íntegramente a Ansible.
- **Orden de despliegue en `aws-native`:** hardening → dns → file-transfer → web-server → directory (de menor a mayor complejidad y coste).
- **Resolución de dependencias en Terraform:** En full-stack greenfield `aws-native`, se utiliza apply en dos fases (`-target=module.hardening` primero) porque `dns` y `file_transfer` consultan la VPC vía `data "aws_vpc"` en tiempo de plan.
- **Rutas y valores dinámicos:** Variables como `html_dir` en web-server se resuelven relativas al directorio de ejecución; `create_ec2_record` en DNS es opcional y deshabilitado por defecto en aws-native.

---

## Automatización — Decisiones de Ansible

- **Alcance y ubicación:** Aplica únicamente a `self-managed` a nivel de stack (`stacks/full-infra/self-managed/automation/ansible/`), reproduciendo con precisión el alcance de los despliegues manuales (VM y EC2 para hardening, file-transfer, web-server; solo EC2 para dns y directory; solo VM para dhcp).
- **Estructura de documentación (`self-managed-automation.md`):** Organizado en secciones por módulo con steps locales (máximo 4 por sección; hardening cuenta con 4 steps: Baseline, Access chain, System hardening, Verify; los demás módulos cuentan con 2: Apply y Verify). Comandos unificados en tablas por destino (`Target | --limit | host_vars | Command | Expected`) y verificaciones enlazadas al manual sin duplicación de comandos.
- **Fuente de verdad de configs y variables:** Los roles leen los archivos de `modules/<module>/self-managed/configs/` desde el nodo de control (`configs_root`) y sustituyen placeholders mediante `ansible.builtin.copy` con `content` y `validate:`. Nunca se emplean `template` sobre copias dentro del rol.
- **Partida greenfield y desarrollo incremental:** Los módulos se desarrollan incrementalmente sobre la misma máquina. La reconstrucción completa desde cero de ambos entornos se aplaza a la Fase 9 para validar el aprovisionamiento de extremo a extremo sin duplicar esfuerzo en fases intermedias. Puntos de retorno: snapshot local en la VM antes del bloque de acceso; en EC2, relanzamiento completo vía Terraform y Ansible.
- **Topología y configuración de WireGuard:** EC2 actúa como hub (`172.16.0.1`) y la VM como peer (`172.16.0.3`). La clave privada del servidor se genera en el host con `creates:` y `no_log: true`. En la VM cliente, `wireguard_endpoint` es obligatorio en `host_vars/multi-lab-local.yml` apuntando explícitamente a la IP pública y puerto del hub EC2 (`<ec2_eip>:51820`), eliminando cualquier valor por defecto a la IP local para evitar fallos de handshake.
- **Gestión de accesos y transición SSH:** Transición por modos (`pre` en puerto 22, `hardened` en puerto 22222 por IP pública/LAN, y `wg` en puerto 22222 por la interfaz `wg0`). La desconexión y reconexión en Step 3 se aísla en `step_03_ssh_transition.yml` (evitando que `meta: reset_connection` se ejecute incondicionalmente en cada pasada). El cierre del acceso SSH público en EC2 se controla con `hardening_wg_close_public_ssh: true`; la VM mantiene el puerto 22222 accesible en LAN como vía de recuperación.
- **Idempotencia de cortafuegos UFW:** En `step_04_ufw.yml`, la regla `limit 22222/tcp` se condiciona con `when: not hardening_wg_close_public_ssh` para evitar que el Step 4 la recree y el Step 5 la elimine en cada pasada sobre EC2.
- **Auditd `-e 2` y precedencia:** En desarrollo, `hardening_auditd_immutable_mode: false` en `group_vars/vm.yml` permite recargar reglas sin reiniciar el kernel; para producción o reconstrucción limpia se sobreescribe con `true` en `host_vars`. Al desplegar `99-hardening.rules`, se fuerza un salto de línea final (`\n`) para evitar que `augenrules` concatene directivas con comentarios del kernel.
- **Robustez del nodo de control y playbooks:** Se fijan versiones en `requirements.txt` (ansible-core 2.21.6, ansible-lint 26.10.1, Python 3.12–3.14). Se configura `timeout = 30` en `ansible.cfg` para evitar fallos en prompts de escalada; `module_defaults` con `ansible.builtin.apt: { lock_timeout: 600 }` en playbooks frente a bloqueos de `unattended-upgrades`; y aserción pre-flight de versiones en `playbooks/*.yml`.
- **Desviaciones aceptadas:**
  1. `/var/log/fail2ban.log`: Se pre-crea con `syslog:adm` en Step 11; Fail2Ban escribe como root y logrotate fuerza `0640 root adm`, tolerándose 1 `changed` tras la primera rotación.
  2. Retención de bloqueo dpkg tras arranque: Mitigado operativamente mediante `lock_timeout: 600` en las tareas de apt.
- **Documentos de trabajo:** `ANALYSIS.md` permanece en `automation/ansible/` como referencia interna durante el desarrollo y se eliminará en la Fase 9 tras absorber su contenido en la documentación.

---

## Implementación de CI (GitHub Actions)

- **Workflow reutilizable único (`modules-ci.yml`):** Define centralizadamente todas las reglas de validación invocadas vía `workflow_call` desde `push-ci.yml` (en `main`) y `pull-request.yml` (en PRs hacia `main`). Evita duplicar lógica de CI.
- **Filtrado selectivo con `dorny/paths-filter`:** El job `changes` evalúa las rutas modificadas y expone salidas booleanas por módulo y capa. Cada job de validación se ejecuta condicionalmente (`if: needs.changes.outputs.<name> == 'true'`), omitiendo los que no fueron modificados.
- **Exclusión de `terraform plan` y backend local:** Al no haber infraestructura cloud persistente por costes, CI se limita a `terraform fmt -check` y `terraform validate` sin credenciales de AWS ni estado remoto.
- **Validación estática de Ansible en CI (`ansible-self-managed`):** Se ejecuta en runner `ubuntu-24.04-arm` ante cambios en `stacks/.../ansible/**`. Configura Python 3.12 (`actions/setup-python@v5`), instala dependencias y colecciones, genera inventario efímero desde `hosts.yml.example`, ejecuta `ansible-lint --profile production` y valida la sintaxis de todos los playbooks mediante un bucle dinámico sobre `playbooks/*.yml`. La ejecución contra hosts (`--check` o real) permanece como paso manual.
- **Gobernanza de Pull Requests (`path-consistency`):** Se ejecuta de forma incondicional en PRs para verificar que toda ruta de fichero de configuración referenciada en la documentación exista físicamente en el repositorio.

---

## Gobernanza y Método de Trabajo

- **Gobernanza centralizada en `AGENTS.md` (2026-11-06):** Todas las normas operativas, definición de roles, formato de prompts delta y convenciones técnicas se consolidan en `AGENTS.md`, eliminando duplicidades y reglas dispersas.
- **Mantenimiento del log de decisiones (2026-11-06):** Cada tema tiene una única entrada vigente en este documento. Una decisión que sustituye a otra elimina la anterior sin anotaciones de "sustituido por" ni histórico acumulativo.
- **Lectura de contexto por hash (2026-11-06):** El agente de código calcula `git log -1 --format=%h -- AGENTS.md context/` y solo relee los documentos de contexto si el hash difiere del registrado en su informe anterior o si el prompt lo solicita.
- **Acceso de solo lectura del asistente (2026-11-06):** El asistente arquitecto opera con permisos de solo lectura sobre GitHub (vía conector), verificando mediante diffs e inspección de archivos sin capacidad de modificación directa.
- **AGENTS.md estructurado en un solo documento por roles (2026-11-06):** Se consolida toda la gobernanza técnica y procedimental en un único fichero `AGENTS.md` organizado por roles y convenciones técnicas, eliminando redundancias y dispersión.
