# Log de Decisiones

Decisiones técnicas que están cerradas y no deben reabrirse sin solicitud explícita del autor.

---

## Infraestructura y Entorno

- **Single AZ en multi-lab-vpc** — coste frente a valor de aprendizaje evaluado y
  descartado. Una segunda AZ requiere un segundo NAT Gateway y costes de transferencia
  de datos entre AZs con cero valor de aprendizaje adicional para el alcance de este laboratorio.
- **Regla del puerto 22 en multi-lab-sg** se elimina durante el Step 3 de hardening — no
  en vps-ec2-setup. El doc de setup la referencia como temporal con una nota
  que apunta a hardening. No moverla a setup.
- **apt update** corresponde al Step 1 de hardening, no a los docs de setup de entorno.
  Los docs de entorno finalizan con la primera conexión SSH exitosa.

---

## AWS Native

- **Resolución DNS (enableDnsSupport)** está explícitamente habilitada en multi-lab-vpc.
  Requerida para SSM Session Manager y Route 53 Private Hosted Zones.
- **AdministratorAccess en multi-lab-admin** es intencionado para la cuenta del
  operador del laboratorio. La reducción de privilegios (scope-down) aplica a los roles de servicio por módulo, no al
  operador.
- **MFA Delete en el bucket S3 de CloudTrail** es opcional — requiere la cuenta
  root, no un usuario IAM cualquiera. No marcarlo como obligatorio.
- **CloudTrail all-regions** es intencionado — captura eventos globales de IAM/STS que
  un trail de una sola región pierde.
- **Aplicación de IMDSv2** — laboratorio de una sola instancia, la CLI apunta a una instancia
  explícitamente. No se requiere bucle.

---

## Hardening Self-Managed

- **USERGROUPS_ENAB=no en PAM** — el hallazgo AUTH-9328 de Lynis no aplica
  cuando no hay grupo privado. Documentado como una desviación en custom.prf.
- **Puntuación de Lynis EC2 > VM (90 frente a 88)** — se debe a controles de la plataforma AWS, no a
  pasos manuales adicionales. No implica procedimientos de hardening diferentes.

---

## Alcance del Repositorio

- **DHCP no tiene equivalente en AWS Native** — VPC DHCP Options Sets no es un
  módulo desplegable. Tratado únicamente en el README del módulo DHCP.
- **DNS interno de Samba 4 AD DC** puede reemplazar o integrarse con BIND9. El
  módulo de DNS debe revisarse antes de aprovisionar el módulo de directorio.
- **Columnas de estado/badges eliminados de todos los READMEs y docs de módulos.**
  El estado queda desactualizado de inmediato y no es de confianza.
- **DNS desplegado solo en EC2 — la VM local es un cliente peer.** BIND9 se ejecuta solo
  en el hub de WireGuard en EC2; la VM local resuelve mediante `172.16.0.1` a través del túnel.
- **Idioma del repositorio (2026-11-03)** — El contenido del repositorio (docs de módulos y entornos, README, configs, comentarios en línea, YAML y código) está en inglés. Los documentos internos y de contexto (`AGENTS.md` y `context/decision-log.md`) están en español.

---

## Nomenclatura de Documentación (2026-07-10)

- **Documentos de implementación renombrados de `self-managed.md`/`aws-native.md` a
  `<module>-<environment>.md`** (p. ej. `dns-self-managed.md`). Los nombres simples
  eran ambiguos una vez abiertos fuera de su carpeta — cada módulo repetía los
  mismos dos nombres de archivo. Esto se alinea con la nomenclatura ya utilizada para los docs
  de automatización (`<module>-aws-native-automation.md`). El renombrado se realizó mediante `git mv`
  para preservar el historial de los archivos. Todos los enlaces internos (READMEs de módulo, README raíz,
  referencias cruzadas entre docs) se actualizaron en el mismo commit por módulo.

---

## Generación de Configuración

- **Comprobación de sintaxis de comentarios antes de cualquier config** — identificar el tipo de archivo y la
  sintaxis nativa de comentarios antes de escribir. Nunca asumir que `#` o `//` aplica a archivos
  que no soportan comentarios en línea (zonas de BIND9, texto plano servido
  literalmente). No negociable, comprobado antes de escribir la primera línea.
- **Método de aplicación de config** — `cp` para reemplazo completo de archivo, `tee -a` para
  anexar. Nunca en línea mediante heredoc. La referencia `📄 configs/filename` en
  el paso debe coincidir siempre con el archivo utilizado en el comando de aplicación.

