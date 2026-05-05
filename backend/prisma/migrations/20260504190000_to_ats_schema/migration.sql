-- =============================================================================
-- Migration 20260504190000_to_ats_schema — LTI legacy → modelo ATS completo
-- -----------------------------------------------------------------------------
-- Aplica el schema ATS sobre una BD que ya tiene la migración inicial de
-- Prisma aplicada (Candidate / Education / WorkExperience / Resume).
--
-- Este fichero es la versión aplanada y Prisma-compatible de la migración
-- en 13 pasos. Está pensado para ser invocado por `prisma migrate deploy`
-- o `prisma migrate dev`, que envuelven cada migration.sql en su propia
-- transacción atómica — por eso aquí NO hay BEGIN/COMMIT ni meta-comandos
-- psql (\\i, \\echo, \\set).
--
-- Para revertir (después de COMMIT) o verificar la integridad, ver
-- rollback.sql y verify.sql en este mismo directorio. Esos sí se invocan
-- manualmente con psql.
--
-- Decisiones de diseño:
--   - 3FN respetada (company.description en vez de position.company_description).
--   - Cardinalidades 1:1 del diagrama tratadas como N:1.
--   - Education/WorkExperience/Resume conservadas en snake_case.
--   - Catálogos enum-like en VARCHAR + CHECK constraints.
--   - IDs preservados al copiar datos legacy.
--
-- Estructura interna (mantenemos los step_keys del diseño original):
--   00_migration_state    tablas de control + helpers
--   01_backup_legacy      LOCK + clonado a lti_backup
--   02_create_catalog     company, employee, interview_type, interview_flow
--   03_create_workflow    interview_step
--   04_create_jobs        position, application, interview
--   05_create_candidate   candidate (snake_case)
--   06_create_legacy_kept education, work_experience, resume
--   07_migrate_candidate  copia "Candidate" → candidate
--   08_migrate_subtables  copia Education/WorkExperience/Resume
--   09_drop_legacy        DROP de las tablas legacy
--   10_constraints_fk     FKs entre tablas nuevas
--   11_indexes            índices secundarios
--   12_reset_sequences    alinea secuencias
--   99_committed          marca de cierre
-- =============================================================================


-- =============================================================================
-- Step 00 — Estado de migración y log
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.migration_state (
    step_key     TEXT        PRIMARY KEY,
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    status       TEXT        NOT NULL DEFAULT 'pending'
                              CHECK (status IN ('pending','running','done','failed','rolled_back')),
    details      TEXT
);

COMMENT ON TABLE  public.migration_state           IS 'Control de progreso de la migración 20260504190000_to_ats_schema. No borrar tras la migración (auditoría).';
COMMENT ON COLUMN public.migration_state.step_key  IS 'Identificador estable del paso (ej. "01_backup_legacy").';
COMMENT ON COLUMN public.migration_state.status    IS 'pending | running | done | failed | rolled_back';

