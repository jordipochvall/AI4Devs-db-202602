-- =============================================================================
-- rollback.sql — Reversión de la migración 20260504190000_to_ats_schema
-- -----------------------------------------------------------------------------
-- IMPORTANTE: este script NO se ejecuta automáticamente por Prisma. Se invoca
-- manualmente con psql cuando se decide revertir DESPUÉS del COMMIT (un fallo
-- durante migrate.sql ya queda revertido por la transacción de Prisma).
--
-- Cómo invocar:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/prisma/migrations/20260504190000_to_ats_schema/rollback.sql
--
-- Tras un rollback satisfactorio, también es necesario decirle a Prisma que
-- esta migración ya no está aplicada, para que `prisma migrate deploy` no la
-- considere completada:
--   npx prisma migrate resolve --rolled-back 20260504190000_to_ats_schema
--
-- El script es tolerante a estado parcial (por si alguien hubiese ejecutado
-- los pasos sueltos a mano fuera de tx). lti_backup NO se borra: un humano
-- decide cuándo limpiarlo tras validar.
-- =============================================================================

\echo '====================================================================='
\echo '  ROLLBACK 20260504190000_to_ats_schema  — start'
\echo '====================================================================='

\set ON_ERROR_STOP on
\set VERBOSITY     terse

BEGIN;

SET LOCAL statement_timeout = '15min';
SET LOCAL lock_timeout      = '30s';


-- =============================================================================
-- 1) Detectar estado actual
-- =============================================================================
DO $$
BEGIN
    RAISE NOTICE '[%] rollback: detecting state...', clock_timestamp();
END $$;

CREATE TEMP TABLE _rollback_plan (
    has_state_table  BOOLEAN,
    has_backup       BOOLEAN,
    fully_committed  BOOLEAN
);

INSERT INTO _rollback_plan
SELECT
    EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='migration_state'),
    EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='lti_backup'),
    EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema='public' AND table_name='migration_state')
    AND EXISTS (
        SELECT 1
          FROM (SELECT 1 WHERE EXISTS (SELECT 1 FROM information_schema.tables
                                        WHERE table_schema='public' AND table_name='migration_state')) AS guard
         WHERE EXISTS (
            SELECT 1 FROM public.migration_state
             WHERE step_key='99_committed' AND status='done'
        )
    );

DO $$
DECLARE
    p RECORD;
BEGIN
    SELECT * INTO p FROM _rollback_plan;
    RAISE NOTICE 'has_state_table=% has_backup=% fully_committed=%',
        p.has_state_table, p.has_backup, p.fully_committed;

    IF NOT p.has_state_table AND NOT p.has_backup THEN
        RAISE EXCEPTION 'No migration evidence found (no migration_state, no lti_backup). Nothing to rollback.';
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema='public' AND table_name='migration_state') THEN
        INSERT INTO public.migration_state (step_key, started_at, status, details)
        VALUES ('rollback', clock_timestamp(), 'running', 'rollback in progress')
        ON CONFLICT (step_key) DO UPDATE
           SET started_at = clock_timestamp(),
               finished_at = NULL,
               status      = 'running',
               details     = 'rollback re-run';
    END IF;
END $$;


-- =============================================================================
-- 2) DROP de tablas nuevas (orden FK-safe; CASCADE como red de seguridad)
-- =============================================================================
DO $$
BEGIN
    RAISE NOTICE '[%] rollback: dropping new tables', clock_timestamp();
END $$;

DROP TABLE IF EXISTS public.interview        CASCADE;
DROP TABLE IF EXISTS public.application      CASCADE;
DROP TABLE IF EXISTS public.interview_step   CASCADE;
DROP TABLE IF EXISTS public.position         CASCADE;
DROP TABLE IF EXISTS public.employee         CASCADE;
DROP TABLE IF EXISTS public.resume           CASCADE;
DROP TABLE IF EXISTS public.work_experience  CASCADE;
DROP TABLE IF EXISTS public.education        CASCADE;

DROP TABLE IF EXISTS public.interview_flow   CASCADE;
DROP TABLE IF EXISTS public.interview_type   CASCADE;
DROP TABLE IF EXISTS public.company          CASCADE;
DROP TABLE IF EXISTS public.candidate        CASCADE;


-- =============================================================================
-- 3) Restaurar el schema legacy desde lti_backup
-- -----------------------------------------------------------------------------
-- DDL idéntico al de la migración inicial de Prisma (20260504165247_init).
-- Si lti_backup no existe (rollback sobre estado pre-step-01), abortamos.
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='lti_backup') THEN
        RAISE EXCEPTION 'lti_backup not found — cannot restore legacy data. If migration never ran past step 01, no restore is needed; verify state and skip this script.';
    END IF;
    RAISE NOTICE '[%] rollback: restoring legacy schema from lti_backup', clock_timestamp();
END $$;

DROP TABLE IF EXISTS public."Resume"         CASCADE;
DROP TABLE IF EXISTS public."WorkExperience" CASCADE;
DROP TABLE IF EXISTS public."Education"      CASCADE;
DROP TABLE IF EXISTS public."Candidate"      CASCADE;

CREATE TABLE public."Candidate" (
    "id"        SERIAL       NOT NULL,
    "firstName" VARCHAR(100) NOT NULL,
    "lastName"  VARCHAR(100) NOT NULL,
    "email"     VARCHAR(255) NOT NULL,
    "phone"     VARCHAR(15),
    "address"   VARCHAR(100),
    CONSTRAINT "Candidate_pkey" PRIMARY KEY ("id")
);