## Consultas AWS CLI — Indexación de Arrays con JMESPath

- **Todas las respuestas de `describe-*` devuelven arrays en el nivel superior.**
  `.{key:value}` en el nodo raíz devuelve `null` — indexar siempre primero.
- **Patrón obligatorio:** `ResourceType[0].Field` — nunca `ResourceType.Field`.
- **Las consultas de múltiples resultados** utilizan `[*]`; las verificaciones de un solo recurso siempre
  utilizan `[0]`.

---

## Fase de Automatización — Decisiones de Terraform

- **Los módulos individuales + full-stack son ambos obligatorios.** Un full-stack
  sin módulos individuales es una caja negra; un módulo sin un full-stack
  no demuestra composición.
- **`stacks/full-infra/self-managed/`** despliega EC2 desde el snapshot de la AMI
  (`multi-lab-aws-active-directory`) — capa de infraestructura únicamente. La
  configuración del SO se aplicó manualmente y se documentó por módulo. Ansible
  cerrará esta brecha; este es el patrón correcto (no forzar Terraform donde no
  corresponde).
- **Orden de implementación de módulos (aws-native):** hardening → dns → file-transfer → web-server → directory. De menor a mayor complejidad;
  `directory` al final debido al coste de facturación y ~30 min de tiempo de aprovisionamiento.
- **`stacks/` en la raíz del repo** — coherencia estructural con
  `containerize-your-infra`, que utiliza el mismo patrón.
- **`terraform import` es selectivo por módulo**, recurso por recurso —
  nunca un import de cuenta completa (produce un monolito no estructurado). Flujo:
  escribir bloques import → `terraform plan -generate-config-out=generated.tf` →
  conciliar HCL → clean plan → apply → eliminar bloques import → destroy/redeploy.
- **Restricción de proveedor en módulos legacy** — sin `depends_on`, sin paso de
  `providers` en módulos que declaran su propio bloque `provider` internamente.
  El patrón de apply en dos fases gestiona el orden en su lugar.
- **Apply en dos fases para full-stack greenfield** — `dns` y `file_transfer`
  resuelven la VPC mediante `data "aws_vpc"` en tiempo de plan; en greenfield, esto
  requiere fase 1 (`-target=module.hardening`) y luego fase 2 (full stack).
- **Variable `html_dir` en web-server** — `filemd5()`/`source` resuelven rutas
  relativas al directorio de trabajo de Terraform. Nunca fijar rutas hardcodeadas en
  módulos compuestos en un stack; utilizar una variable con un valor por defecto relativo al módulo.
- **`create_ec2_record` opcional en el módulo dns** — deshabilitado por defecto en el
  full-stack aws-native (allí no hay instancia EC2). Nunca fijar una IP por defecto hardcodeada.
- **Brecha Terraform vs Ansible — alcance preciso (2026-07-10).** Terraform está
  completamente aplicado en todos los módulos `aws-native` individualmente
  (`modules/<name>/aws-native/automation/terraform/`) — cada módulo despliega
  sus propios recursos gestionados de AWS de forma independiente. En `self-managed`, Terraform
  se aplica **únicamente** en `stacks/full-infra/self-managed/` — aprovisiona
  la instancia EC2 a partir del snapshot de la AMI pre-hardened
  (`multi-lab-aws-active-directory`), cubriendo solo la capa de infraestructura
  (instancia, red, security groups). Los módulos individuales self-managed
  **no** tienen Terraform — no hay nada que aprovisionar a nivel de módulo en ese
  entorno (sin recursos cloud, solo configuración de SO sobre un host existente).
  La brecha real no es "Terraform vs Ansible" como herramientas paralelas — es
  que **la capa de configuración del SO del snapshot self-managed se aplicó
  manualmente** y está documentada por módulo (`*-self-managed.md`), pero aún
  no está automatizada. Ansible es la herramienta que cerrará esta brecha específica:
  gestión de configuración sobre la capa de infraestructura del snapshot,
  no un reemplazo para el rol de aprovisionamiento de infraestructura de Terraform. No
  confundir ambos — Terraform aprovisiona, Ansible configura. Ansible está
  planificado pero aún no implementado; junto con la monitorización constituye la
  fase final del repositorio.

---

## Fase de Automatización — Decisiones de Ansible (2026-11-03)

**Alcance y estructura**

