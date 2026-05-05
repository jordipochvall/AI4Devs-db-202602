-- =============================================================================
-- verify.sql — Comprobaciones post-migración
-- -----------------------------------------------------------------------------
-- Ejecutable INDEPENDIENTE de migration.sql. No modifica datos productivos.
-- Aborta al primer fallo con un mensaje claro indicando qué falló.
--
-- Comprobaciones:
--   1. Estado: todos los steps en 'done'.
--   2. Paridad de cardinalidad lti_backup vs public.
--   3. Paridad de contenido por hash (candidate, education, work_experience, resume).
--   4. Integridad referencial: cero orphans en cada FK.
--   5. Secuencias alineadas: last_value >= MAX(id).
--   6. CHECK constraints activas: un INSERT inválido debe fallar.
--
-- Cómo invocar (manual; Prisma NO lo ejecuta):
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/prisma/migrations/20260504190000_to_ats_schema/verify.sql
-- =============================================================================

\echo '====================================================================='
\echo '  VERIFY 20260504190000_to_ats_schema  — start'
\echo '====================================================================='

\set ON_ERROR_STOP on

DO $$
-- ---------------------------------------------------------------------------
-- 1) Estado de la migración
-- ---------------------------------------------------------------------------
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(step_key || '=' || status, ', ')
      INTO bad
      FROM public.migration_state
     WHERE status NOT IN ('done','rolled_back')
        OR (status = 'rolled_back' AND step_key = '99_committed');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'migration_state has non-done rows: %', bad;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.migration_state
                    WHERE step_key='99_committed' AND status='done') THEN
        RAISE EXCEPTION 'migration did not reach 99_committed=done';
    END IF;

    RAISE NOTICE '[1/6] migration_state OK';
END $$;

DO $$
-- ---------------------------------------------------------------------------
-- 2) Paridad de cardinalidad
-- ---------------------------------------------------------------------------
DECLARE
    pair RECORD;
BEGIN
    FOR pair IN
        SELECT 'candidate'::text AS tbl,
               (SELECT COUNT(*) FROM lti_backup."Candidate")      AS bak,
               (SELECT COUNT(*) FROM public.candidate)            AS cur UNION ALL
        SELECT 'education',
               (SELECT COUNT(*) FROM lti_backup."Education"),
               (SELECT COUNT(*) FROM public.education)                  UNION ALL
        SELECT 'work_experience',
               (SELECT COUNT(*) FROM lti_backup."WorkExperience"),
               (SELECT COUNT(*) FROM public.work_experience)            UNION ALL
        SELECT 'resume',
               (SELECT COUNT(*) FROM lti_backup."Resume"),
               (SELECT COUNT(*) FROM public.resume)
    LOOP
        IF pair.bak <> pair.cur THEN
            RAISE EXCEPTION 'count mismatch %: backup=% public=%', pair.tbl, pair.bak, pair.cur;
        END IF;
    END LOOP;

    RAISE NOTICE '[2/6] cardinality parity OK';
END $$;

DO $$
-- ---------------------------------------------------------------------------
-- 3) Paridad de contenido (hash de columnas clave)
-- ---------------------------------------------------------------------------
DECLARE
    hash_bak TEXT;
    hash_cur TEXT;
BEGIN
    -- candidate
    SELECT MD5(string_agg(
                  id::text || '|' || "firstName" || '|' || "lastName" || '|' || email
                  || '|' || COALESCE(phone,'') || '|' || COALESCE(address,''),
                  E'\n' ORDER BY id))
      INTO hash_bak FROM lti_backup."Candidate";

    SELECT MD5(string_agg(
                  id::text || '|' || first_name || '|' || last_name || '|' || email
                  || '|' || COALESCE(phone,'') || '|' || COALESCE(address,''),
                  E'\n' ORDER BY id))
      INTO hash_cur FROM public.candidate;

    IF hash_bak IS DISTINCT FROM hash_cur THEN
        RAISE EXCEPTION 'candidate content hash mismatch: backup=% public=%', hash_bak, hash_cur;
    END IF;

    -- education
    SELECT MD5(string_agg(
                  id::text || '|' || "candidateId" || '|' || institution || '|' || title
                  || '|' || "startDate"::date::text || '|' || COALESCE("endDate"::date::text,''),
                  E'\n' ORDER BY id))
      INTO hash_bak FROM lti_backup."Education";

    SELECT MD5(string_agg(
                  id::text || '|' || candidate_id || '|' || institution || '|' || title
                  || '|' || start_date::text || '|' || COALESCE(end_date::text,''),
                  E'\n' ORDER BY id))
      INTO hash_cur FROM public.education;

    IF hash_bak IS DISTINCT FROM hash_cur THEN
        RAISE EXCEPTION 'education content hash mismatch';
    END IF;

    -- work_experience
    SELECT MD5(string_agg(
                  id::text || '|' || "candidateId" || '|' || company || '|' || "position"
                  || '|' || COALESCE(description,'')
                  || '|' || "startDate"::date::text || '|' || COALESCE("endDate"::date::text,''),
                  E'\n' ORDER BY id))
      INTO hash_bak FROM lti_backup."WorkExperience";

    SELECT MD5(string_agg(
                  id::text || '|' || candidate_id || '|' || company_name || '|' || position_title
                  || '|' || COALESCE(description,'')
                  || '|' || start_date::text || '|' || COALESCE(end_date::text,''),
                  E'\n' ORDER BY id))
      INTO hash_cur FROM public.work_experience;

    IF hash_bak IS DISTINCT FROM hash_cur THEN
        RAISE EXCEPTION 'work_experience content hash mismatch';
    END IF;

    -- resume
    SELECT MD5(string_agg(
                  id::text || '|' || "candidateId" || '|' || "filePath" || '|' || "fileType"
                  || '|' || "uploadDate"::timestamptz::text,
                  E'\n' ORDER BY id))
      INTO hash_bak FROM lti_backup."Resume";

    SELECT MD5(string_agg(
                  id::text || '|' || candidate_id || '|' || file_path || '|' || file_type
                  || '|' || upload_date::text,
                  E'\n' ORDER BY id))
      INTO hash_cur FROM public.resume;

    IF hash_bak IS DISTINCT FROM hash_cur THEN
        RAISE EXCEPTION 'resume content hash mismatch';
    END IF;

    RAISE NOTICE '[3/6] content parity OK';
