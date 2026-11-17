# Sistema Distribuido de Coordinación y Gestión de Emergencias en Elixir

Plataforma concurrente y multiusuario desarrollada en **Elixir (OTP)** para coordinar la atención, logística de recursos, gestión de albergues, localización de personas y emparejamiento de mascotas tras un terremoto de gran magnitud.

---

## Información Académica

* **Autor:** José Daniel Carmona García - Jeronimo Delgado Estrada
* **Institución:** Universidad del Quindío
* **Facultad:** Ingeniería — Programa de Ingeniería de Sistemas y Computación
* **Asignatura:** Programación III (2026-2)

---

## Características Principales y Arquitectura

El sistema está diseñado bajo principios de programación funcional, inmutabilidad, aislamiento de fallos y concurrencia basada en el modelo de actores de la máquina virtual BEAM:

* **Gestión de Usuarios y Roles (`UserRegistry`):** Registro automático al primer inicio de sesión (`connect`), contraseñas con hash SHA-256 y sal, validación de credenciales, auditoría inmutable de acciones y control de permisos para `:ciudadano`, `:voluntario`, `:coordinador` y `:administrador`.
* **Jerarquía de Zonas Afectadas (`ZoneManager`):** Modelado anidado `Zona -> Sectores -> Puntos de Atención` con asociación libre de duplicados mediante `MapSet` (`shelters`, `needs`, `resources`, `reports`) y cálculo recursivo de estadísticas acumuladas.
* **Gestión de Necesidades y Cola de Prioridad (`NeedManager`):** Máquina de estados estricta (`:pendiente`, `:asignada`, `:en_atencion`, `:atendida`, `:cancelada`), ordenamiento recursivo (*Insertion Sort*) y selector de atención según peso de criticidad (`:critica > :alta > :media > :baja`).
* **Inventario Transaccional libre de Condiciones de Carrera (`ResourceManager`):** Reserva atómica serializada a través del buzón del `GenServer`, garantizando que solicitudes simultáneas nunca asignen más unidades de las disponibles ni generen saldos negativos, con historial completo de movimientos (kardex) y transferencias entre centros/albergues.
* **Localización de Personas y Mensajería Familiar (`FamilyRegistry`):** Trazabilidad histórica de cambios de estado (`:sin_informacion`, `:reportada`, `:localizada`, `:trasladada`, `:en_albergue`, `:reunificada`) y buzón de mensajes para familiares con estados `:pendiente` y `:entregado`.
* **Motor de Emparejamiento de Mascotas (`PetMatcher`):** Evaluación recursiva multicriterio (especie, zona, color, tamaño y rasgos/nombre) con puntaje de similitud sobre 100 puntos, transición a `:posible_coincidencia` y cierre atómico (`:resuelta`) de ambos reportes vinculados.
* **Control de Albergues (`ShelterManager`):** Validación estricta de capacidad máxima, control de ocupantes únicos, asociación de recursos y necesidades mediante `MapSet` y ranking de ocupación en tiempo real.
* **Supervisión Dinámica y Paso de Mensajes Puro (`SessionSupervisor` & `AlertBroadcaster`):** Uso de `DynamicSupervisor` para aislar sesiones activas de usuarios (`UserSessionWorker`) y difusión de alertas sísmicas mediante primitivas puras (`spawn_link`, `send`, `receive`).
* **Persistencia en Texto Plano (`TextStorage`):** Almacenamiento y reconstrucción recursiva segura (AST whitelist) del estado en archivos `.txt` legibles dentro del directorio `data/`.

---

## Ejecución y Uso

### 1. Ejecutar la suite de pruebas (84 tests)

```bash
mix test
```

*(En Windows con sistemas de archivos restringidos, si Mix solicita desactivar hardlinks: `$env:MIX_OS_CONCURRENCY_LOCK="0"; mix.bat test`).*

### 2. Iniciar la Consola Interactiva (CLI / REPL)

```bash
mix run -e "EmergencySystem.start_cli()"
```

Dentro de la consola puedes escribir `help` para listar todos los comandos o `demo` para ejecutar automáticamente el **Flujo de Ejemplo oficial (Sección 1.4.10)** con demostración de concurrencia en vivo.

### 3. Ejecutar directamente el Flujo de Ejemplo 1.4.10

```bash
mix run -e "EmergencySystem.run_demo_scenario()"
```

---

## Comandos de Referencia Soportados en el CLI

