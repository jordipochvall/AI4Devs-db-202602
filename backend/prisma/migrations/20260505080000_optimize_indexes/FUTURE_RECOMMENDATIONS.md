# Recomendaciones de índices — pendientes (D y E)

Estos dos índices se identificaron en el análisis pero **no se aplican aún**: tienen sentido sólo cuando exista código que los necesite. Crearlos ahora paga el coste (escritura, almacenamiento) sin obtener el beneficio (no hay queries que los usen).

Cuando se añadan los endpoints correspondientes, aplicar como migración nueva.

---

## D) Búsqueda fuzzy de candidatos por nombre (`pg_trgm` + GIN)

### Cuándo aplicar
Cuando aparezca un endpoint tipo `GET /candidates?search=...` que use `ILIKE '%algo%'` o similar sobre `first_name` / `last_name`.

### Por qué el índice actual no basta
`candidate_name_idx` es un B-tree sobre `(LOWER(last_name), LOWER(first_name))`. Sirve para igualdad y prefijos del primer campo (`LOWER(last_name) = 'sa'` o `LIKE 'sa%'` con `text_pattern_ops` — que tampoco tiene). **No** sirve para coincidencia parcial del tipo `ILIKE '%alb%'`, que es el patrón habitual de un buscador interactivo.

### Solución propuesta

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX candidate_name_trgm_idx
    ON public.candidate
    USING gin ((LOWER(first_name) || ' ' || LOWER(last_name)) gin_trgm_ops);
```

Permite acelerar `WHERE LOWER(first_name) || ' ' || LOWER(last_name) ILIKE '%alb%sael%'` con búsqueda por trigramas.

### Coste
- GIN ocupa ~2-3× lo que un B-tree equivalente.
- Penaliza `INSERT`/`UPDATE` en `candidate` más que un B-tree.
- En PostgreSQL la extensión `pg_trgm` viene con el contrib estándar — sin dependencias externas.

### Alternativa más sencilla
Si el caso de uso es sólo "autocompletar por inicio de apellido" (`LIKE 'sa%'`, no `'%sa%'`), basta con cambiar el índice existente a usar `text_pattern_ops`:

```sql
DROP INDEX candidate_name_idx;
CREATE INDEX candidate_name_idx
    ON public.candidate (LOWER(last_name) varchar_pattern_ops, LOWER(first_name) varchar_pattern_ops);
```

Más barato y sin extensión, pero no cubre búsqueda por subcadena.

---

## E) `position(application_deadline)` parcial — vacantes próximas a cerrar

### Cuándo aplicar
Cuando aparezca un endpoint del portal del candidato tipo "vacantes que cierran pronto", típicamente:

```sql
SELECT * FROM position
 WHERE is_visible = true
   AND status = 'open'
   AND application_deadline > now()
 ORDER BY application_deadline ASC
 LIMIT 20;
```

### Por qué los índices actuales no bastan
`position_visible_idx` y `position_status_idx` son parciales sin `application_deadline`, así que el planner los puede usar para filtrar pero la ordenación posterior por deadline requiere un sort. Con datasets grandes, eso domina el coste.

### Solución propuesta

```sql
CREATE INDEX position_deadline_idx
    ON public.position (application_deadline)
    WHERE is_visible = true
      AND status     = 'open'
      AND application_deadline IS NOT NULL;
```

El predicado parcial mantiene el índice mínimo (sólo vacantes "vivas con deadline") y permite index scan ordenado nativo. Cubre además el filtro de "ya cerradas" si se invierte el filtro.

### Coste
Mínimo. Sólo crece con el subconjunto de posiciones abiertas con deadline — típicamente cientos como mucho.

---

## Cómo aplicar cuando llegue el momento

1. Crear nueva migración: `npx prisma migrate dev --name search_or_deadline_indexes` (en dev) o un fichero `migration.sql` manual con timestamp posterior.
2. Si toca `pg_trgm`, asegurarse de que el usuario de aplicación tiene permiso `CREATE EXTENSION` o pre-crearla con superuser.
3. Validar con `EXPLAIN ANALYZE` antes y después contra datos representativos.
4. Si el índice no acelera (cardinalidad real distinta de la esperada), revertir.