- **Alcance: self-managed únicamente.** `aws-native` aprovisiona servicios gestionados con
  Terraform; no hay SO que configurar. Ansible cierra la brecha de configuración
  del snapshot self-managed, no una brecha de Terraform.
- **Se automatiza exactamente lo ya aplicado a mano, en cada destino donde se aplicó**
  (fuente: `snapshots/README.md`). hardening, file-transfer y web-server: VM y EC2.
  dns y directory: solo EC2. dhcp: solo VM. Sin funcionalidad nueva; las limitaciones
  conocidas se reproducen tal cual (p. ej. SMB2 bloqueado por el bug de Samba 4.19.5 en aarch64).
- **Estructura en dos niveles.** Un rol por módulo en
  `modules/<module>/self-managed/automation/ansible/roles/<module>/` (con `tasks/`,
  `handlers/`, `defaults/`, `templates/` y `meta/`). Inventario, `ansible.cfg`,
  `requirements.txt` y playbooks (`bootstrap.yml`, `site.yml` y uno por módulo) en
  `stacks/full-infra/self-managed/automation/ansible/` — el mismo patrón de módulo + stack
  utilizado para Terraform. `roles_path` en `ansible.cfg` lista una ruta por módulo, añadida
  al llegar a su fase.
- **`terraform/` y `ansible/` coexisten dentro de `automation/`** y ambos se mantienen
  separados de `configs/`, que es hermano de `automation/`.
- **Docs de implementación de Ansible:** `<module>-self-managed-automation.md` dentro de
  `modules/<module>/self-managed/automation/`, con el estándar What was done / Why / Verification.
- **Módulos elegibles.** Un playbook por módulo y `site.yml` con un tag por módulo; cada módulo
  comprueba al inicio que hardening está aplicado y falla con un mensaje claro si no lo está.

**Diseño de los roles**

- **`configs/` se mantiene como la única fuente de verdad.** Los roles consumen los archivos
  existentes desde el nodo de control; sin contenido de configuración duplicado. Los
  placeholders (`<username>`, `192.168.X.X`, `<upstream_port>`) se sustituyen al desplegar
  con variables de inventario.
- **Un rol por módulo para ambos destinos.** Las diferencias VM/EC2 se resuelven con variables
  (`is_cloud`, `tls_mode`, ...) y los módulos se asignan a hosts mediante grupos de inventario
  que reflejan la matriz real. TLS: autofirmado en VM, Let's Encrypt en EC2.
- **Fuera de Ansible:** Security Groups y SSM (Terraform/consola). Cada hito en EC2 lista
  estos pasos como previos y manuales.
- **Seguridad.** Sin secretos en el repo; `--ask-become-pass` para el sudo; las claves
  privadas de WireGuard se generan en su host y nunca viajan al repo ni a variables.

**Entorno de trabajo y pruebas**

- **Nodo de control: el Mac, con Ansible nativo en un `venv`** y versiones fijadas en
  `requirements.txt`. Tras el Step 5 de hardening, SSH solo escucha por `wg0`; el túnel
  de WireGuard del Mac es nativo y evita el routing adicional de un contenedor o una VM.
- **Orden de implementación:** hardening → file-transfer → dns → web-server → directory →
  dhcp. Sigue la cadena real de snapshots, de modo que cada módulo dispone de su snapshot
  acumulativo como oráculo. Sustituye al orden anterior (dns antes de file-transfer).
- **Punto de partida: siempre una base limpia.** VM: snapshot `ubuntu-base-install`. EC2: AMI
  `multi-lab-aws-base-install`. Nunca el AMI ya configurado como destino de construcción.
- **El stack de Terraform self-managed** admite elegir el AMI mediante una variable, para
  poder lanzar `multi-lab-aws-base-install` además del AMI actual. Se revisa primero cómo
  está definido hoy.
- **Oráculos.** Los snapshots y AMIs manuales existentes se conservan hasta cerrar Ansible y se
  usan para comprobar equivalencia (`--check --diff` vacío). Lo creado durante Ansible lleva
  el prefijo `multi-lab-local-ansible-` / `multi-lab-aws-ansible-`.
- **Pruebas.** `ansible-lint` y `--syntax-check` en CI; `--check --diff` y una segunda
  ejecución con 0 `changed` en cada destino. Sin Molecule.
- **Monitorización (Prometheus + Grafana)** es un módulo posterior, solo self-managed,
  añadido tras cerrar la base de Ansible. También existe en
  `containerize-your-infra`, donde por ahora no se planifica Ansible.
  
---

## Plan de Implementación de Ansible (2026-11-03)

