# Prompts relevantes — Sesión AI4DEVS-DB-202602

Este documento recoge los prompts del usuario que guiaron las **decisiones de diseño de la migración** y los **cambios en el código**. Se omiten prompts puramente operativos (arrancar servidores, comprobar credenciales, etc.) y aclaraciones que no llevaron a cambios estructurales.

---

## P1 — Especificar la migración del schema legacy al modelo ATS

**Prompt:**

> Eres un experto en base de datos relacionales con años de experiencias en el uso de PosgreSQL.
>
> Quiero que generes el script necesario para migrar la base de datos actual en PosgreSQL descrita en Prisma a la descrita en el diagrama del final del prompt.
>
> Requerimientos a tener en cuenta:
> - Quiero que el schema final respete las 3 formas de normalización. En caso que detectes algún error de diseño en el diagrama notifícamelo para decidir conjuntamente qué hacer.
> - Quiero también que revises que ningún datos del schema antiguo "se pierda", en caso de ser comentamelo y veremos como gestionarlo.
> - La migración deberá realizar los cambios necesarios en los objetos del schema y preveer también la migración de los datos ya introducidos en la aplicación. No solo lo que pueda haber actualmente en la base de datos sino de cualquier dato que pueda haberse introducido entre la creación de los scripts de migración y la migración propiamente dicha.
> - Para el nuevo schema quiero un script que coordine todo el proceso. En caso de error debe mostrar claramente en qué punto nos hemos quedado. No escatimes en comentarios y logs del proceso.
> - Quiero que generes una estructura en paralelo con scripts de rollback por si hay que revertir los cambios. El rollback debe restaurar el estado previo a la migración. Además debe ser capaz de manejar la situación si solo se han ejecutado una parte de los pasos de la creación porque en algún punto ha habido un error.
> - Una vez finalizada la migración deberán lanzar queries para garantizar que ningún dato se ha perdido en la migración.
> - Dejar una copia de los datos del antiguo schema en otro schema aparte para poder revisarlos. En caso de ser correcta la migración un operador humano ya lo borraría a posteriori.
>
> [+ diagrama Mermaid con COMPANY, EMPLOYEE, POSITION, INTERVIEW_FLOW, INTERVIEW_STEP, INTERVIEW_TYPE, CANDIDATE, APPLICATION, INTERVIEW]

**Por qué relevante:** prompt fundacional de toda la migración. Define los siete requisitos no funcionales (3FN, no pérdida de datos, atomicidad, logging, rollback robusto, verificación, schema de backup) que condicionaron el diseño completo.

---

## P2 — Decisiones de diseño consensuadas en plan mode

Durante la fase de planificación se acordaron las decisiones siguientes (vía preguntas estructuradas):

| Cuestión | Decisión |
|---|---|
| Cardinalidades 1:1 sospechosas en el diagrama (POSITION-INTERVIEW_FLOW, INTERVIEW_STEP-INTERVIEW_TYPE, INTERVIEW-INTERVIEW_STEP) | Tratar como N:1 (varias posiciones reutilizan un flow, etc.) |
| Tablas huérfanas (Education, WorkExperience, Resume) sin equivalente en el diagrama nuevo | Conservar tablas en el nuevo schema (renombradas a snake_case) |
| `POSITION.company_description` viola 3FN | Mover a `company.description` |
| Campos enum-like (status, role, employment_type, result) | `VARCHAR` + `CHECK` constraints (documentando valores admitidos en `COMMENT ON COLUMN`) |
| Convención de nombres | `snake_case` sin comillas |
| Orquestación de la migración | Master `.sql` con psql (`\i` + `SAVEPOINT`) |
| `schema.prisma` | No tocar todavía; nota para regenerar después con `prisma db pull` |

**Por qué relevante:** estas decisiones determinan la forma final del schema y del flujo de migración. Cada una se documentó después en `plan.md` y en los comentarios de las propias migraciones.

---

## P3 — Persistir el plan en la raíz del proyecto

**Prompt:**

> Acepto el plan pero guardame el fichero como plan.md en la raíz del proyecto.

**Por qué relevante:** decisión de tener el plan como documento auditable en el repo (no sólo en el directorio temporal de planes de Claude).

---

## P4 — Discusión sobre relocalizar la migración a `backend/prisma/migrations`

**Prompt:**

> Si muevo el contenido de la carpeta db/migrations/001_to_ats_schema a backend/prisma/migrations seguiría funcionando bien? En caso de ser así hazlo.

**Por qué relevante:** disparó la discusión sobre la incompatibilidad entre el formato multi-fichero con `\i` y meta-comandos psql vs. el formato esperado por Prisma (un único `migration.sql` por carpeta timestamped). La respuesta documentó las cinco razones por las que un movimiento literal no funcionaría.

---

## P5 — Adaptar la migración al formato Prisma

**Prompt:**

> Puedes hacer las adaptaciones necesarias para mover el contenido dentro de backend/prisma/migrations y que siga funcionando correctamente?