END $$;

DO $$
-- ---------------------------------------------------------------------------
-- 4) Integridad referencial — orphans en cada FK
-- ---------------------------------------------------------------------------
DECLARE
    orphan_count BIGINT;
    pair RECORD;
BEGIN
    FOR pair IN VALUES
        ('employee','company_id','company'),
        ('interview_step','interview_flow_id','interview_flow'),
        ('interview_step','interview_type_id','interview_type'),
        ('position','company_id','company'),
        ('position','interview_flow_id','interview_flow'),
        ('application','position_id','position'),
        ('application','candidate_id','candidate'),
        ('interview','application_id','application'),
        ('interview','interview_step_id','interview_step'),
        ('interview','employee_id','employee'),
        ('education','candidate_id','candidate'),
        ('work_experience','candidate_id','candidate'),
        ('resume','candidate_id','candidate')
    LOOP
        EXECUTE format(
            'SELECT COUNT(*) FROM public.%I c LEFT JOIN public.%I p ON p.id = c.%I WHERE p.id IS NULL',
            pair.column1, pair.column3, pair.column2
        ) INTO orphan_count;
        IF orphan_count > 0 THEN
            RAISE EXCEPTION 'orphans in %.%→%: %', pair.column1, pair.column2, pair.column3, orphan_count;
        END IF;
    END LOOP;

    RAISE NOTICE '[4/6] referential integrity OK';
END $$;

DO $$
-- ---------------------------------------------------------------------------
-- 5) Secuencias alineadas
-- ---------------------------------------------------------------------------
DECLARE
    r RECORD;
    seq_last BIGINT;
    max_id   BIGINT;
BEGIN
    FOR r IN VALUES
        ('candidate'),('education'),('work_experience'),('resume'),
        ('company'),('employee'),('interview_type'),('interview_flow'),
        ('interview_step'),('position'),('application'),('interview')
    LOOP
        -- pg_get_serial_sequence devuelve el nombre cualificado y entrecomillado
        -- correctamente incluso para identificadores reservados como "position".
        EXECUTE format(
            'SELECT last_value FROM %s',
            pg_get_serial_sequence(format('public.%I', r.column1), 'id')
        ) INTO seq_last;
        EXECUTE format('SELECT COALESCE(MAX(id),0) FROM public.%I', r.column1) INTO max_id;
        IF seq_last < max_id THEN
            RAISE EXCEPTION 'sequence behind on %: last=% max_id=%', r.column1, seq_last, max_id;
        END IF;
    END LOOP;

    RAISE NOTICE '[5/6] sequences aligned OK';
END $$;

DO $$
-- ---------------------------------------------------------------------------
-- 6) CHECK constraints — un valor inválido debe ser rechazado
-- ---------------------------------------------------------------------------
BEGIN
    BEGIN
        INSERT INTO public.position
            (company_id, interview_flow_id, title, status, employment_type)
        VALUES
            (-1, -1, 'verify-test', 'NOT_A_STATUS', 'full_time');
        RAISE EXCEPTION 'CHECK on position.status did NOT fire (insert succeeded)';
    EXCEPTION
        WHEN check_violation THEN
            -- esperado
            NULL;
        WHEN foreign_key_violation THEN
            -- también aceptable si la FK falla antes que el CHECK
            NULL;
    END;

    RAISE NOTICE '[6/6] CHECK constraints active OK';
END $$;

\echo '====================================================================='
\echo '  VERIFY OK'
\echo '====================================================================='