- **Documento de referencia:** `context/ansible-implementation.md`. Es la fuente
  única de fases, hitos de verificación, matriz módulo × destino, cadenas de
  snapshots/AMIs y riesgos de la implementación de Ansible. Las decisiones que lo
  sustentan están en la sección anterior; el plan las aplica y no las reabre.
- **Lectura obligatoria** para el autor, el asistente y el agente de código en
  cualquier tarea relacionada con Ansible.
- **Fases (orden fijo):** 0 alineación de contexto · 1 análisis de hardening +
  scaffolding · 2 hardening (2A preparación, 2B cadena de acceso, 2C resto de
  capas, 2D réplica en EC2) · 3 Ansible en el CI · 4 file-transfer · 5 dns ·
  6 web-server · 7 directory · 8 dhcp · 9 orquestación y cierre.
- **Regla de puertas.** No se inicia una fase sin cumplir el hito de verificación
  de la anterior. Los hitos se definen por destino (VM y/o EC2) según la matriz
  del plan.
- **Verificación estándar por módulo y destino:** `ansible-lint` y
  `--syntax-check`; `--check --diff`; ejecución real; segunda ejecución con
  0 `changed`; verificaciones del doc manual; prueba de equivalencia contra el
  snapshot/AMI manual del módulo.
- **Cambios al plan.** Cualquier cambio de fases, hitos, matriz u orden se edita
  en `context/ansible-implementation.md` y se registra aquí con fecha. El estado
  de avance no se anota en ninguno de los dos documentos (se vuelve obsoleto);
  lo reflejan los PRs mergeados y las tablas de módulos.
- **Alcance del plan:** Ansible en self-managed. La monitorización
  (Prometheus + Grafana) se planificará en un documento aparte cuando se cierre
  la base de Ansible.

---

## Implementación de CI

- **No existe un entorno persistente de AWS** (restricciones de facturación). Por lo tanto,
  `terraform plan` queda excluido de todos los workflows de CI — un plan frente a
  referencias `data "aws_vpc"` que no existen fallaría siempre. El CI para
  `aws-native` se limita a `fmt` + `validate`.
- **El backend de Terraform es local** — el estado está en .gitignore y nunca se comparte con
  los runners de CI. `validate` no requiere estado.
- **Único workflow reutilizable.** `modules-ci.yml` (`workflow_call`) define
  cada job una sola vez; `push-ci.yml` y `pull-request.yml` son puntos de entrada delgados.
  Justificación: evita duplicar reglas de validación en hasta doce archivos.
- **`paths-filter` se ejecuta dentro del workflow, no como trigger.** Un job `changes`
  calcula los outputs por módulo-entorno y `any-module`.
- **`full-infra` se ejecuta cuando cambia cualquier módulo**, controlado por `any-module`, por lo que
  nunca se ejecuta en cambios exclusivamente de documentación.
- **Los jobs de `self-managed` y `aws-native` están separados por módulo**, cada uno con
  su propio filtro — diferente perfil de riesgo y herramientas.
- **`path-consistency` es solo para PR**, para mantener el ciclo de push enfocado en la
  corrección de los módulos.

---

## Cierre y Alcance del Repositorio (2026-11-02)

- **Criterios de cierre.** El repositorio se considera cerrado una vez que Ansible esté aplicado en todos
  los módulos self-managed y la monitorización (Prometheus + Grafana) esté desplegada.
  El diagrama de arquitectura se elaborará al final, de modo que se construya una sola vez frente al
  stack definitivo.
- **`context/current-iteration.md` eliminado.** El estado ya se refleja
  en las tablas de módulos y en este log; un documento de estado separado añadía fricción y
  quedaba desactualizado.
- **Enfoque orientado al problema sin reescribir.** El README raíz incorpora una breve
  introducción de problema/enfoque y cada README de módulo abre con el problema que
  resuelve. Las secciones `### Why` a nivel de paso se mantienen tal cual están.

---

## Método de Trabajo (2026-11-02)

- Estructura y decisiones primero, luego documentos de implementación generados por el asistente arquitecto, después el autor los ejecuta paso a paso y reporta los errores de vuelta a los documentos.
- Las tareas mecánicas pueden delegarse al agente de código (Antigravity); diseño, docs y justificaciones no se delegan. Los prompts son redactados por el autor y el asistente.
- El agente de código trabaja en feature branches y abre pull requests; nunca hace push a `main` ni merge, y ejecuta la estructura definida aquí sin decidirla.