CREATE TABLE public."Education" (
    "id"          SERIAL       NOT NULL,
    "institution" VARCHAR(100) NOT NULL,
    "title"       VARCHAR(250) NOT NULL,
    "startDate"   TIMESTAMP(3) NOT NULL,
    "endDate"     TIMESTAMP(3),
    "candidateId" INTEGER      NOT NULL,
    CONSTRAINT "Education_pkey" PRIMARY KEY ("id")
);

CREATE TABLE public."WorkExperience" (
    "id"          SERIAL       NOT NULL,
    "company"     VARCHAR(100) NOT NULL,
    "position"    VARCHAR(100) NOT NULL,
    "description" VARCHAR(200),
    "startDate"   TIMESTAMP(3) NOT NULL,
    "endDate"     TIMESTAMP(3),
    "candidateId" INTEGER      NOT NULL,
    CONSTRAINT "WorkExperience_pkey" PRIMARY KEY ("id")
);

CREATE TABLE public."Resume" (
    "id"          SERIAL       NOT NULL,
    "filePath"    VARCHAR(500) NOT NULL,
    "fileType"    VARCHAR(50)  NOT NULL,
    "uploadDate"  TIMESTAMP(3) NOT NULL,
    "candidateId" INTEGER      NOT NULL,
    CONSTRAINT "Resume_pkey" PRIMARY KEY ("id")
);

INSERT INTO public."Candidate"      SELECT * FROM lti_backup."Candidate";
INSERT INTO public."Education"      SELECT * FROM lti_backup."Education";
INSERT INTO public."WorkExperience" SELECT * FROM lti_backup."WorkExperience";
INSERT INTO public."Resume"         SELECT * FROM lti_backup."Resume";

DO $$
DECLARE
    r RECORD;
    seq_full TEXT;
BEGIN
    FOR r IN SELECT sequence_name, last_value, is_called FROM lti_backup._sequence_state LOOP
        seq_full := format('public.%I', r.sequence_name);
        EXECUTE format('SELECT setval(%L, %s, %L)', seq_full, r.last_value, r.is_called);
    END LOOP;
END $$;

CREATE UNIQUE INDEX "Candidate_email_key" ON public."Candidate"("email");

ALTER TABLE public."Education"
    ADD CONSTRAINT "Education_candidateId_fkey"
    FOREIGN KEY ("candidateId") REFERENCES public."Candidate"("id")
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public."WorkExperience"
    ADD CONSTRAINT "WorkExperience_candidateId_fkey"
    FOREIGN KEY ("candidateId") REFERENCES public."Candidate"("id")
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public."Resume"
    ADD CONSTRAINT "Resume_candidateId_fkey"
    FOREIGN KEY ("candidateId") REFERENCES public."Candidate"("id")
    ON DELETE RESTRICT ON UPDATE CASCADE;

DO $$
DECLARE
    pair RECORD;
BEGIN
    FOR pair IN
        SELECT 'Candidate'::text      AS tbl, (SELECT COUNT(*) FROM lti_backup."Candidate")      AS bak, (SELECT COUNT(*) FROM public."Candidate")      AS cur UNION ALL
        SELECT 'Education',                  (SELECT COUNT(*) FROM lti_backup."Education"),            (SELECT COUNT(*) FROM public."Education")           UNION ALL
        SELECT 'WorkExperience',             (SELECT COUNT(*) FROM lti_backup."WorkExperience"),       (SELECT COUNT(*) FROM public."WorkExperience")      UNION ALL
        SELECT 'Resume',                     (SELECT COUNT(*) FROM lti_backup."Resume"),               (SELECT COUNT(*) FROM public."Resume")
    LOOP
        IF pair.bak <> pair.cur THEN
            RAISE EXCEPTION 'restore mismatch %: backup=% public=%', pair.tbl, pair.bak, pair.cur;
        END IF;
    END LOOP;
    RAISE NOTICE '[%] rollback: legacy schema restored OK', clock_timestamp();
END $$;


-- =============================================================================
-- 4) Cierre del rollback
-- =============================================================================
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema='public' AND table_name='migration_state') THEN
        UPDATE public.migration_state
           SET status = 'rolled_back',
               finished_at = clock_timestamp(),
               details = COALESCE(details,'') || ' [rolled_back]'
         WHERE status <> 'rolled_back';

        INSERT INTO public.migration_log (step_key, level, message)
        VALUES ('rollback', 'INFO', 'rollback completed');
    END IF;
END $$;

DO $$
DECLARE
    bak_present BOOLEAN := EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='lti_backup');
BEGIN
    RAISE NOTICE '[%] rollback: DONE. lti_backup present=%', clock_timestamp(), bak_present;
    RAISE NOTICE 'NOTE: lti_backup is preserved for human audit. Drop it manually when satisfied.';
END $$;

COMMIT;

\echo '====================================================================='
\echo '  ROLLBACK 20260504190000_to_ats_schema  — COMMIT OK'
\echo '====================================================================='
\echo 'Legacy schema restored. lti_backup preserved for audit.'
\echo 'Remember: npx prisma migrate resolve --rolled-back 20260504190000_to_ats_schema'
