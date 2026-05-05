# Migration `20260504190000_to_ats_schema`

Migración del schema legacy LTI (`Candidate`, `Education`, `WorkExperience`, `Resume`) al modelo ATS completo descrito en el diagrama del proyecto.

Esta carpeta es **híbrida**: contiene un `migration.sql` compatible con Prisma (lo aplica `prisma migrate deploy/dev`) y dos scripts auxiliares que se ejecutan **manualmente con psql** (Prisma los ignora).

## Ficheros

| Fichero | Quién lo invoca | Cuándo |
|---|---|---|
| `migration.sql` | Prisma (automático) | `prisma migrate deploy` o `prisma migrate dev` |
| `rollback.sql`  | Operador (manual) | Si tras COMMIT se decide revertir |
| `verify.sql`    | Operador (manual) | Tras la migración, valida integridad |
| `README.md`     | — | Este documento |

## Aplicar la migración

```bash
cd backend
npx prisma migrate deploy
```

Prisma envuelve `migration.sql` en una transacción atómica. Si cualquier paso falla, hace ROLLBACK y la BD queda en el estado previo. La migración registra su progreso en `public.migration_state` y `public.migration_log` (auxiliares, separadas de `_prisma_migrations`).

Decisiones de diseño documentadas en el cabezal de `migration.sql`:
- 3FN respetada (`company.description` en vez de `position.company_description`).
- Cardinalidades 1:1 del diagrama tratadas como N:1.
- `Education`, `WorkExperience`, `Resume` conservadas en snake_case.
- Catálogos enum-like en `VARCHAR` + `CHECK` constraints.
- IDs preservados al copiar datos legacy (consumers externos no se rompen).

## Verificar

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/prisma/migrations/20260504190000_to_ats_schema/verify.sql
```

Comprueba 6 categorías y aborta al primer fallo:

1. Estado de los pasos (`migration_state`).
2. Cardinalidad: `count(lti_backup.*) == count(public.*)`.
3. Contenido por hash MD5 de columnas clave.
4. Integridad referencial (cero orphans en cada FK).
5. Secuencias alineadas.
6. CHECK constraints activas.

Salida esperada: `VERIFY OK`.

## Revertir (rollback manual)

Sólo necesario si **después del COMMIT** se decide volver atrás (un fallo durante `migrate deploy` ya queda revertido por la transacción de Prisma).

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/prisma/migrations/20260504190000_to_ats_schema/rollback.sql
npx prisma migrate resolve --rolled-back 20260504190000_to_ats_schema
```

El segundo comando es **crítico**: sin él, `prisma migrate deploy` seguirá considerando esta migración como aplicada y no la re-aplicará si más tarde quieres avanzar otra vez.

`rollback.sql`:
- Elimina las tablas nuevas (orden FK-safe + CASCADE como red).
- Reconstruye `Candidate/Education/WorkExperience/Resume` desde `lti_backup` con DDL idéntico al de la init original de Prisma.
- Restaura las secuencias a sus valores exactos pre-migración.
- Verifica paridad con `lti_backup` antes de COMMIT.
- Marca `migration_state.status = 'rolled_back'`.

`lti_backup` **NO se borra**. Una vez confirmado que el estado legacy funciona:

```sql
DROP SCHEMA lti_backup CASCADE;
```

## Limpieza tras validar definitivamente

Cuando la migración se considere buena en producción y no haya intención de revertir:

```sql
DROP SCHEMA lti_backup CASCADE;
-- opcional: tablas de control (mantenibles para auditoría)
DROP TABLE IF EXISTS public.migration_state, public.migration_log;
DROP FUNCTION IF EXISTS public._mig_begin(text, text);
DROP FUNCTION IF EXISTS public._mig_end(text, text);
```

## Caveats Prisma

- **Drift con `schema.prisma`**: el modelo Prisma sigue describiendo la BD legacy. Tras validar, ejecuta `npx prisma db pull` para regenerar `schema.prisma` desde el estado real (modelo ATS). Después `npx prisma generate` actualiza el cliente.
- **`migrate dev` detectará drift** si lo intentas antes de regenerar el schema. Usa `migrate deploy` para aplicar esta migración tal cual.
- **CHECK constraints no son nativos en Prisma**: tras `db pull` quedarán como comentarios. Si quieres enforcement vía cliente, añade `enum` en el `schema.prisma` regenerado.

## Estructura interna de `migration.sql`

Los step_keys del diseño multi-fichero original se conservan dentro de `migration_state` para trazabilidad:

```
00_migration_state    Tablas y helpers de control
01_backup_legacy      LOCK SHARE + clonado a lti_backup
02_create_catalog     company, employee, interview_type, interview_flow
03_create_workflow    interview_step
04_create_jobs        position, application, interview
05_create_candidate   candidate (snake_case)
06_create_legacy_kept education, work_experience, resume
07_migrate_candidate  "Candidate" → candidate
08_migrate_subtables  Education/WorkExperience/Resume → snake_case
09_drop_legacy        DROP de tablas legacy
10_constraints_fk     FKs entre tablas nuevas
11_indexes            Índices secundarios
12_reset_sequences    Alinea secuencias
99_committed          Marca de cierre
```

Inspeccionable post-migración:

```sql
SELECT step_key, status, finished_at - started_at AS duration, details
  FROM public.migration_state
 ORDER BY started_at;
```