CREATE TABLE IF NOT EXISTS public.migration_log (
    id        SERIAL   PRIMARY KEY,
    step_key  TEXT        NOT NULL,
    level     TEXT        NOT NULL CHECK (level IN ('INFO','WARN','ERROR')),
    message   TEXT        NOT NULL,
    ts        TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.migration_log IS 'Log persistente de la migración (sobrevive al cierre de la sesión psql/Prisma).';

CREATE INDEX IF NOT EXISTS migration_log_step_idx ON public.migration_log (step_key, ts);

CREATE OR REPLACE FUNCTION public._mig_begin(p_step TEXT, p_details TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.migration_state (step_key, started_at, status, details)
    VALUES (p_step, clock_timestamp(), 'running', p_details)
    ON CONFLICT (step_key) DO UPDATE
        SET started_at  = clock_timestamp(),
            finished_at = NULL,
            status      = 'running',
            details     = COALESCE(EXCLUDED.details, migration_state.details);

    INSERT INTO public.migration_log (step_key, level, message)
    VALUES (p_step, 'INFO', 'BEGIN ' || COALESCE(p_details, ''));

    RAISE NOTICE '[%] BEGIN %  %', clock_timestamp(), p_step, COALESCE(p_details, '');
END $$;

CREATE OR REPLACE FUNCTION public._mig_end(p_step TEXT, p_details TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.migration_state
       SET finished_at = clock_timestamp(),
           status      = 'done',
           details     = COALESCE(p_details, details)
     WHERE step_key = p_step;

    INSERT INTO public.migration_log (step_key, level, message)
    VALUES (p_step, 'INFO', 'END ' || COALESCE(p_details, ''));

    RAISE NOTICE '[%] END   %  %', clock_timestamp(), p_step, COALESCE(p_details, '');
END $$;

SELECT public._mig_begin('00_migration_state', 'control tables ready');
SELECT public._mig_end  ('00_migration_state', 'ok');


-- =============================================================================
-- Step 01 — Backup íntegro del schema legacy en lti_backup
-- -----------------------------------------------------------------------------
-- LOCK SHARE: lecturas OK, escrituras esperan al COMMIT/ROLLBACK final → ningún
-- INSERT puede colarse entre el snapshot y la migración de datos posterior.
-- lti_backup NO se borra automáticamente; un humano lo elimina tras validar.
-- =============================================================================
SELECT public._mig_begin('01_backup_legacy', 'lock + clone Candidate/Education/WorkExperience/Resume into lti_backup');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema='public' AND table_name='Candidate') THEN
        EXECUTE 'LOCK TABLE public."Candidate", public."Education", public."WorkExperience", public."Resume" IN SHARE MODE';
    ELSE
        RAISE EXCEPTION 'Schema legacy no encontrado: la tabla "Candidate" no existe en public. La migración inicial 20260504165247_init debe haberse aplicado antes.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS lti_backup;
COMMENT ON SCHEMA lti_backup IS 'Snapshot del schema legacy previo a la migración 20260504190000_to_ats_schema. Eliminar manualmente tras validación.';

DROP TABLE IF EXISTS lti_backup."Candidate"      CASCADE;
DROP TABLE IF EXISTS lti_backup."Education"      CASCADE;
DROP TABLE IF EXISTS lti_backup."WorkExperience" CASCADE;
DROP TABLE IF EXISTS lti_backup."Resume"         CASCADE;

CREATE TABLE lti_backup."Candidate"      AS TABLE public."Candidate"      WITH DATA;
CREATE TABLE lti_backup."Education"      AS TABLE public."Education"      WITH DATA;
CREATE TABLE lti_backup."WorkExperience" AS TABLE public."WorkExperience" WITH DATA;
CREATE TABLE lti_backup."Resume"         AS TABLE public."Resume"         WITH DATA;

DROP TABLE IF EXISTS lti_backup._sequence_state;
CREATE TABLE lti_backup._sequence_state (
    sequence_name TEXT PRIMARY KEY,
    last_value    BIGINT NOT NULL,
    is_called     BOOLEAN NOT NULL
);

INSERT INTO lti_backup._sequence_state (sequence_name, last_value, is_called)
SELECT 'Candidate_id_seq',      last_value, is_called FROM public."Candidate_id_seq"      UNION ALL
SELECT 'Education_id_seq',      last_value, is_called FROM public."Education_id_seq"      UNION ALL
SELECT 'WorkExperience_id_seq', last_value, is_called FROM public."WorkExperience_id_seq" UNION ALL
SELECT 'Resume_id_seq',         last_value, is_called FROM public."Resume_id_seq";

DO $$
DECLARE
    src_count BIGINT;
    bak_count BIGINT;
BEGIN
    FOR src_count, bak_count IN
        SELECT (SELECT COUNT(*) FROM public."Candidate"),      (SELECT COUNT(*) FROM lti_backup."Candidate")      UNION ALL
        SELECT (SELECT COUNT(*) FROM public."Education"),      (SELECT COUNT(*) FROM lti_backup."Education")      UNION ALL
        SELECT (SELECT COUNT(*) FROM public."WorkExperience"), (SELECT COUNT(*) FROM lti_backup."WorkExperience") UNION ALL
        SELECT (SELECT COUNT(*) FROM public."Resume"),         (SELECT COUNT(*) FROM lti_backup."Resume")
    LOOP
        IF src_count IS DISTINCT FROM bak_count THEN
            RAISE EXCEPTION 'Backup count mismatch: % vs %', src_count, bak_count;
        END IF;
    END LOOP;
END $$;

SELECT public._mig_end('01_backup_legacy',
    format('rows: candidate=%s education=%s work_experience=%s resume=%s',
        (SELECT COUNT(*) FROM lti_backup."Candidate"),
        (SELECT COUNT(*) FROM lti_backup."Education"),
        (SELECT COUNT(*) FROM lti_backup."WorkExperience"),
        (SELECT COUNT(*) FROM lti_backup."Resume")));


-- =============================================================================
-- Step 02 — Tablas catálogo: company, employee, interview_type, interview_flow
-- =============================================================================
SELECT public._mig_begin('02_create_catalog', 'company, employee, interview_type, interview_flow');

-- company.description sustituye al antiguo POSITION.company_description (3FN).
CREATE TABLE public.company (
    id          SERIAL    PRIMARY KEY,
    name        VARCHAR(150) NOT NULL,
    description TEXT
);

COMMENT ON TABLE  public.company             IS 'Empresas que publican posiciones en la plataforma.';
COMMENT ON COLUMN public.company.description IS 'Descripción corporativa reutilizada en todas las posiciones de la empresa.';

CREATE UNIQUE INDEX company_name_uniq ON public.company (LOWER(name));

CREATE TABLE public.employee (
    id         SERIAL    PRIMARY KEY,
    company_id INTEGER       NOT NULL,
    name       VARCHAR(200) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    role       VARCHAR(40)  NOT NULL,
    is_active  BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT employee_role_chk CHECK (role IN ('admin','recruiter','interviewer','manager','hiring_manager')),
    CONSTRAINT employee_email_uniq UNIQUE (email)
);

COMMENT ON TABLE  public.employee           IS 'Personal de cada empresa (recruiters, entrevistadores, etc.).';
COMMENT ON COLUMN public.employee.role      IS 'Rol funcional. Valores admitidos: admin | recruiter | interviewer | manager | hiring_manager.';
COMMENT ON COLUMN public.employee.is_active IS 'Soft-delete: false = baja, conservado por integridad referencial con interview.';

CREATE TABLE public.interview_type (
    id          SERIAL    PRIMARY KEY,
    name        VARCHAR(80)  NOT NULL,
    description TEXT,
    CONSTRAINT interview_type_name_uniq UNIQUE (name)
);

COMMENT ON TABLE public.interview_type IS 'Catálogo de tipos de entrevista (technical, hr, cultural-fit, etc.). Reutilizable entre flows.';

CREATE TABLE public.interview_flow (
    id          SERIAL PRIMARY KEY,
    description VARCHAR(255) NOT NULL
);

COMMENT ON TABLE public.interview_flow IS 'Flujo de entrevistas reutilizable. Una posición referencia un flow; el flow agrupa los steps en orden.';

SELECT public._mig_end('02_create_catalog', 'ok');


-- =============================================================================
-- Step 03 — interview_step
-- =============================================================================
SELECT public._mig_begin('03_create_workflow', 'interview_step');

CREATE TABLE public.interview_step (
    id                SERIAL    PRIMARY KEY,
    interview_flow_id INTEGER       NOT NULL,
    interview_type_id INTEGER       NOT NULL,
    name              VARCHAR(120) NOT NULL,
    order_index       INTEGER      NOT NULL,
    CONSTRAINT interview_step_order_chk CHECK (order_index >= 0),
    CONSTRAINT interview_step_flow_order_uniq UNIQUE (interview_flow_id, order_index)
);

COMMENT ON TABLE  public.interview_step             IS 'Paso concreto dentro de un interview_flow. order_index define la secuencia.';
COMMENT ON COLUMN public.interview_step.order_index IS 'Posición 0-based dentro del flow. Único por flow.';

SELECT public._mig_end('03_create_workflow', 'ok');


-- =============================================================================
-- Step 04 — position, application, interview
-- =============================================================================
SELECT public._mig_begin('04_create_jobs', 'position, application, interview');

CREATE TABLE public.position (
    id                    SERIAL     PRIMARY KEY,
    company_id            INTEGER        NOT NULL,
    interview_flow_id     INTEGER        NOT NULL,
    title                 VARCHAR(150)  NOT NULL,
    description           TEXT,
    status                VARCHAR(20)   NOT NULL DEFAULT 'draft',
    is_visible            BOOLEAN       NOT NULL DEFAULT FALSE,
    location              VARCHAR(150),
    job_description       TEXT,
    requirements          TEXT,
    responsibilities      TEXT,
    salary_min            NUMERIC(12,2),
    salary_max            NUMERIC(12,2),
    employment_type       VARCHAR(20)   NOT NULL DEFAULT 'full_time',
    benefits              TEXT,
    application_deadline  DATE,
    contact_info          VARCHAR(255),
    CONSTRAINT position_status_chk
        CHECK (status IN ('draft','open','paused','closed','filled')),
    CONSTRAINT position_employment_type_chk
        CHECK (employment_type IN ('full_time','part_time','contract','internship','freelance','temporary')),
    CONSTRAINT position_salary_range_chk
        CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_max >= salary_min),
    CONSTRAINT position_salary_nonneg_chk
        CHECK ((salary_min IS NULL OR salary_min >= 0) AND (salary_max IS NULL OR salary_max >= 0))
);

COMMENT ON TABLE  public.position                      IS 'Oferta de empleo publicada por una empresa, asociada a un interview_flow.';
COMMENT ON COLUMN public.position.status               IS 'Ciclo de vida. Valores: draft | open | paused | closed | filled.';
COMMENT ON COLUMN public.position.is_visible           IS 'Controla si la oferta es pública (independiente del status).';
COMMENT ON COLUMN public.position.employment_type      IS 'Tipo de contratación. Valores: full_time | part_time | contract | internship | freelance | temporary.';
COMMENT ON COLUMN public.position.salary_min           IS 'Salario anual mínimo. NULL = no especificado.';
COMMENT ON COLUMN public.position.salary_max           IS 'Salario anual máximo. Si ambos no nulos, debe ser >= salary_min.';
COMMENT ON COLUMN public.position.application_deadline IS 'Fecha límite para aplicar. NULL = sin deadline.';

CREATE TABLE public.application (
    id               SERIAL   PRIMARY KEY,
    position_id      INTEGER      NOT NULL,
    candidate_id     INTEGER      NOT NULL,
    application_date DATE        NOT NULL DEFAULT CURRENT_DATE,
    status           VARCHAR(20) NOT NULL DEFAULT 'submitted',
    notes            TEXT,
    CONSTRAINT application_status_chk
        CHECK (status IN ('submitted','under_review','interview','offer','hired','rejected','withdrawn')),
    CONSTRAINT application_position_candidate_uniq UNIQUE (position_id, candidate_id)
);

COMMENT ON TABLE  public.application        IS 'Aplicación de un candidato a una posición. Único por (position_id, candidate_id).';
COMMENT ON COLUMN public.application.status IS 'Estado del proceso. Valores: submitted | under_review | interview | offer | hired | rejected | withdrawn.';

CREATE TABLE public.interview (
    id                SERIAL    PRIMARY KEY,
    application_id    INTEGER       NOT NULL,
    interview_step_id INTEGER       NOT NULL,
    employee_id       INTEGER       NOT NULL,
    interview_date    TIMESTAMPTZ  NOT NULL,
    result            VARCHAR(20)  NOT NULL DEFAULT 'pending',
    score             SMALLINT,
    notes             TEXT,
    CONSTRAINT interview_result_chk
        CHECK (result IN ('pending','passed','failed','no_show','cancelled')),
    CONSTRAINT interview_score_chk
        CHECK (score IS NULL OR (score BETWEEN 0 AND 100))
);

COMMENT ON TABLE  public.interview                IS 'Entrevista concreta: liga una application a un step y al employee entrevistador.';
COMMENT ON COLUMN public.interview.interview_date IS 'Momento programado/realizado de la entrevista (TZ-aware).';
COMMENT ON COLUMN public.interview.result         IS 'Resultado. Valores: pending | passed | failed | no_show | cancelled.';
COMMENT ON COLUMN public.interview.score          IS 'Puntuación 0..100. NULL si aún no evaluada.';

SELECT public._mig_end('04_create_jobs', 'ok');


-- =============================================================================
-- Step 05 — candidate (snake_case, sustituye a "Candidate")
-- =============================================================================
SELECT public._mig_begin('05_create_candidate', 'candidate');

CREATE TABLE public.candidate (
    id         SERIAL    PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name  VARCHAR(100) NOT NULL,
    email      VARCHAR(255) NOT NULL,
    phone      VARCHAR(30),
    address    VARCHAR(255),
    CONSTRAINT candidate_email_uniq UNIQUE (email)
);

COMMENT ON TABLE  public.candidate       IS 'Persona aspirante. Una fila por individuo único (UNIQUE por email).';
COMMENT ON COLUMN public.candidate.email IS 'Identificador funcional del candidato. Único.';
COMMENT ON COLUMN public.candidate.phone IS 'Teléfono libre formato (incluye prefijos internacionales). Hasta 30 chars.';

-- Búsqueda habitual: apellido, luego nombre (case-insensitive).
CREATE INDEX candidate_name_idx ON public.candidate (LOWER(last_name), LOWER(first_name));

SELECT public._mig_end('05_create_candidate', 'ok');


-- =============================================================================
-- Step 06 — education, work_experience, resume (legacy conservado, snake_case)
-- -----------------------------------------------------------------------------
-- start_date/end_date pasan de TIMESTAMP(3) a DATE (sin pérdida en la práctica:
-- las fechas académicas/laborales no llevan hora real). work_experience.position
-- → position_title para evitar choque con la tabla position del nuevo modelo.
-- =============================================================================
SELECT public._mig_begin('06_create_legacy_kept', 'education, work_experience, resume');

CREATE TABLE public.education (
    id           SERIAL    PRIMARY KEY,
    candidate_id INTEGER       NOT NULL,
    institution  VARCHAR(150) NOT NULL,
    title        VARCHAR(250) NOT NULL,
    start_date   DATE         NOT NULL,
    end_date     DATE,
    CONSTRAINT education_dates_chk CHECK (end_date IS NULL OR end_date >= start_date)
);

COMMENT ON TABLE public.education IS 'Formación académica del candidato. Conservada del modelo legacy.';

CREATE TABLE public.work_experience (
    id             SERIAL    PRIMARY KEY,
    candidate_id   INTEGER       NOT NULL,
    company_name   VARCHAR(150) NOT NULL,
    position_title VARCHAR(150) NOT NULL,
    description    VARCHAR(500),
    start_date     DATE         NOT NULL,
    end_date       DATE,
    CONSTRAINT work_experience_dates_chk CHECK (end_date IS NULL OR end_date >= start_date)
);

COMMENT ON TABLE  public.work_experience                IS 'Experiencia laboral previa del candidato. Texto libre, no enlazada a public.company.';
COMMENT ON COLUMN public.work_experience.company_name   IS 'Nombre de la empresa donde trabajó (texto libre).';
COMMENT ON COLUMN public.work_experience.position_title IS 'Cargo desempeñado. Renombrado desde el legacy "position" para no chocar con la tabla position.';

CREATE TABLE public.resume (
    id           SERIAL    PRIMARY KEY,
    candidate_id INTEGER       NOT NULL,
    file_path    VARCHAR(500) NOT NULL,
    file_type    VARCHAR(50)  NOT NULL,
    upload_date  TIMESTAMPTZ  NOT NULL
);

COMMENT ON TABLE  public.resume           IS 'CV/resume subido por el candidato. file_path apunta al storage configurado en backend.';
COMMENT ON COLUMN public.resume.file_type IS 'MIME type del fichero (ej. application/pdf).';

SELECT public._mig_end('06_create_legacy_kept', 'ok');


-- =============================================================================
-- Step 07 — Migración de datos: "Candidate" → candidate (preservando IDs)
-- =============================================================================
SELECT public._mig_begin('07_migrate_candidate', 'copy "Candidate" rows preserving id');

INSERT INTO public.candidate (id, first_name, last_name, email, phone, address)
SELECT id, "firstName", "lastName", email, phone, address
  FROM public."Candidate";

SELECT setval('public.candidate_id_seq',
              GREATEST(COALESCE((SELECT MAX(id) FROM public.candidate), 0), 1),
              (SELECT MAX(id) FROM public.candidate) IS NOT NULL);

DO $$
DECLARE
    c_old BIGINT := (SELECT COUNT(*) FROM public."Candidate");
    c_new BIGINT := (SELECT COUNT(*) FROM public.candidate);
BEGIN
    IF c_old <> c_new THEN
        RAISE EXCEPTION 'candidate row count mismatch: legacy=% new=%', c_old, c_new;
    END IF;
END $$;

SELECT public._mig_end('07_migrate_candidate',
    format('rows=%s', (SELECT COUNT(*) FROM public.candidate)));


-- =============================================================================
-- Step 08 — Migración de datos: Education / WorkExperience / Resume
-- =============================================================================
SELECT public._mig_begin('08_migrate_subtables', 'copy Education/WorkExperience/Resume preserving ids');

INSERT INTO public.education (id, candidate_id, institution, title, start_date, end_date)
SELECT id, "candidateId", institution, title, "startDate"::date, "endDate"::date
  FROM public."Education";

SELECT setval('public.education_id_seq',
              GREATEST(COALESCE((SELECT MAX(id) FROM public.education), 0), 1),
              (SELECT MAX(id) FROM public.education) IS NOT NULL);

INSERT INTO public.work_experience (id, candidate_id, company_name, position_title, description, start_date, end_date)
SELECT id, "candidateId", company, "position", description, "startDate"::date, "endDate"::date
  FROM public."WorkExperience";

SELECT setval('public.work_experience_id_seq',
              GREATEST(COALESCE((SELECT MAX(id) FROM public.work_experience), 0), 1),
              (SELECT MAX(id) FROM public.work_experience) IS NOT NULL);

INSERT INTO public.resume (id, candidate_id, file_path, file_type, upload_date)
SELECT id, "candidateId", "filePath", "fileType", "uploadDate"::timestamptz
  FROM public."Resume";

SELECT setval('public.resume_id_seq',
              GREATEST(COALESCE((SELECT MAX(id) FROM public.resume), 0), 1),
              (SELECT MAX(id) FROM public.resume) IS NOT NULL);

DO $$
DECLARE
    pair RECORD;
BEGIN
    FOR pair IN
        SELECT 'education'::text       AS tbl, (SELECT COUNT(*) FROM public."Education")      AS old_c, (SELECT COUNT(*) FROM public.education)       AS new_c UNION ALL
        SELECT 'work_experience'::text,         (SELECT COUNT(*) FROM public."WorkExperience"),        (SELECT COUNT(*) FROM public.work_experience)            UNION ALL
        SELECT 'resume'::text,                  (SELECT COUNT(*) FROM public."Resume"),                (SELECT COUNT(*) FROM public.resume)
    LOOP
        IF pair.old_c <> pair.new_c THEN
            RAISE EXCEPTION '% row count mismatch: legacy=% new=%', pair.tbl, pair.old_c, pair.new_c;
        END IF;
    END LOOP;
END $$;

SELECT public._mig_end('08_migrate_subtables',
    format('education=%s work_experience=%s resume=%s',
        (SELECT COUNT(*) FROM public.education),
        (SELECT COUNT(*) FROM public.work_experience),
        (SELECT COUNT(*) FROM public.resume)));


-- =============================================================================
-- Step 09 — DROP de tablas legacy
-- =============================================================================
SELECT public._mig_begin('09_drop_legacy', 'drop "Candidate"/"Education"/"WorkExperience"/"Resume"');

DROP TABLE IF EXISTS public."Resume"         CASCADE;
DROP TABLE IF EXISTS public."WorkExperience" CASCADE;
DROP TABLE IF EXISTS public."Education"      CASCADE;
DROP TABLE IF EXISTS public."Candidate"      CASCADE;

DO $$
DECLARE
    leftover TEXT;
BEGIN
    SELECT string_agg(table_name, ', ')
      INTO leftover
      FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name IN ('Candidate','Education','WorkExperience','Resume');

    IF leftover IS NOT NULL THEN
        RAISE EXCEPTION 'Legacy tables still present after drop: %', leftover;
    END IF;
END $$;

SELECT public._mig_end('09_drop_legacy', 'ok');


-- =============================================================================
-- Step 10 — Foreign keys
-- -----------------------------------------------------------------------------
-- ON DELETE RESTRICT por defecto (evita borrados accidentales con dependencias).
-- ON DELETE CASCADE en interview→application y en education/work_experience/
-- resume → candidate (semántica natural).
-- =============================================================================
SELECT public._mig_begin('10_constraints_fk', 'add FKs across new schema');

ALTER TABLE public.employee
    ADD CONSTRAINT employee_company_fk
    FOREIGN KEY (company_id) REFERENCES public.company(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.interview_step
    ADD CONSTRAINT interview_step_flow_fk
    FOREIGN KEY (interview_flow_id) REFERENCES public.interview_flow(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.interview_step
    ADD CONSTRAINT interview_step_type_fk
    FOREIGN KEY (interview_type_id) REFERENCES public.interview_type(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.position
    ADD CONSTRAINT position_company_fk
    FOREIGN KEY (company_id) REFERENCES public.company(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.position
    ADD CONSTRAINT position_interview_flow_fk
    FOREIGN KEY (interview_flow_id) REFERENCES public.interview_flow(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.application
    ADD CONSTRAINT application_position_fk
    FOREIGN KEY (position_id) REFERENCES public.position(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.application
    ADD CONSTRAINT application_candidate_fk
    FOREIGN KEY (candidate_id) REFERENCES public.candidate(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.interview
    ADD CONSTRAINT interview_application_fk
    FOREIGN KEY (application_id) REFERENCES public.application(id)
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public.interview
    ADD CONSTRAINT interview_step_fk
    FOREIGN KEY (interview_step_id) REFERENCES public.interview_step(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.interview
    ADD CONSTRAINT interview_employee_fk
    FOREIGN KEY (employee_id) REFERENCES public.employee(id)
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE public.education
    ADD CONSTRAINT education_candidate_fk
    FOREIGN KEY (candidate_id) REFERENCES public.candidate(id)
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public.work_experience
    ADD CONSTRAINT work_experience_candidate_fk
    FOREIGN KEY (candidate_id) REFERENCES public.candidate(id)
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE public.resume
    ADD CONSTRAINT resume_candidate_fk
    FOREIGN KEY (candidate_id) REFERENCES public.candidate(id)
    ON DELETE CASCADE ON UPDATE CASCADE;

SELECT public._mig_end('10_constraints_fk', 'ok');


-- =============================================================================
-- Step 11 — Índices secundarios
-- -----------------------------------------------------------------------------
-- PostgreSQL crea automáticamente índice en PK y UNIQUE, pero NO en FK. Aquí
-- añadimos los necesarios para JOIN/CASCADE checks + filtros funcionales típicos.
-- =============================================================================
SELECT public._mig_begin('11_indexes', 'secondary indexes');

CREATE INDEX employee_company_idx              ON public.employee        (company_id);
CREATE INDEX interview_step_flow_idx           ON public.interview_step  (interview_flow_id);
CREATE INDEX interview_step_type_idx           ON public.interview_step  (interview_type_id);
CREATE INDEX position_company_idx              ON public.position        (company_id);
CREATE INDEX position_interview_flow_idx       ON public.position        (interview_flow_id);
CREATE INDEX application_position_idx          ON public.application     (position_id);
CREATE INDEX application_candidate_idx         ON public.application     (candidate_id);
CREATE INDEX interview_application_idx         ON public.interview       (application_id);
CREATE INDEX interview_step_id_idx             ON public.interview       (interview_step_id);
CREATE INDEX interview_employee_idx            ON public.interview       (employee_id);
CREATE INDEX education_candidate_idx           ON public.education       (candidate_id);
CREATE INDEX work_experience_candidate_idx     ON public.work_experience (candidate_id);
CREATE INDEX resume_candidate_idx              ON public.resume          (candidate_id);

CREATE INDEX position_status_idx        ON public.position    (status)        WHERE status IN ('open','paused');
CREATE INDEX position_visible_idx       ON public.position    (is_visible)    WHERE is_visible = TRUE;
CREATE INDEX application_status_idx     ON public.application (status);
CREATE INDEX interview_date_idx         ON public.interview   (interview_date);

SELECT public._mig_end('11_indexes', 'ok');


-- =============================================================================
-- Step 12 — Re-alineación final de secuencias
-- =============================================================================
SELECT public._mig_begin('12_reset_sequences', 'finalize sequence state');

DO $$
DECLARE
    r RECORD;
    sql TEXT;
BEGIN
    FOR r IN
        SELECT t.table_name, c.column_name,
               pg_get_serial_sequence(format('public.%I', t.table_name), c.column_name) AS seq
          FROM information_schema.tables t
          JOIN information_schema.columns c
            ON c.table_schema = t.table_schema
           AND c.table_name   = t.table_name
         WHERE t.table_schema = 'public'
           AND t.table_name IN (
               'company','employee','interview_type','interview_flow','interview_step',
               'position','application','interview',
               'candidate','education','work_experience','resume'
           )
           AND c.column_name = 'id'
    LOOP
        IF r.seq IS NULL THEN
            CONTINUE;
        END IF;
        -- Tabla vacía: setval(seq, 1, false) ⇒ próximo nextval = 1.
        -- Con datos:    setval(seq, MAX(id), true) ⇒ próximo nextval = MAX(id)+1.
        sql := format(
            'SELECT setval(%L, GREATEST(COALESCE((SELECT MAX(id) FROM public.%I), 0), 1), (SELECT MAX(id) FROM public.%I) IS NOT NULL)',
            r.seq, r.table_name, r.table_name
        );
        EXECUTE sql;
    END LOOP;
END $$;

SELECT public._mig_end('12_reset_sequences', 'ok');


-- =============================================================================
-- Marca de cierre — útil para que verify.sql / rollback.sql sepan que la
-- migración llegó al final.
-- =============================================================================
INSERT INTO public.migration_state (step_key, started_at, finished_at, status, details)
VALUES ('99_committed', clock_timestamp(), clock_timestamp(), 'done', 'all steps completed')
ON CONFLICT (step_key) DO UPDATE
   SET finished_at = clock_timestamp(),
       status      = 'done',
       details     = 'all steps completed (re-run)';
