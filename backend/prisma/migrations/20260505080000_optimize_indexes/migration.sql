-- =============================================================================
-- Migration 20260505080000_optimize_indexes
-- -----------------------------------------------------------------------------
-- Optimización de índices basada en el análisis de las consultas que la app
-- ejecutará al exponer endpoints típicos de un ATS (pipeline de vacante,
-- agenda del entrevistador, portal del candidato).
--
-- Objetivo: cubrir los patrones de query habituales con índices compuestos
-- bien diseñados, reduciendo además el número total de índices al absorber
-- los simples redundantes (los compuestos sirven también al prefijo izquierdo).
--
-- Cambios netos:
--   public.application: 3 índices secundarios → 2 (uno menos)
--   public.interview:   3 índices secundarios → 3 (mismo, mejor cobertura)
--
-- Recomendaciones futuras (D y E del análisis) en FUTURE_RECOMMENDATIONS.md.
-- =============================================================================


-- A) application(position_id, status) compuesto
-- -----------------------------------------------------------------------------
-- Query objetivo: "pipeline de la vacante X" — listar aplicaciones de una
-- posición filtrando opcionalmente por status (submitted, under_review, ...).
--
-- Por qué compuesto:
--   * El prefijo izquierdo (position_id) sirve también al filtro "todas las
--     apps de esta posición" → absorbe a application_position_idx.
--   * El filtro `status` solo (sin position_id) tiene baja cardinalidad
--     (~7 valores), el planner suele preferir seq scan → application_status_idx
--     standalone aporta poco. Lo retiramos.
DROP INDEX IF EXISTS public.application_position_idx;
DROP INDEX IF EXISTS public.application_status_idx;

CREATE INDEX application_position_status_idx
    ON public.application (position_id, status);


-- B) interview(employee_id, interview_date) compuesto
-- -----------------------------------------------------------------------------
-- Query objetivo: "mi agenda" — interview_date BETWEEN x AND y filtrando por
-- entrevistador. Es el caso de uso #1 del rol interviewer.
--
-- Por qué compuesto:
--   * Permite index range scan: filtra por employee_id y barre por
--     interview_date sin sort posterior.
--   * El prefijo izquierdo cubre "todas las entrevistas de este empleado"
--     → absorbe a interview_employee_idx.
--   * interview_date_idx (global) se conserva: sirve a queries cross-team
--     ("entrevistas de hoy en toda la empresa", reporting).
DROP INDEX IF EXISTS public.interview_employee_idx;

CREATE INDEX interview_employee_date_idx
    ON public.interview (employee_id, interview_date);


-- C) application(candidate_id, application_date DESC) compuesto
-- -----------------------------------------------------------------------------
-- Query objetivo: "portal del candidato" — listar mis aplicaciones ordenadas
-- de más reciente a más antigua.
--
-- Por qué compuesto:
--   * `DESC` en application_date elimina el sort posterior al index range scan.
--   * El prefijo izquierdo (candidate_id) cubre la query simple
--     → absorbe a application_candidate_idx.
DROP INDEX IF EXISTS public.application_candidate_idx;

CREATE INDEX application_candidate_date_idx
    ON public.application (candidate_id, application_date DESC);