**Cambios derivados:**
- `migration.sql` aplanado: eliminados `\i`, `\set`, `\echo`, `BEGIN`/`COMMIT` y `SAVEPOINT` (Prisma envuelve en su propia tx)
- `rollback.sql` y `verify.sql` conservaron meta-comandos psql porque se ejecutan manualmente
- `migration_state` y `migration_log` mantenidas como tablas operativas separadas de `_prisma_migrations`
- README de la migración indicando qué ficheros aplica Prisma vs. cuáles son manuales
- `db/migrations/` eliminado tras validar el equivalente en Prisma

**Por qué relevante:** marcó el cambio de paradigma de "scripts SQL operados manualmente" a "migración integrada en el flujo Prisma". Decisión irreversible para cómo se aplican futuras migraciones.

---

## P6 — Adaptar el backend al nuevo modelo de datos

**Prompt:**

> Puedes adaptar el backend al nuevo modelo de datos?

**Decisiones tomadas en el proceso:**
1. **`BIGSERIAL` → `SERIAL`** en `migration.sql` (reaplicado con rollback + redeploy). Mantiene los IDs como `Int` en TypeScript en vez de `BigInt` (que rompería `JSON.stringify`, comparaciones, etc.).
2. **`@@map` y `@map`** en `schema.prisma` para que los modelos sigan en PascalCase (`Candidate`, `WorkExperience`...) y campos en camelCase, mapeados a tablas/columnas snake_case en BD.
3. **`WorkExperience.company` → columna `company_name`**, **`WorkExperience.position` → columna `position_title`** vía `@map`. **Cero cambios** en código TS de modelos de dominio.
4. **Excluir tablas auxiliares** (`migration_state`, `migration_log`) del `schema.prisma`: existen en BD pero no son modelo de negocio.

**Resultado:** `npm test` 37/37, `npm run build` OK, `POST /candidates` end-to-end funcional con la BD ATS.

**Por qué relevante:** demostró cómo el mapping de Prisma permite migrar la convención de naming de la BD sin tocar el código consumidor. Las cuatro decisiones determinan el contrato entre BD y aplicación durante años.

---

## P7 — Análisis de índices y propuestas justificadas

**Prompt:**

> Quiero que revises las consultas que puede hacer la aplicación y evalues la opción de poner índices para ellas. Justifica tus propuestas.

**Conclusiones clave del análisis:**
- Las **6 queries Prisma reales** del código actual (todas sobre `Candidate` por PK o email UNIQUE) **ya están cubiertas**: ninguna propuesta justificada por el código actual.
- Para los patrones típicos de un ATS al exponer endpoints: 5 propuestas A-E con análisis de cardinalidad, prefijos izquierdos, sustitución de simples por compuestos, y cuándo aplicar.
- Principio: no añadir índices sin un caso de uso codificado o un `EXPLAIN ANALYZE` real.

**Por qué relevante:** sentó la metodología de "índices por consulta concreta", no "índices por si acaso". Reglas explícitas para cuándo añadir y cuándo retirar.

---

## P8 — Aplicar A, B y C; D y E como recomendaciones futuras

**Prompt:**

> De acuerdo genera los A, B y C y deja anotados los D y E como recomendaciones futuras.

**Aplicado en migración `20260505080000_optimize_indexes`:**
- **A)** `application(position_id, status)` compuesto — absorbe `application_position_idx` y `application_status_idx`
- **B)** `interview(employee_id, interview_date)` compuesto — absorbe `interview_employee_idx`
- **C)** `application(candidate_id, application_date DESC)` compuesto — absorbe `application_candidate_idx`

**Net:** un índice menos en total, mejor cobertura para pipeline del recruiter, agenda del entrevistador y portal del candidato.

**Diferido en `FUTURE_RECOMMENDATIONS.md`:**
- **D)** `pg_trgm` + GIN para búsqueda fuzzy de candidatos por nombre — sólo cuando exista endpoint de búsqueda
- **E)** `position(application_deadline)` parcial — sólo cuando exista endpoint "vacantes próximas a cerrar"

**Por qué relevante:** ejemplo concreto de aplicar la regla "índices por caso de uso". Los aplicados resuelven queries inminentes, los diferidos quedan documentados con criterio claro de "cuándo activarlos".

---

## Resumen de artefactos generados

| Decisión / prompt | Artefacto |
|---|---|
| P1, P2 | [plan.md](../plan.md) |
| P5 | [backend/prisma/migrations/20260504190000_to_ats_schema/](../backend/prisma/migrations/20260504190000_to_ats_schema/) (`migration.sql`, `rollback.sql`, `verify.sql`, `README.md`) |
| P6 | [backend/prisma/schema.prisma](../backend/prisma/schema.prisma) reescrito con `@@map`/`@map` |
| P7, P8 | [backend/prisma/migrations/20260505080000_optimize_indexes/](../backend/prisma/migrations/20260505080000_optimize_indexes/) (`migration.sql`, `FUTURE_RECOMMENDATIONS.md`) |