```text
# Usuarios y Sesión (1.4.1 y 1.4.2)
connect <usuario> <password> [rol] [zona]
disconnect
register_user <usuario> <password> "<nombre_completo>" <rol> <zona>
user_activity [usuario]

# Zonas, Sectores y Puntos de Atención (1.4.3)
register_zone <codigo> "<nombre>" <nivel> [afectados]
add_sector <zona> <codigo_sector> "<nombre>" <nivel> [afectados]
add_attention_point <zona> <sector> <id_punto> "<nombre>" <personas_afectadas>
zone_status <zona>

# Necesidades Puntuales (1.4.4)
register_need <tipo> <cantidad> <prioridad> <zona> "<descripcion>" [entidad_asociada]
update_need_status <id_necesidad> <nuevo_estado>
list_needs [zona=X] [prioridad=Y] [estado=Z] [tipo=W]
pending_needs
next_need
assign_resource <id_necesidad> <recurso> <cantidad>

# Recursos y Centros de Apoyo (1.4.5)
register_resource <codigo> <nombre> <cantidad> <unidad> <ubicacion> [zona]
add_stock <codigo> <cantidad>
list_resources [zona=X] [tipo=Y] [ubicacion=Z]
resource_availability [zona=X] [tipo=Y]
resource_history <codigo>
critical_resources
transfer_resource <codigo> <origen> <destino> <cantidad> [zona_destino]

# Comunicación entre Familiares (1.4.6)
report_person <documento> "<nombre>" [edad] <zona> <estado>
find_person <documento_o_nombre_o_zona_o_estado>
send_family_message <documento> "<mensaje>"
list_family_messages <documento>
mark_message_delivered <id_mensaje>

# Mascotas Perdidas y Encontradas (1.4.7)
report_pet <lost|found> <especie> "<nombre>" ["<caracteristicas>"] <color> <pequena|mediana|grande> <zona> <contacto>
list_pets [especie=X] [zona=Y] [estado=Z]
match_pets
confirm_match <id_perdida> <id_encontrada>

# Albergues (1.4.8)
register_shelter <codigo> "<nombre>" <zona> <capacidad>
check_shelter <codigo>
register_entry <codigo_albergue> <documento>
register_exit <codigo_albergue> <documento>
link_shelter_resource <codigo_albergue> <codigo_recurso>
link_shelter_need <codigo_albergue> <id_necesidad>
top_shelters

# Alertas y Resumen Global
broadcast_alert "<mensaje>"
summary
demo
exit
```

---

## Estructura del Proyecto

```text
Proyectos-jeronimo2/
├── config/                                  # Configuración por entorno (dev, test, prod)
├── data/                                    # Archivos de persistencia en texto plano (.txt)
├── lib/
│   ├── emergency_system.ex                  # Fachada pública y simulación del flujo 1.4.10
│   └── emergency_system/
│       ├── application.ex                   # Supervisor raíz OTP (:one_for_one)
│       ├── algorithms/
│       │   ├── zone_traversal.ex            # Recursión #1: Estadísticas jerárquicas de zonas
│       │   ├── priority_queue.ex            # Recursión #2: Ordenamiento, filtrado y selección por prioridad
│       │   └── similarity_engine.ex         # Recursión #3: Puntaje de similitud de mascotas
│       ├── cli/
│       │   └── dispatcher.ex                # Intérprete de comandos y consola interactiva (REPL)
│       ├── core/
│       │   ├── user.ex                      # Struct y permisos de usuario
│       │   ├── zone.ex                      # Structs Zone, Sector y AttentionPoint
│       │   ├── need.ex                      # Struct y máquina de estados de necesidades
│       │   ├── resource.ex                  # Struct y kardex de inventario
│       │   ├── person.ex                    # Structs Person y FamilyMessage
│       │   ├── pet_report.ex                # Struct de mascotas perdidas/encontradas
│       │   └── shelter.ex                   # Struct y control de cupos de albergues
│       ├── servers/
│       │   ├── user_registry.ex             # GenServer de usuarios y sesiones
│       │   ├── zone_manager.ex              # GenServer de zonas y sectores
│       │   ├── resource_manager.ex          # GenServer transaccional de recursos
│       │   ├── need_manager.ex              # GenServer de necesidades puntuales
│       │   ├── family_registry.ex           # GenServer de personas y mensajes familiares
│       │   ├── pet_matcher.ex               # GenServer de reportes y cruces de mascotas
│       │   ├── shelter_manager.ex           # GenServer de albergues
│       │   └── session_supervisor.ex        # DynamicSupervisor + AlertBroadcaster (spawn/receive)
│       └── storage/
│           └── text_storage.ex              # Recursión #4: Serializador/Parser en texto plano
├── test/                                    # Suite de 84 pruebas automatizadas (ExUnit)
└── mix.exs
```
