--
-- PostgreSQL database dump
--

\restrict W9hriDSQZZnDrCyEADjVKCIitKgZSAdTK6oxPoYCI53SC2mlH4r6Xak1nKBv1vm

-- Dumped from database version 16.4
-- Dumped by pg_dump version 16.14

-- Started on 2026-07-18 21:19:45

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 11 (class 2615 OID 292994)
-- Name: thesession; Type: SCHEMA; Schema: -; Owner: folkguitar
--

CREATE SCHEMA thesession;


ALTER SCHEMA thesession OWNER TO folkguitar;

--
-- TOC entry 1170 (class 1255 OID 807356)
-- Name: abc_clean_for_melody(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.abc_clean_for_melody(p_abc text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    s text;
BEGIN
    s := COALESCE(p_abc, '');

    -- remove line noise
    s := regexp_replace(s, E'[\\r\\n\\t]+', ' ', 'g');

    -- remove chord/text annotations: "Em", "D", etc.
    s := regexp_replace(s, '"[^"]*"', '', 'g');

    -- remove grace notes and decorations
    s := regexp_replace(s, '\{[^}]*\}', '', 'g');
    s := regexp_replace(s, '![^!]*!', '', 'g');

    -- remove inline ABC headers such as K:D, K:AMix, M:6/8
    s := regexp_replace(s, '(^|[[:space:]])[A-Z]:[^|[:space:]]*', ' ', 'g');

    -- remove tuplets, e.g. (3GFG -> GFG
    s := regexp_replace(s, '\([0-9]+', '', 'g');

    -- remove first/second ending markers
    s := regexp_replace(s, '\[[0-9]+', '', 'g');

    -- strip accidentals completely
    s := regexp_replace(s, '[\^_=]+', '', 'g');

    -- remove slurs/brackets/broken rhythm markers
    s := regexp_replace(s, '[\[\]\(\)<>]', '', 'g');

    -- simplify repeat markers but preserve barlines
    s := replace(s, ':', '');

    -- normalize whitespace
    s := regexp_replace(s, '[[:space:]]+', ' ', 'g');

    RETURN btrim(s);
END;
$$;


ALTER FUNCTION thesession.abc_clean_for_melody(p_abc text) OWNER TO folkguitar;

--
-- TOC entry 1171 (class 1255 OID 807357)
-- Name: abc_token_pitch(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.abc_token_pitch(p_token text) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    n text;
    base integer;
    oct integer := 0;
BEGIN
    n := substring(p_token from '^[A-Ga-g]');

    base := CASE upper(n)
        WHEN 'C' THEN 0
        WHEN 'D' THEN 2
        WHEN 'E' THEN 4
        WHEN 'F' THEN 5
        WHEN 'G' THEN 7
        WHEN 'A' THEN 9
        WHEN 'B' THEN 11
    END;

    IF n = lower(n) THEN
        oct := oct + 12;
    END IF;

    oct := oct + ((length(p_token) - length(replace(p_token, '''', ''))) * 12);
    oct := oct - ((length(p_token) - length(replace(p_token, ',', ''))) * 12);

    RETURN base + oct;
END;
$$;


ALTER FUNCTION thesession.abc_token_pitch(p_token text) OWNER TO folkguitar;

--
-- TOC entry 1181 (class 1255 OID 862099)
-- Name: abc_token_repeat_count(text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.abc_token_repeat_count(p_token text, p_max_repeat integer DEFAULT 2) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT GREATEST(
        1,
        LEAST(
            COALESCE(
                NULLIF(substring(thesession.abc_token_rhythm(p_token) FROM '^[0-9]+'), '')::integer,
                1
            ),
            GREATEST(p_max_repeat, 1)
        )
    );
$$;


ALTER FUNCTION thesession.abc_token_repeat_count(p_token text, p_max_repeat integer) OWNER TO folkguitar;

--
-- TOC entry 1172 (class 1255 OID 807358)
-- Name: abc_token_rhythm(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.abc_token_rhythm(p_token text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    r text;
BEGIN
    r := regexp_replace(p_token, '^[A-Ga-g][,'']*', '');

    IF r IS NULL OR r = '' THEN
        RETURN '1';
    END IF;

    RETURN r;
END;
$$;


ALTER FUNCTION thesession.abc_token_rhythm(p_token text) OWNER TO folkguitar;

--
-- TOC entry 1183 (class 1255 OID 869091)
-- Name: compare_melody_edit_distance(text, text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.compare_melody_edit_distance(p_query_abc text, p_candidate_abc text) RETURNS TABLE(query_intervals text, candidate_intervals text, edit_distance integer, max_length integer, similarity_pct numeric)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    a text[];
    b text[];
    m integer;
    n integer;
    i integer;
    j integer;
    cost integer;
    prev integer[];
    curr integer[];
BEGIN
    SELECT string_to_array(interval_fingerprint, ',')
    INTO a
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_query_abc);

    SELECT string_to_array(interval_fingerprint, ',')
    INTO b
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_candidate_abc);

    m := COALESCE(array_length(a, 1), 0);
    n := COALESCE(array_length(b, 1), 0);

    IF m = 0 OR n = 0 THEN
        RETURN QUERY SELECT
            array_to_string(a, ','),
            array_to_string(b, ','),
            NULL::integer,
            GREATEST(m, n),
            0::numeric;
        RETURN;
    END IF;

    prev := ARRAY[]::integer[];

    FOR j IN 0..n LOOP
        prev := array_append(prev, j);
    END LOOP;

    FOR i IN 1..m LOOP
        curr := ARRAY[i];

        FOR j IN 1..n LOOP
            cost := CASE WHEN a[i] = b[j] THEN 0 ELSE 1 END;

            curr := array_append(
                curr,
                LEAST(
                    prev[j + 1] + 1,      -- deletion
                    curr[j] + 1,          -- insertion
                    prev[j] + cost        -- substitution
                )
            );
        END LOOP;

        prev := curr;
    END LOOP;

    RETURN QUERY SELECT
        array_to_string(a, ','),
        array_to_string(b, ','),
        prev[n + 1],
        GREATEST(m, n),
        ROUND((1 - (prev[n + 1]::numeric / GREATEST(m, n))) * 100, 2);
END;
$$;


ALTER FUNCTION thesession.compare_melody_edit_distance(p_query_abc text, p_candidate_abc text) OWNER TO folkguitar;

--
-- TOC entry 1187 (class 1255 OID 870477)
-- Name: compare_melody_edit_distance_from_intervals(text, text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.compare_melody_edit_distance_from_intervals(p_query_intervals text, p_candidate_abc text) RETURNS TABLE(query_intervals text, candidate_intervals text, edit_distance integer, max_length integer, similarity_pct numeric)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    a text[];
    b text[];
    m integer;
    n integer;
    i integer;
    j integer;
    cost integer;
    prev integer[];
    curr integer[];
BEGIN
    a := string_to_array(p_query_intervals, ',');

    SELECT string_to_array(interval_fingerprint, ',')
    INTO b
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_candidate_abc);

    m := COALESCE(array_length(a, 1), 0);
    n := COALESCE(array_length(b, 1), 0);

    IF m = 0 OR n = 0 THEN
        RETURN QUERY SELECT
            array_to_string(a, ','),
            array_to_string(b, ','),
            NULL::integer,
            GREATEST(m, n),
            0::numeric;
        RETURN;
    END IF;

    prev := ARRAY[]::integer[];

    FOR j IN 0..n LOOP
        prev := array_append(prev, j);
    END LOOP;

    FOR i IN 1..m LOOP
        curr := ARRAY[i];

        FOR j IN 1..n LOOP
            cost := CASE WHEN a[i] = b[j] THEN 0 ELSE 1 END;

            curr := array_append(
                curr,
                LEAST(
                    prev[j + 1] + 1,
                    curr[j] + 1,
                    prev[j] + cost
                )
            );
        END LOOP;

        prev := curr;
    END LOOP;

    RETURN QUERY SELECT
        array_to_string(a, ','),
        array_to_string(b, ','),
        prev[n + 1],
        GREATEST(m, n),
        ROUND((1 - (prev[n + 1]::numeric / GREATEST(m, n))) * 100, 2);
END;
$$;


ALTER FUNCTION thesession.compare_melody_edit_distance_from_intervals(p_query_intervals text, p_candidate_abc text) OWNER TO folkguitar;

--
-- TOC entry 1179 (class 1255 OID 858758)
-- Name: compare_melody_fingerprints(text, text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.compare_melody_fingerprints(p_abc_1 text, p_abc_2 text) RETURNS TABLE(interval_1 text, interval_2 text, contour_1 text, contour_2 text, coarse_1 text, coarse_2 text, interval_match_pct numeric, contour_match_pct numeric, coarse_match_pct numeric)
    LANGUAGE sql STABLE
    AS $$
WITH f1 AS (
    SELECT
        interval_fingerprint,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse
    FROM thesession.melody_2bar_fingerprint_from_abc(p_abc_1)
),

f2 AS (
    SELECT
        interval_fingerprint,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse
    FROM thesession.melody_2bar_fingerprint_from_abc(p_abc_2)
),

interval_compare AS (
    SELECT
        count(*) FILTER (WHERE a.val = b.val)::numeric AS matches,
        greatest(count(*), 1)::numeric AS total
    FROM (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f1,
        unnest(string_to_array(interval_fingerprint, ',')) val
    ) a
    FULL OUTER JOIN (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f2,
        unnest(string_to_array(interval_fingerprint, ',')) val
    ) b
      ON a.rn = b.rn
),

contour_compare AS (
    SELECT
        count(*) FILTER (WHERE a.val = b.val)::numeric AS matches,
        greatest(count(*), 1)::numeric AS total
    FROM (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f1,
        unnest(string_to_array(contour, ',')) val
    ) a
    FULL OUTER JOIN (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f2,
        unnest(string_to_array(contour, ',')) val
    ) b
      ON a.rn = b.rn
),

coarse_compare AS (
    SELECT
        count(*) FILTER (WHERE a.val = b.val)::numeric AS matches,
        greatest(count(*), 1)::numeric AS total
    FROM (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f1,
        unnest(string_to_array(coarse, ',')) val
    ) a
    FULL OUTER JOIN (
        SELECT
            row_number() OVER () AS rn,
            val
        FROM f2,
        unnest(string_to_array(coarse, ',')) val
    ) b
      ON a.rn = b.rn
)

SELECT
    f1.interval_fingerprint,
    f2.interval_fingerprint,
    f1.contour,
    f2.contour,
    f1.coarse,
    f2.coarse,

    round(
        (ic.matches / NULLIF(ic.total, 0)) * 100,
        2
    ) AS interval_match_pct,

    round(
        (cc.matches / NULLIF(cc.total, 0)) * 100,
        2
    ) AS contour_match_pct,

    round(
        (coc.matches / NULLIF(coc.total, 0)) * 100,
        2
    ) AS coarse_match_pct

FROM f1
CROSS JOIN f2
CROSS JOIN interval_compare ic
CROSS JOIN contour_compare cc
CROSS JOIN coarse_compare coc;
$$;


ALTER FUNCTION thesession.compare_melody_fingerprints(p_abc_1 text, p_abc_2 text) OWNER TO folkguitar;

--
-- TOC entry 1180 (class 1255 OID 858759)
-- Name: compare_melody_ngram_overlap(text, text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.compare_melody_ngram_overlap(p_abc_1 text, p_abc_2 text, p_ngram_size integer DEFAULT 4) RETURNS TABLE(interval_overlap_pct numeric, contour_overlap_pct numeric, coarse_overlap_pct numeric, shared_interval_ngrams text[], shared_contour_ngrams text[], shared_coarse_ngrams text[])
    LANGUAGE sql STABLE
    AS $$
WITH f1 AS (
    SELECT
        interval_fingerprint,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse
    FROM thesession.melody_2bar_fingerprint_from_abc(p_abc_1)
),

f2 AS (
    SELECT
        interval_fingerprint,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse
    FROM thesession.melody_2bar_fingerprint_from_abc(p_abc_2)
),

parts AS (
    SELECT
        string_to_array(f1.interval_fingerprint, ',') AS i1,
        string_to_array(f2.interval_fingerprint, ',') AS i2,
        string_to_array(f1.contour, ',') AS c1,
        string_to_array(f2.contour, ',') AS c2,
        string_to_array(f1.coarse, ',') AS co1,
        string_to_array(f2.coarse, ',') AS co2
    FROM f1
    CROSS JOIN f2
),

interval_ngrams_1 AS (
    SELECT DISTINCT
        array_to_string(i1[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(i1, 1) - p_ngram_size + 1, 0)
    ) pos
),

interval_ngrams_2 AS (
    SELECT DISTINCT
        array_to_string(i2[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(i2, 1) - p_ngram_size + 1, 0)
    ) pos
),

shared_interval AS (
    SELECT array_agg(ng ORDER BY ng) AS vals
    FROM (
        SELECT ng
        FROM interval_ngrams_1
        INTERSECT
        SELECT ng
        FROM interval_ngrams_2
    ) x
),

contour_ngrams_1 AS (
    SELECT DISTINCT
        array_to_string(c1[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(c1, 1) - p_ngram_size + 1, 0)
    ) pos
),

contour_ngrams_2 AS (
    SELECT DISTINCT
        array_to_string(c2[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(c2, 1) - p_ngram_size + 1, 0)
    ) pos
),

shared_contour AS (
    SELECT array_agg(ng ORDER BY ng) AS vals
    FROM (
        SELECT ng
        FROM contour_ngrams_1
        INTERSECT
        SELECT ng
        FROM contour_ngrams_2
    ) x
),

coarse_ngrams_1 AS (
    SELECT DISTINCT
        array_to_string(co1[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(co1, 1) - p_ngram_size + 1, 0)
    ) pos
),

coarse_ngrams_2 AS (
    SELECT DISTINCT
        array_to_string(co2[pos:(pos + p_ngram_size - 1)], ',') AS ng
    FROM parts,
    generate_series(
        1,
        greatest(array_length(co2, 1) - p_ngram_size + 1, 0)
    ) pos
),

shared_coarse AS (
    SELECT array_agg(ng ORDER BY ng) AS vals
    FROM (
        SELECT ng
        FROM coarse_ngrams_1
        INTERSECT
        SELECT ng
        FROM coarse_ngrams_2
    ) x
)

SELECT
    round(
        (
            cardinality(COALESCE(si.vals, ARRAY[]::text[]))::numeric
            /
            greatest(
                (
                    SELECT count(*)
                    FROM interval_ngrams_1
                ),
                1
            )
        ) * 100,
        2
    ) AS interval_overlap_pct,

    round(
        (
            cardinality(COALESCE(sc.vals, ARRAY[]::text[]))::numeric
            /
            greatest(
                (
                    SELECT count(*)
                    FROM contour_ngrams_1
                ),
                1
            )
        ) * 100,
        2
    ) AS contour_overlap_pct,

    round(
        (
            cardinality(COALESCE(sco.vals, ARRAY[]::text[]))::numeric
            /
            greatest(
                (
                    SELECT count(*)
                    FROM coarse_ngrams_1
                ),
                1
            )
        ) * 100,
        2
    ) AS coarse_overlap_pct,

    COALESCE(si.vals, ARRAY[]::text[]),
    COALESCE(sc.vals, ARRAY[]::text[]),
    COALESCE(sco.vals, ARRAY[]::text[])

FROM shared_interval si
CROSS JOIN shared_contour sc
CROSS JOIN shared_coarse sco;
$$;


ALTER FUNCTION thesession.compare_melody_ngram_overlap(p_abc_1 text, p_abc_2 text, p_ngram_size integer) OWNER TO folkguitar;

--
-- TOC entry 1174 (class 1255 OID 807391)
-- Name: melody_2bar_fingerprint_from_abc(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.melody_2bar_fingerprint_from_abc(p_abc text) RETURNS TABLE(bar_count integer, note_count integer, interval_fingerprint text, rhythm_fingerprint text)
    LANGUAGE sql STABLE
    AS $$
WITH clean AS (
    SELECT thesession.abc_clean_for_melody(p_abc) AS abc
),
bars AS (
    SELECT
        row_number() OVER (ORDER BY raw_bar_number)::integer AS bar_number,
        raw_bar_number,
        btrim(bar_text) AS bar_text
    FROM clean
    CROSS JOIN LATERAL regexp_split_to_table(abc, '\|+') WITH ORDINALITY AS b(bar_text, raw_bar_number)
    WHERE btrim(bar_text) <> ''
),
notes AS (
    SELECT
        b.bar_number,
        m.note_order,
        thesession.abc_token_pitch((m.matches)[1]) AS pitch,
        thesession.abc_token_rhythm((m.matches)[1]) AS rhythm
    FROM bars b
    CROSS JOIN LATERAL regexp_matches(
        b.bar_text,
        '([A-Ga-g][,'']*[0-9/]*)',
        'g'
    ) WITH ORDINALITY AS m(matches, note_order)
),
rollup AS (
    SELECT
        count(DISTINCT bar_number)::integer AS bar_count,
        count(*)::integer AS note_count,
        array_agg(pitch ORDER BY bar_number, note_order) AS pitches,
        array_agg(rhythm ORDER BY bar_number, note_order) AS rhythms
    FROM notes
)
SELECT
    bar_count,
    note_count,
    thesession.melody_interval_fingerprint(pitches) AS interval_fingerprint,
    array_to_string(rhythms, ',') AS rhythm_fingerprint
FROM rollup;
$$;


ALTER FUNCTION thesession.melody_2bar_fingerprint_from_abc(p_abc text) OWNER TO folkguitar;

--
-- TOC entry 1182 (class 1255 OID 862100)
-- Name: melody_2bar_fuzzy_fingerprint_from_abc(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_abc text) RETURNS TABLE(bar_count integer, note_count integer, interval_fingerprint text, rhythm_fingerprint text)
    LANGUAGE sql STABLE
    AS $$
WITH clean AS (
    SELECT thesession.abc_clean_for_melody(p_abc) AS abc
),
bars AS (
    SELECT
        row_number() OVER (ORDER BY raw_bar_number)::integer AS bar_number,
        raw_bar_number,
        btrim(bar_text) AS bar_text
    FROM clean
    CROSS JOIN LATERAL regexp_split_to_table(abc, '\|+') WITH ORDINALITY AS b(bar_text, raw_bar_number)
    WHERE btrim(bar_text) <> ''
),
notes AS (
    SELECT
        b.bar_number,
        m.note_order,
        r.repeat_order,
        thesession.abc_token_pitch((m.matches)[1]) AS pitch,
        '1'::text AS rhythm
    FROM bars b
    CROSS JOIN LATERAL regexp_matches(
        b.bar_text,
        '([A-Ga-g][,'']*[0-9/]*)',
        'g'
    ) WITH ORDINALITY AS m(matches, note_order)
    CROSS JOIN LATERAL generate_series(
        1,
        thesession.abc_token_repeat_count((m.matches)[1], 3)
    ) AS r(repeat_order)
),
rollup AS (
    SELECT
        count(DISTINCT bar_number)::integer AS bar_count,
        count(*)::integer AS note_count,
        array_agg(pitch ORDER BY bar_number, note_order, repeat_order) AS pitches,
        array_agg(rhythm ORDER BY bar_number, note_order, repeat_order) AS rhythms
    FROM notes
)
SELECT
    bar_count,
    note_count,
    thesession.melody_interval_fingerprint(pitches) AS interval_fingerprint,
    array_to_string(rhythms, ',') AS rhythm_fingerprint
FROM rollup;
$$;


ALTER FUNCTION thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_abc text) OWNER TO folkguitar;

--
-- TOC entry 1178 (class 1255 OID 858754)
-- Name: melody_coarse_interval_fingerprint(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.melody_coarse_interval_fingerprint(p_interval_fingerprint text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT array_to_string(
        ARRAY(
            SELECT
                CASE
                    WHEN x::integer = 0 THEN 'S'
                    WHEN x::integer BETWEEN 1 AND 2 THEN 'u'
                    WHEN x::integer > 2 THEN 'U'
                    WHEN x::integer BETWEEN -2 AND -1 THEN 'd'
                    WHEN x::integer < -2 THEN 'D'
                END
            FROM unnest(string_to_array(COALESCE(p_interval_fingerprint, ''), ',')) AS t(x)
            WHERE btrim(x) <> ''
        ),
        ','
    );
$$;


ALTER FUNCTION thesession.melody_coarse_interval_fingerprint(p_interval_fingerprint text) OWNER TO folkguitar;

--
-- TOC entry 1177 (class 1255 OID 858753)
-- Name: melody_contour_fingerprint(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.melody_contour_fingerprint(p_interval_fingerprint text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT array_to_string(
        ARRAY(
            SELECT
                CASE
                    WHEN x::integer > 0 THEN 'U'
                    WHEN x::integer < 0 THEN 'D'
                    ELSE 'S'
                END
            FROM unnest(string_to_array(COALESCE(p_interval_fingerprint, ''), ',')) AS t(x)
            WHERE btrim(x) <> ''
        ),
        ','
    );
$$;


ALTER FUNCTION thesession.melody_contour_fingerprint(p_interval_fingerprint text) OWNER TO folkguitar;

--
-- TOC entry 1173 (class 1255 OID 807359)
-- Name: melody_interval_fingerprint(integer[]); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.melody_interval_fingerprint(p_pitches integer[]) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT array_to_string(
        ARRAY(
            SELECT (p_pitches[i + 1] - p_pitches[i])::text
            FROM generate_subscripts(p_pitches, 1) AS g(i)
            WHERE i < array_length(p_pitches, 1)
            ORDER BY i
        ),
        ','
    );
$$;


ALTER FUNCTION thesession.melody_interval_fingerprint(p_pitches integer[]) OWNER TO folkguitar;

--
-- TOC entry 1175 (class 1255 OID 807435)
-- Name: search_melody_2bar(text, text, text, text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.search_melody_2bar(p_abc text, p_rhythm_mode text DEFAULT 'soft'::text, p_type text DEFAULT NULL::text, p_meter text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(tune_id bigint, tune_name text, type text, meter text, mode text, tunebooks integer, star_rating integer, has_recording_albums boolean, matching_settings bigint, matching_fragments bigint, has_exact_rhythm_match boolean, best_bar_start integer, best_sample_match text, score numeric)
    LANGUAGE sql STABLE
    AS $$
WITH q AS (
    SELECT *
    FROM thesession.melody_2bar_fingerprint_from_abc(p_abc)
    WHERE bar_count = 2
),
matches AS (
    SELECT
        f.*,
        q.rhythm_fingerprint AS query_rhythm_fingerprint,
        (f.rhythm_fingerprint = q.rhythm_fingerprint) AS exact_rhythm_match
    FROM q
    JOIN thesession.mv_melody_2bar_fragments_v5 f
      ON f.interval_fingerprint = q.interval_fingerprint
    WHERE (p_rhythm_mode <> 'hard' OR f.rhythm_fingerprint = q.rhythm_fingerprint)
      AND (p_type IS NULL OR lower(f.type) = lower(p_type))
      AND (p_meter IS NULL OR f.meter = p_meter)
),
ranked_fragments AS (
    SELECT
        m.*,
        row_number() OVER (
            PARTITION BY m.tune_id
            ORDER BY
                m.exact_rhythm_match DESC,
                m.bar_start,
                m.setting_id
        ) AS rn
    FROM matches m
),
rollup AS (
    SELECT
        m.tune_id,
        min(m.name) AS tune_name,
        min(m.type) AS type,
        min(m.meter) AS meter,
        min(m.mode) AS mode,
        count(DISTINCT m.setting_id) AS matching_settings,
        count(*) AS matching_fragments,
        bool_or(m.exact_rhythm_match) AS has_exact_rhythm_match,

        (
            SELECT rf.bar_start
            FROM ranked_fragments rf
            WHERE rf.tune_id = m.tune_id
              AND rf.rn = 1
        ) AS best_bar_start,

        (
            SELECT rf.bar_1_text || ' | ' || rf.bar_2_text
            FROM ranked_fragments rf
            WHERE rf.tune_id = m.tune_id
              AND rf.rn = 1
        ) AS best_sample_match
    FROM matches m
    GROUP BY m.tune_id
)
SELECT
    r.tune_id,
    COALESCE(tm.primary_name, r.tune_name) AS tune_name,
    COALESCE(tm.type, r.type) AS type,
    COALESCE(tm.meter, r.meter) AS meter,
    COALESCE(tm.mode, r.mode) AS mode,
    tm.tunebooks,
    tm.star_rating,
    COALESCE(tm.has_recording_albums, false) AS has_recording_albums,
    r.matching_settings,
    r.matching_fragments,
    r.has_exact_rhythm_match,
    r.best_bar_start,
    r.best_sample_match,

    (
        r.matching_settings::numeric * 10
        + r.matching_fragments::numeric
        + CASE WHEN r.has_exact_rhythm_match THEN 25 ELSE 0 END
        + COALESCE(tm.star_rating, 0)::numeric * 5
        + CASE
            WHEN COALESCE(tm.tunebooks, 0) >= 200 THEN 10
            WHEN COALESCE(tm.tunebooks, 0) >= 100 THEN 7
            WHEN COALESCE(tm.tunebooks, 0) >= 50 THEN 5
            WHEN COALESCE(tm.tunebooks, 0) >= 20 THEN 3
            ELSE 0
          END
        + CASE WHEN COALESCE(tm.has_recording_albums, false) THEN 5 ELSE 0 END
    ) AS score
FROM rollup r
LEFT JOIN thesession.mv_tune_meta tm
  ON tm.tune_id = r.tune_id
ORDER BY
    score DESC,
    r.has_exact_rhythm_match DESC,
    r.matching_settings DESC,
    r.matching_fragments DESC,
    tune_name
LIMIT p_limit;
$$;


ALTER FUNCTION thesession.search_melody_2bar(p_abc text, p_rhythm_mode text, p_type text, p_meter text, p_limit integer) OWNER TO folkguitar;

--
-- TOC entry 1192 (class 1255 OID 889768)
-- Name: search_melody_2bar_fuzzy_stage2_v5(text, text, text, text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.search_melody_2bar_fuzzy_stage2_v5(p_abc text, p_rhythm_mode text DEFAULT 'soft'::text, p_type text DEFAULT NULL::text, p_meter text DEFAULT NULL::text, p_limit integer DEFAULT 100) RETURNS TABLE(tune_id bigint, tune_name text, type text, meter text, mode text, tunebooks integer, star_rating integer, has_recording_albums boolean, matching_settings bigint, matching_fragments bigint, shared_ngrams bigint, query_ngrams integer, coverage_pct numeric, has_rhythm_ngram_match boolean, best_bar_start integer, best_sample_match text, score numeric)
    LANGUAGE sql STABLE
    AS $$
WITH q AS (
    SELECT
        *,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour_fingerprint,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse_fingerprint,
        string_to_array(interval_fingerprint, ',') AS interval_parts,
        string_to_array(thesession.melody_coarse_interval_fingerprint(interval_fingerprint), ',') AS coarse_interval_parts,
        string_to_array(rhythm_fingerprint, ',') AS rhythm_parts
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_abc)
    WHERE bar_count = 2
),

query_ngrams_all AS (
    SELECT
        gs.pos AS query_ngram_position,
        array_to_string(q.interval_parts[gs.pos:(gs.pos + 3)], ',') AS interval_ngram,
        array_to_string(q.coarse_interval_parts[gs.pos:(gs.pos + 3)], ',') AS coarse_interval_ngram,
        array_to_string(q.rhythm_parts[gs.pos:(gs.pos + 4)], ',') AS rhythm_ngram,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 1) AS total_ngram_positions
    FROM q
    CROSS JOIN LATERAL generate_series(
        1,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 0)
    ) gs(pos)
),

query_ngrams_ranked AS (
    SELECT
        qn.*,
        CASE
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions / 3.0) THEN 'early'
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions * 2.0 / 3.0) THEN 'middle'
            ELSE 'late'
        END AS phrase_zone,
        COALESCE(s.tune_count, 999999999) AS tune_count,
        COALESCE(s.fragment_count, 999999999) AS fragment_count,
        CASE
            WHEN s.fragment_count IS NULL THEN 0.10::numeric
            ELSE round((1.0 / ln(2 + s.fragment_count::numeric)), 6)
        END AS rarity_weight
    FROM query_ngrams_all qn
    LEFT JOIN thesession.mv_melody_2bar_ngram_stats_v5 s
      ON s.interval_ngram = qn.interval_ngram
    WHERE qn.interval_ngram IS NOT NULL
      AND btrim(qn.interval_ngram) <> ''
      AND COALESCE(s.tune_count, 999999999) <= 2500
      AND COALESCE(s.fragment_count, 999999999) <= 8250
),

query_ngrams AS (
    SELECT
        qnr.query_ngram_position,
        qnr.interval_ngram,
        qnr.coarse_interval_ngram,
        qnr.rhythm_ngram,
        qnr.rarity_weight,
        q.contour_fingerprint AS query_contour_fingerprint,
        q.coarse_fingerprint AS query_coarse_fingerprint,
        q.interval_fingerprint AS query_interval_fingerprint,
        count(*) OVER ()::integer AS query_ngram_count
    FROM (
        SELECT *
        FROM (
            SELECT
                qnr.*,
                row_number() OVER (
                    PARTITION BY qnr.phrase_zone
                    ORDER BY qnr.tune_count, qnr.fragment_count, qnr.query_ngram_position
                ) AS zone_rank
            FROM query_ngrams_ranked qnr
        ) x
        WHERE x.zone_rank <= 3
        ORDER BY query_ngram_position
        LIMIT 9
    ) qnr
    CROSS JOIN q
),

matches AS (
    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.query_interval_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        true AS exact_ngram_match,
        false AS coarse_ngram_match
    FROM query_ngrams qn
    JOIN thesession.mv_melody_2bar_fragment_ngrams_v5 f
      ON f.interval_ngram = qn.interval_ngram
    WHERE (p_type IS NULL OR f.type = p_type)
      AND (p_meter IS NULL OR f.meter = p_meter)

    UNION ALL

    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.query_interval_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        false AS exact_ngram_match,
        true AS coarse_ngram_match
	FROM (
	    SELECT *
	    FROM query_ngrams
	    WHERE rarity_weight >= 0.09
	    ORDER BY rarity_weight DESC
	    LIMIT 4
	) qn
	JOIN thesession.mv_melody_2bar_fragment_ngrams_v5 f
	  ON f.coarse_interval_ngram = qn.coarse_interval_ngram
	WHERE (p_type IS NULL OR f.type = p_type)
	  AND (p_meter IS NULL OR f.meter = p_meter)
	  AND f.interval_ngram <> qn.interval_ngram
	  AND abs(f.ngram_position - qn.query_ngram_position) <= 1
	),

fragment_query_hits AS (
    SELECT
        m.fragment_id,
        m.query_ngram_position,
        max(m.rarity_weight) AS rarity_weight,
        bool_or(m.rhythm_ngram_match) AS rhythm_ngram_match,
        bool_or(m.exact_ngram_match) AS exact_ngram_match,
        bool_or(m.coarse_ngram_match) AS coarse_ngram_match,
        max(
            CASE
                WHEN m.exact_ngram_match THEN 1.0
                WHEN m.coarse_ngram_match THEN 0.45
                ELSE 0.0
            END
        ) AS weighted_hit
    FROM matches m
    GROUP BY m.fragment_id, m.query_ngram_position
),

stage1_fragments AS (
    SELECT
        m.fragment_id,
        min(m.setting_id) AS setting_id,
        min(m.tune_id) AS tune_id,
        min(m.name) AS name,
        min(m.type) AS type,
        min(m.meter) AS meter,
        min(m.mode) AS mode,
        min(m.bar_start) AS bar_start,
        min(m.bar_1_text || ' | ' || m.bar_2_text) AS sample_match,
        count(DISTINCT h.query_ngram_position) AS shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.exact_ngram_match) AS exact_shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.coarse_ngram_match AND NOT h.exact_ngram_match) AS coarse_only_shared_ngrams,
        sum(h.weighted_hit) AS weighted_shared_ngrams,
        max(m.query_ngram_count) AS query_ngram_count,
        bool_or(h.rhythm_ngram_match) AS has_rhythm_ngram_match,
        sum(h.rarity_weight * h.weighted_hit) AS rarity_score,
        min(m.query_contour_fingerprint) AS query_contour_fingerprint,
        min(m.fragment_contour_fingerprint) AS fragment_contour_fingerprint,
        min(m.query_coarse_fingerprint) AS query_coarse_fingerprint,
        min(m.fragment_coarse_fingerprint) AS fragment_coarse_fingerprint,
        min(m.query_interval_fingerprint) AS query_interval_fingerprint
    FROM matches m
    JOIN fragment_query_hits h
      ON h.fragment_id = m.fragment_id
     AND h.query_ngram_position = m.query_ngram_position
    GROUP BY m.fragment_id
    HAVING (
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.exact_ngram_match) >= 2
        OR count(DISTINCT h.query_ngram_position) >= 4
    )
    AND (
        p_rhythm_mode <> 'hard'
        OR count(DISTINCT h.query_ngram_position) FILTER (WHERE h.rhythm_ngram_match) >= 2
    )
),

stage1_candidates AS (
    SELECT *
    FROM (
        SELECT
            s1.*,
            row_number() OVER (
                ORDER BY
                    s1.weighted_shared_ngrams DESC,
                    s1.exact_shared_ngrams DESC,
                    s1.rarity_score DESC,
                    s1.has_rhythm_ngram_match DESC,
                    s1.setting_id
            ) AS stage1_rank
        FROM stage1_fragments s1
    ) x
    WHERE x.stage1_rank <= 1100
),

fragment_position_runs AS (
    SELECT
        y.fragment_id,
        max(y.run_length)::integer AS max_consecutive_ngrams
    FROM (
        SELECT
            x.fragment_id,
            count(*) AS run_length
        FROM (
            SELECT
                h.fragment_id,
                h.query_ngram_position,
                h.query_ngram_position
                  - row_number() OVER (
                        PARTITION BY h.fragment_id
                        ORDER BY h.query_ngram_position
                    ) AS run_group
            FROM fragment_query_hits h
            JOIN stage1_candidates c
              ON c.fragment_id = h.fragment_id
        ) x
        GROUP BY x.fragment_id, x.run_group
    ) y
    GROUP BY y.fragment_id
),

ranked_fragments AS (
    SELECT
        c.*,
        COALESCE(r.max_consecutive_ngrams, 1) AS max_consecutive_ngrams,
		LEAST(
		    round(
		        (
		            c.weighted_shared_ngrams::numeric
		            / NULLIF(c.query_ngram_count, 0)::numeric
		        ) * 100,
		        2
		    ),
		    100
		) AS coverage_pct,
        CASE
            WHEN c.fragment_contour_fingerprint = c.query_contour_fingerprint THEN 20
            WHEN left(c.fragment_contour_fingerprint, 15) = left(c.query_contour_fingerprint, 15) THEN 10
            ELSE 0
        END AS contour_bonus,
        CASE
            WHEN c.fragment_coarse_fingerprint = c.query_coarse_fingerprint THEN 40
            WHEN left(c.fragment_coarse_fingerprint, 15) = left(c.query_coarse_fingerprint, 15) THEN 20
            ELSE 0
        END AS coarse_bonus,
        CASE
            WHEN COALESCE(r.max_consecutive_ngrams, 1) >= 6 THEN 140
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 5 THEN 100
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 4 THEN 65
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 3 THEN 30
            ELSE 0
        END AS continuity_bonus,
        row_number() OVER (
            PARTITION BY c.tune_id
            ORDER BY
                c.weighted_shared_ngrams DESC,
                c.exact_shared_ngrams DESC,
                COALESCE(r.max_consecutive_ngrams, 1) DESC,
                c.rarity_score DESC,
                c.has_rhythm_ngram_match DESC,
                c.setting_id
        ) AS rn
    FROM stage1_candidates c
    LEFT JOIN fragment_position_runs r
      ON r.fragment_id = c.fragment_id
),

candidate_fragments AS (
    SELECT *
    FROM (
        SELECT
            rf.*,
            row_number() OVER (
                ORDER BY
                    rf.weighted_shared_ngrams DESC,
                    rf.exact_shared_ngrams DESC,
                    rf.max_consecutive_ngrams DESC,
                    rf.rarity_score DESC,
                    rf.coverage_pct DESC
            ) AS candidate_rank
        FROM ranked_fragments rf
    ) x
    WHERE x.candidate_rank <= 350
),

reranked_fragments AS (
    SELECT
        cf.*,
        ed.edit_distance,
        ed.similarity_pct AS edit_similarity_pct,
        ROUND(ed.similarity_pct * 2.5)::integer AS edit_distance_bonus
    FROM candidate_fragments cf
    CROSS JOIN LATERAL thesession.compare_melody_edit_distance_from_intervals(
        cf.query_interval_fingerprint,
        '| ' || cf.sample_match || ' |'
    ) ed
),

rollup AS (
    SELECT
        rf.tune_id,
        min(rf.name) AS tune_name,
        min(rf.type) AS type,
        min(rf.meter) AS meter,
        min(rf.mode) AS mode,
        count(DISTINCT rf.setting_id) AS matching_settings,
        count(*) AS matching_fragments,
        max(rf.shared_ngrams) AS shared_ngrams,
        max(rf.exact_shared_ngrams) AS exact_shared_ngrams,
        max(rf.coarse_only_shared_ngrams) AS coarse_only_shared_ngrams,
        max(rf.weighted_shared_ngrams) AS weighted_shared_ngrams,
        max(rf.query_ngram_count) AS query_ngrams,
        max(rf.coverage_pct) AS coverage_pct,
        bool_or(rf.has_rhythm_ngram_match) AS has_rhythm_ngram_match,
        max(rf.rarity_score) AS rarity_score,
        max(rf.contour_bonus) AS contour_bonus,
        max(rf.coarse_bonus) AS coarse_bonus,
        max(rf.continuity_bonus) AS continuity_bonus,
        max(rf.edit_distance_bonus) AS edit_distance_bonus,
        min(rf.bar_start) FILTER (WHERE rf.rn = 1) AS best_bar_start,
        min(rf.sample_match) FILTER (WHERE rf.rn = 1) AS best_sample_match
    FROM reranked_fragments rf
    GROUP BY rf.tune_id
),

final_results AS (
    SELECT
        r.tune_id,
        COALESCE(tm.primary_name, r.tune_name) AS tune_name,
        COALESCE(tm.type, r.type) AS type,
        COALESCE(tm.meter, r.meter) AS meter,
        COALESCE(tm.mode, r.mode) AS mode,
        tm.tunebooks,
        tm.star_rating,
        COALESCE(tm.has_recording_albums, false) AS has_recording_albums,
        r.matching_settings,
        r.matching_fragments,
        r.shared_ngrams,
        r.query_ngrams,
        r.coverage_pct,
        r.has_rhythm_ngram_match,
        r.best_bar_start,
        r.best_sample_match,
        round(
            (
                r.coverage_pct::numeric * 2.0
                + r.weighted_shared_ngrams::numeric * 45.0
                + r.exact_shared_ngrams::numeric * 25.0
                + r.coarse_only_shared_ngrams::numeric * 8.0
                + r.rarity_score::numeric * 80.0
                + COALESCE(r.contour_bonus, 0)
                + COALESCE(r.coarse_bonus, 0)
                + COALESCE(r.continuity_bonus, 0)
                + COALESCE(r.edit_distance_bonus, 0)
				+ CASE
				    WHEN r.best_bar_start = 1 THEN 500
				    WHEN r.best_bar_start <= 4 THEN 250
				    WHEN r.best_bar_start <= 8 THEN 100
				    ELSE 0
				  END
				+ CASE WHEN r.has_rhythm_ngram_match THEN 10 ELSE 0 END
                + LEAST(r.matching_settings::numeric, 5) * 4
                + LEAST(r.matching_fragments::numeric, 10)
                + LEAST(COALESCE(tm.star_rating, 0)::numeric * 2, 10)
                + CASE
                    WHEN COALESCE(tm.tunebooks, 0) >= 200 THEN 5
                    WHEN COALESCE(tm.tunebooks, 0) >= 100 THEN 3
                    WHEN COALESCE(tm.tunebooks, 0) >= 50 THEN 2
                    ELSE 0
                  END
            )
        )::integer AS score
    FROM rollup r
    LEFT JOIN thesession.mv_tune_meta tm
      ON tm.tune_id = r.tune_id
    WHERE r.coverage_pct >= 20
)

SELECT
    fr.tune_id,
    fr.tune_name,
    fr.type,
    fr.meter,
    fr.mode,
    fr.tunebooks,
    fr.star_rating,
    fr.has_recording_albums,
    fr.matching_settings,
    fr.matching_fragments,
    fr.shared_ngrams,
    fr.query_ngrams,
    fr.coverage_pct,
    fr.has_rhythm_ngram_match,
    fr.best_bar_start,
    fr.best_sample_match,
    fr.score
FROM final_results fr
ORDER BY
    fr.score DESC,
    fr.coverage_pct DESC,
    fr.shared_ngrams DESC,
    fr.matching_settings DESC,
    fr.matching_fragments DESC,
    fr.tune_name
LIMIT p_limit;
$$;


ALTER FUNCTION thesession.search_melody_2bar_fuzzy_stage2_v5(p_abc text, p_rhythm_mode text, p_type text, p_meter text, p_limit integer) OWNER TO folkguitar;

--
-- TOC entry 409 (class 1255 OID 339894)
-- Name: slugify_unaccent(text); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.slugify_unaccent(input text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT trim(both '-' FROM
    regexp_replace(
      regexp_replace(
        lower(unaccent(replace(coalesce(input,''), '''', ''))),
        '[^a-z0-9]+', '-', 'g'
      ),
      '-+', '-', 'g'
    )
  );
$$;


ALTER FUNCTION thesession.slugify_unaccent(input text) OWNER TO folkguitar;

--
-- TOC entry 412 (class 1255 OID 339907)
-- Name: trg_set_slug_session_tunes_raw(); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.trg_set_slug_session_tunes_raw() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.slug := CASE
    WHEN NEW.name IS NULL THEN NULL
    ELSE thesession.slugify_unaccent(NEW.name)
  END;
  RETURN NEW;
END;
$$;


ALTER FUNCTION thesession.trg_set_slug_session_tunes_raw() OWNER TO folkguitar;

--
-- TOC entry 411 (class 1255 OID 339897)
-- Name: trg_set_slug_set_items(); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.trg_set_slug_set_items() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.slug := CASE
    WHEN NEW.name IS NULL THEN NULL
    ELSE thesession.slugify_unaccent(NEW.name)
  END;
  RETURN NEW;
END;
$$;


ALTER FUNCTION thesession.trg_set_slug_set_items() OWNER TO folkguitar;

--
-- TOC entry 410 (class 1255 OID 339895)
-- Name: trg_set_slug_tune_popularity(); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.trg_set_slug_tune_popularity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.slug := thesession.slugify_unaccent(NEW.name);
  RETURN NEW;
END;
$$;


ALTER FUNCTION thesession.trg_set_slug_tune_popularity() OWNER TO folkguitar;

--
-- TOC entry 1169 (class 1255 OID 436199)
-- Name: update_timestamp(); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.update_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
   NEW.updated_at = now();
   RETURN NEW;
END;
$$;


ALTER FUNCTION thesession.update_timestamp() OWNER TO folkguitar;

--
-- TOC entry 1176 (class 1255 OID 807822)
-- Name: zz_old_search_melody_2bar_fuzzy(text, text, text, text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.zz_old_search_melody_2bar_fuzzy(p_abc text, p_rhythm_mode text DEFAULT 'soft'::text, p_type text DEFAULT NULL::text, p_meter text DEFAULT NULL::text, p_limit integer DEFAULT 100) RETURNS TABLE(tune_id bigint, tune_name text, type text, meter text, mode text, tunebooks integer, star_rating integer, has_recording_albums boolean, matching_settings bigint, matching_fragments bigint, shared_ngrams bigint, query_ngrams integer, coverage_pct numeric, has_rhythm_ngram_match boolean, best_bar_start integer, best_sample_match text, score numeric)
    LANGUAGE sql STABLE
    AS $$
WITH q AS (
    SELECT
        *,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour_fingerprint,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse_fingerprint,
        string_to_array(interval_fingerprint, ',') AS interval_parts,
        string_to_array(thesession.melody_coarse_interval_fingerprint(interval_fingerprint), ',') AS coarse_interval_parts,
        string_to_array(rhythm_fingerprint, ',') AS rhythm_parts
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_abc)
    WHERE bar_count = 2
),

query_ngrams_all AS (
    SELECT
        gs.pos AS query_ngram_position,
        array_to_string(q.interval_parts[gs.pos:(gs.pos + 3)], ',') AS interval_ngram,
        array_to_string(q.coarse_interval_parts[gs.pos:(gs.pos + 3)], ',') AS coarse_interval_ngram,
        array_to_string(q.rhythm_parts[gs.pos:(gs.pos + 4)], ',') AS rhythm_ngram,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 1) AS total_ngram_positions
    FROM q
    CROSS JOIN LATERAL generate_series(
        1,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 0)
    ) AS gs(pos)
),

query_ngrams_ranked AS (
    SELECT
        qn.query_ngram_position,
        qn.interval_ngram,
        qn.coarse_interval_ngram,
        qn.rhythm_ngram,
        qn.total_ngram_positions,
        CASE
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions / 3.0) THEN 'early'
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions * 2.0 / 3.0) THEN 'middle'
            ELSE 'late'
        END AS phrase_zone,
        COALESCE(s.tune_count, 999999999) AS tune_count,
        COALESCE(s.fragment_count, 999999999) AS fragment_count,
        CASE
            WHEN s.fragment_count IS NULL THEN 0.10::numeric
            ELSE round((1.0 / ln(2 + s.fragment_count::numeric)), 6)
        END AS rarity_weight
    FROM query_ngrams_all qn
    LEFT JOIN thesession.mv_melody_2bar_ngram_stats_v4 s
      ON s.interval_ngram = qn.interval_ngram
    WHERE qn.interval_ngram IS NOT NULL
      AND btrim(qn.interval_ngram) <> ''
      AND COALESCE(s.tune_count, 999999999) <= 2500
      AND COALESCE(s.fragment_count, 999999999) <= 8250
),

query_ngrams_spread AS (
    SELECT *
    FROM (
        SELECT
            qnr.*,
            row_number() OVER (
                PARTITION BY qnr.phrase_zone
                ORDER BY
                    qnr.tune_count,
                    qnr.fragment_count,
                    qnr.query_ngram_position
            ) AS zone_rank
        FROM query_ngrams_ranked qnr
    ) x
    WHERE x.zone_rank <= 3
),

query_ngrams_limited AS (
    SELECT
        query_ngram_position,
        interval_ngram,
        coarse_interval_ngram,
        rhythm_ngram,
        rarity_weight
    FROM query_ngrams_spread
    ORDER BY query_ngram_position
    LIMIT 9
),

query_ngrams AS (
    SELECT
        qn.query_ngram_position,
        qn.interval_ngram,
        qn.coarse_interval_ngram,
        qn.rhythm_ngram,
        qn.rarity_weight,
        q.contour_fingerprint AS query_contour_fingerprint,
        q.coarse_fingerprint AS query_coarse_fingerprint,
        count(*) OVER ()::integer AS query_ngram_count
    FROM query_ngrams_limited qn
    CROSS JOIN q
),

matches AS (
    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        true AS exact_ngram_match,
        false AS coarse_ngram_match
    FROM query_ngrams qn
    JOIN thesession.mv_melody_2bar_fragment_ngrams_v4 f
      ON f.interval_ngram = qn.interval_ngram
    WHERE (p_type IS NULL OR f.type = p_type)
      AND (p_meter IS NULL OR f.meter = p_meter)

    UNION ALL

    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        false AS exact_ngram_match,
        true AS coarse_ngram_match
    FROM query_ngrams qn
    JOIN thesession.mv_melody_2bar_fragment_ngrams_v4 f
      ON f.coarse_interval_ngram = qn.coarse_interval_ngram
    WHERE (p_type IS NULL OR f.type = p_type)
	  AND (p_meter IS NULL OR f.meter = p_meter)
	  AND qn.rarity_weight >= 0.09
	  AND f.interval_ngram <> qn.interval_ngram
	  AND abs(f.ngram_position - qn.query_ngram_position) = 0
),

fragment_query_hits AS (
    SELECT
        m.fragment_id,
        m.query_ngram_position,
        max(m.rarity_weight) AS rarity_weight,
        bool_or(m.rhythm_ngram_match) AS rhythm_ngram_match,
        bool_or(m.exact_ngram_match) AS exact_ngram_match,
        bool_or(m.coarse_ngram_match) AS coarse_ngram_match,
        max(
            CASE
                WHEN m.exact_ngram_match THEN 1.0
                WHEN m.coarse_ngram_match THEN 0.45
                ELSE 0.0
            END
        ) AS weighted_hit
    FROM matches m
    GROUP BY m.fragment_id, m.query_ngram_position
),

fragment_position_runs AS (
    SELECT
        fragment_id,
        max(run_length)::integer AS max_consecutive_ngrams
    FROM (
        SELECT
            fragment_id,
            count(*) AS run_length
        FROM (
            SELECT
                fragment_id,
                query_ngram_position,
                query_ngram_position
                  - row_number() OVER (
                        PARTITION BY fragment_id
                        ORDER BY query_ngram_position
                    ) AS run_group
            FROM fragment_query_hits
        ) x
        GROUP BY fragment_id, run_group
    ) y
    GROUP BY fragment_id
),

fragment_scores AS (
    SELECT
        m.fragment_id,
        min(m.setting_id) AS setting_id,
        min(m.tune_id) AS tune_id,
        min(m.name) AS name,
        min(m.type) AS type,
        min(m.meter) AS meter,
        min(m.mode) AS mode,
        min(m.bar_start) AS bar_start,
        min(m.bar_1_text || ' | ' || m.bar_2_text) AS sample_match,
        count(DISTINCT h.query_ngram_position) AS shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.exact_ngram_match) AS exact_shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.coarse_ngram_match AND NOT h.exact_ngram_match) AS coarse_only_shared_ngrams,
        sum(h.weighted_hit) AS weighted_shared_ngrams,
        max(m.query_ngram_count) AS query_ngram_count,
        bool_or(h.rhythm_ngram_match) AS has_rhythm_ngram_match,
        sum(h.rarity_weight * h.weighted_hit) AS rarity_score,
        min(m.query_contour_fingerprint) AS query_contour_fingerprint,
        min(m.fragment_contour_fingerprint) AS fragment_contour_fingerprint,
        min(m.query_coarse_fingerprint) AS query_coarse_fingerprint,
        min(m.fragment_coarse_fingerprint) AS fragment_coarse_fingerprint,
        max(COALESCE(r.max_consecutive_ngrams, 1)) AS max_consecutive_ngrams
    FROM matches m
    JOIN fragment_query_hits h
      ON h.fragment_id = m.fragment_id
     AND h.query_ngram_position = m.query_ngram_position
    LEFT JOIN fragment_position_runs r
      ON r.fragment_id = m.fragment_id
    GROUP BY m.fragment_id
    HAVING (
	    count(DISTINCT h.query_ngram_position) FILTER (
	        WHERE h.exact_ngram_match
	    	) >= 2
		)
		OR (
		    count(DISTINCT h.query_ngram_position) >= 4
		)
       AND (
           p_rhythm_mode <> 'hard'
           OR count(DISTINCT h.query_ngram_position)
              FILTER (WHERE h.rhythm_ngram_match) >= 3
       )
),

ranked_fragments AS (
    SELECT
        fs.*,
        round(
            (
                fs.weighted_shared_ngrams::numeric
                / NULLIF(fs.query_ngram_count, 0)::numeric
            ) * 100,
            2
        ) AS coverage_pct,
        CASE
            WHEN fs.fragment_contour_fingerprint = fs.query_contour_fingerprint THEN 20
            WHEN left(fs.fragment_contour_fingerprint, 15) = left(fs.query_contour_fingerprint, 15) THEN 10
            ELSE 0
        END AS contour_bonus,
        CASE
            WHEN fs.fragment_coarse_fingerprint = fs.query_coarse_fingerprint THEN 40
            WHEN left(fs.fragment_coarse_fingerprint, 15) = left(fs.query_coarse_fingerprint, 15) THEN 20
            ELSE 0
        END AS coarse_bonus,
        CASE
            WHEN fs.max_consecutive_ngrams >= 6 THEN 140
            WHEN fs.max_consecutive_ngrams = 5 THEN 100
            WHEN fs.max_consecutive_ngrams = 4 THEN 65
            WHEN fs.max_consecutive_ngrams = 3 THEN 30
            ELSE 0
        END AS continuity_bonus,
        row_number() OVER (
            PARTITION BY fs.tune_id
            ORDER BY
                fs.weighted_shared_ngrams DESC,
                fs.exact_shared_ngrams DESC,
                fs.max_consecutive_ngrams DESC,
                fs.rarity_score DESC,
                fs.has_rhythm_ngram_match DESC,
                fs.setting_id
        ) AS rn
    FROM fragment_scores fs
),

candidate_fragments AS (
    SELECT *
    FROM (
        SELECT
            rf.*,
            row_number() OVER (
                ORDER BY
                    rf.weighted_shared_ngrams DESC,
                    rf.exact_shared_ngrams DESC,
                    rf.max_consecutive_ngrams DESC,
                    rf.rarity_score DESC,
                    rf.coverage_pct DESC
            ) AS candidate_rank
        FROM ranked_fragments rf
    ) x
    WHERE x.candidate_rank <= 250
),

reranked_fragments AS (
    SELECT
        cf.*,
        ed.edit_distance,
        ed.similarity_pct AS edit_similarity_pct,
        ROUND(ed.similarity_pct * 2.5)::integer AS edit_distance_bonus
    FROM candidate_fragments cf
    CROSS JOIN q
    CROSS JOIN LATERAL thesession.compare_melody_edit_distance_from_intervals(
        q.interval_fingerprint,
        '| ' || cf.sample_match || ' |'
    ) ed
),

rollup AS (
    SELECT
        rf.tune_id,
        min(rf.name) AS tune_name,
        min(rf.type) AS type,
        min(rf.meter) AS meter,
        min(rf.mode) AS mode,
        count(DISTINCT rf.setting_id) AS matching_settings,
        count(*) AS matching_fragments,
        max(rf.shared_ngrams) AS shared_ngrams,
        max(rf.exact_shared_ngrams) AS exact_shared_ngrams,
        max(rf.coarse_only_shared_ngrams) AS coarse_only_shared_ngrams,
        max(rf.weighted_shared_ngrams) AS weighted_shared_ngrams,
        max(rf.query_ngram_count) AS query_ngrams,
        max(rf.coverage_pct) AS coverage_pct,
        bool_or(rf.has_rhythm_ngram_match) AS has_rhythm_ngram_match,
        max(rf.rarity_score) AS rarity_score,
        max(rf.contour_bonus) AS contour_bonus,
        max(rf.coarse_bonus) AS coarse_bonus,
        max(rf.continuity_bonus) AS continuity_bonus,
        max(rf.edit_similarity_pct) AS edit_similarity_pct,
        max(rf.edit_distance_bonus) AS edit_distance_bonus,
        max(rf.max_consecutive_ngrams) AS max_consecutive_ngrams,
        min(rf.bar_start) FILTER (WHERE rf.rn = 1) AS best_bar_start,
        min(rf.sample_match) FILTER (WHERE rf.rn = 1) AS best_sample_match
    FROM reranked_fragments rf
    GROUP BY rf.tune_id
),

final_results AS (
    SELECT
        r.tune_id,
        COALESCE(tm.primary_name, r.tune_name) AS tune_name,
        COALESCE(tm.type, r.type) AS type,
        COALESCE(tm.meter, r.meter) AS meter,
        COALESCE(tm.mode, r.mode) AS mode,
        tm.tunebooks,
        tm.star_rating,
        COALESCE(tm.has_recording_albums, false) AS has_recording_albums,
        r.matching_settings,
        r.matching_fragments,
        r.shared_ngrams,
        r.query_ngrams,
        r.coverage_pct,
        r.has_rhythm_ngram_match,
        r.best_bar_start,
        r.best_sample_match,
        round(
            (
                r.coverage_pct::numeric * 2.0
                + r.weighted_shared_ngrams::numeric * 45.0
                + r.exact_shared_ngrams::numeric * 25.0
                + r.coarse_only_shared_ngrams::numeric * 8.0
                + r.rarity_score::numeric * 80.0
                + COALESCE(r.contour_bonus, 0)
                + COALESCE(r.coarse_bonus, 0)
                + COALESCE(r.continuity_bonus, 0)
                + COALESCE(r.edit_distance_bonus, 0)
                + CASE WHEN r.has_rhythm_ngram_match THEN 10 ELSE 0 END
                + LEAST(r.matching_settings::numeric, 5) * 4
                + LEAST(r.matching_fragments::numeric, 10)
                + LEAST(COALESCE(tm.star_rating, 0)::numeric * 2, 10)
                + CASE
                    WHEN COALESCE(tm.tunebooks, 0) >= 200 THEN 5
                    WHEN COALESCE(tm.tunebooks, 0) >= 100 THEN 3
                    WHEN COALESCE(tm.tunebooks, 0) >= 50 THEN 2
                    ELSE 0
                  END
            )
        )::integer AS score
    FROM rollup r
    LEFT JOIN thesession.mv_tune_meta tm
      ON tm.tune_id = r.tune_id
    WHERE r.coverage_pct >= 25
)

SELECT
    fr.tune_id,
    fr.tune_name,
    fr.type,
    fr.meter,
    fr.mode,
    fr.tunebooks,
    fr.star_rating,
    fr.has_recording_albums,
    fr.matching_settings,
    fr.matching_fragments,
    fr.shared_ngrams,
    fr.query_ngrams,
    fr.coverage_pct,
    fr.has_rhythm_ngram_match,
    fr.best_bar_start,
    fr.best_sample_match,
    fr.score
FROM final_results fr
ORDER BY
    fr.score DESC,
    fr.coverage_pct DESC,
    fr.shared_ngrams DESC,
    fr.matching_settings DESC,
    fr.matching_fragments DESC,
    fr.tune_name
LIMIT p_limit;
$$;


ALTER FUNCTION thesession.zz_old_search_melody_2bar_fuzzy(p_abc text, p_rhythm_mode text, p_type text, p_meter text, p_limit integer) OWNER TO folkguitar;

--
-- TOC entry 1188 (class 1255 OID 870578)
-- Name: zz_old_search_melody_2bar_fuzzy_stage2(text, text, text, text, integer); Type: FUNCTION; Schema: thesession; Owner: folkguitar
--

CREATE FUNCTION thesession.zz_old_search_melody_2bar_fuzzy_stage2(p_abc text, p_rhythm_mode text DEFAULT 'soft'::text, p_type text DEFAULT NULL::text, p_meter text DEFAULT NULL::text, p_limit integer DEFAULT 100) RETURNS TABLE(tune_id bigint, tune_name text, type text, meter text, mode text, tunebooks integer, star_rating integer, has_recording_albums boolean, matching_settings bigint, matching_fragments bigint, shared_ngrams bigint, query_ngrams integer, coverage_pct numeric, has_rhythm_ngram_match boolean, best_bar_start integer, best_sample_match text, score numeric)
    LANGUAGE sql STABLE
    AS $$
WITH q AS (
    SELECT
        *,
        thesession.melody_contour_fingerprint(interval_fingerprint) AS contour_fingerprint,
        thesession.melody_coarse_interval_fingerprint(interval_fingerprint) AS coarse_fingerprint,
        string_to_array(interval_fingerprint, ',') AS interval_parts,
        string_to_array(thesession.melody_coarse_interval_fingerprint(interval_fingerprint), ',') AS coarse_interval_parts,
        string_to_array(rhythm_fingerprint, ',') AS rhythm_parts
    FROM thesession.melody_2bar_fuzzy_fingerprint_from_abc(p_abc)
    WHERE bar_count = 2
),

query_ngrams_all AS (
    SELECT
        gs.pos AS query_ngram_position,
        array_to_string(q.interval_parts[gs.pos:(gs.pos + 3)], ',') AS interval_ngram,
        array_to_string(q.coarse_interval_parts[gs.pos:(gs.pos + 3)], ',') AS coarse_interval_ngram,
        array_to_string(q.rhythm_parts[gs.pos:(gs.pos + 4)], ',') AS rhythm_ngram,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 1) AS total_ngram_positions
    FROM q
    CROSS JOIN LATERAL generate_series(
        1,
        greatest(array_length(q.interval_parts, 1) - 4 + 1, 0)
    ) gs(pos)
),

query_ngrams_ranked AS (
    SELECT
        qn.*,
        CASE
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions / 3.0) THEN 'early'
            WHEN qn.query_ngram_position <= CEIL(qn.total_ngram_positions * 2.0 / 3.0) THEN 'middle'
            ELSE 'late'
        END AS phrase_zone,
        COALESCE(s.tune_count, 999999999) AS tune_count,
        COALESCE(s.fragment_count, 999999999) AS fragment_count,
        CASE
            WHEN s.fragment_count IS NULL THEN 0.10::numeric
            ELSE round((1.0 / ln(2 + s.fragment_count::numeric)), 6)
        END AS rarity_weight
    FROM query_ngrams_all qn
    LEFT JOIN thesession.mv_melody_2bar_ngram_stats_v4 s
      ON s.interval_ngram = qn.interval_ngram
    WHERE qn.interval_ngram IS NOT NULL
      AND btrim(qn.interval_ngram) <> ''
      AND COALESCE(s.tune_count, 999999999) <= 2500
      AND COALESCE(s.fragment_count, 999999999) <= 8250
),

query_ngrams AS (
    SELECT
        qnr.query_ngram_position,
        qnr.interval_ngram,
        qnr.coarse_interval_ngram,
        qnr.rhythm_ngram,
        qnr.rarity_weight,
        q.contour_fingerprint AS query_contour_fingerprint,
        q.coarse_fingerprint AS query_coarse_fingerprint,
        q.interval_fingerprint AS query_interval_fingerprint,
        count(*) OVER ()::integer AS query_ngram_count
    FROM (
        SELECT *
        FROM (
            SELECT
                qnr.*,
                row_number() OVER (
                    PARTITION BY qnr.phrase_zone
                    ORDER BY qnr.tune_count, qnr.fragment_count, qnr.query_ngram_position
                ) AS zone_rank
            FROM query_ngrams_ranked qnr
        ) x
        WHERE x.zone_rank <= 3
        ORDER BY query_ngram_position
        LIMIT 9
    ) qnr
    CROSS JOIN q
),

matches AS (
    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.query_interval_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        true AS exact_ngram_match,
        false AS coarse_ngram_match
    FROM query_ngrams qn
    JOIN thesession.mv_melody_2bar_fragment_ngrams_v4 f
      ON f.interval_ngram = qn.interval_ngram
    WHERE (p_type IS NULL OR f.type = p_type)
      AND (p_meter IS NULL OR f.meter = p_meter)

    UNION ALL

    SELECT
        f.*,
        qn.query_ngram_position,
        qn.query_ngram_count,
        qn.rarity_weight,
        qn.query_contour_fingerprint,
        qn.query_coarse_fingerprint,
        qn.query_interval_fingerprint,
        qn.rhythm_ngram AS query_rhythm_ngram,
        (f.rhythm_ngram = qn.rhythm_ngram) AS rhythm_ngram_match,
        false AS exact_ngram_match,
        true AS coarse_ngram_match
	FROM (
	    SELECT *
	    FROM query_ngrams
	    WHERE rarity_weight >= 0.09
	    ORDER BY rarity_weight DESC
	    LIMIT 4
	) qn
	JOIN thesession.mv_melody_2bar_fragment_ngrams_v4 f
	  ON f.coarse_interval_ngram = qn.coarse_interval_ngram
	WHERE (p_type IS NULL OR f.type = p_type)
	  AND (p_meter IS NULL OR f.meter = p_meter)
	  AND f.interval_ngram <> qn.interval_ngram
	  AND abs(f.ngram_position - qn.query_ngram_position) <= 1
	),

fragment_query_hits AS (
    SELECT
        m.fragment_id,
        m.query_ngram_position,
        max(m.rarity_weight) AS rarity_weight,
        bool_or(m.rhythm_ngram_match) AS rhythm_ngram_match,
        bool_or(m.exact_ngram_match) AS exact_ngram_match,
        bool_or(m.coarse_ngram_match) AS coarse_ngram_match,
        max(
            CASE
                WHEN m.exact_ngram_match THEN 1.0
                WHEN m.coarse_ngram_match THEN 0.45
                ELSE 0.0
            END
        ) AS weighted_hit
    FROM matches m
    GROUP BY m.fragment_id, m.query_ngram_position
),

stage1_fragments AS (
    SELECT
        m.fragment_id,
        min(m.setting_id) AS setting_id,
        min(m.tune_id) AS tune_id,
        min(m.name) AS name,
        min(m.type) AS type,
        min(m.meter) AS meter,
        min(m.mode) AS mode,
        min(m.bar_start) AS bar_start,
        min(m.bar_1_text || ' | ' || m.bar_2_text) AS sample_match,
        count(DISTINCT h.query_ngram_position) AS shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.exact_ngram_match) AS exact_shared_ngrams,
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.coarse_ngram_match AND NOT h.exact_ngram_match) AS coarse_only_shared_ngrams,
        sum(h.weighted_hit) AS weighted_shared_ngrams,
        max(m.query_ngram_count) AS query_ngram_count,
        bool_or(h.rhythm_ngram_match) AS has_rhythm_ngram_match,
        sum(h.rarity_weight * h.weighted_hit) AS rarity_score,
        min(m.query_contour_fingerprint) AS query_contour_fingerprint,
        min(m.fragment_contour_fingerprint) AS fragment_contour_fingerprint,
        min(m.query_coarse_fingerprint) AS query_coarse_fingerprint,
        min(m.fragment_coarse_fingerprint) AS fragment_coarse_fingerprint,
        min(m.query_interval_fingerprint) AS query_interval_fingerprint
    FROM matches m
    JOIN fragment_query_hits h
      ON h.fragment_id = m.fragment_id
     AND h.query_ngram_position = m.query_ngram_position
    GROUP BY m.fragment_id
    HAVING (
        count(DISTINCT h.query_ngram_position) FILTER (WHERE h.exact_ngram_match) >= 2
        OR count(DISTINCT h.query_ngram_position) >= 4
    )
    AND (
        p_rhythm_mode <> 'hard'
        OR count(DISTINCT h.query_ngram_position) FILTER (WHERE h.rhythm_ngram_match) >= 2
    )
),

stage1_candidates AS (
    SELECT *
    FROM (
        SELECT
            s1.*,
            row_number() OVER (
                ORDER BY
                    s1.weighted_shared_ngrams DESC,
                    s1.exact_shared_ngrams DESC,
                    s1.rarity_score DESC,
                    s1.has_rhythm_ngram_match DESC,
                    s1.setting_id
            ) AS stage1_rank
        FROM stage1_fragments s1
    ) x
    WHERE x.stage1_rank <= 1100
),

fragment_position_runs AS (
    SELECT
        y.fragment_id,
        max(y.run_length)::integer AS max_consecutive_ngrams
    FROM (
        SELECT
            x.fragment_id,
            count(*) AS run_length
        FROM (
            SELECT
                h.fragment_id,
                h.query_ngram_position,
                h.query_ngram_position
                  - row_number() OVER (
                        PARTITION BY h.fragment_id
                        ORDER BY h.query_ngram_position
                    ) AS run_group
            FROM fragment_query_hits h
            JOIN stage1_candidates c
              ON c.fragment_id = h.fragment_id
        ) x
        GROUP BY x.fragment_id, x.run_group
    ) y
    GROUP BY y.fragment_id
),

ranked_fragments AS (
    SELECT
        c.*,
        COALESCE(r.max_consecutive_ngrams, 1) AS max_consecutive_ngrams,
		LEAST(
		    round(
		        (
		            c.weighted_shared_ngrams::numeric
		            / NULLIF(c.query_ngram_count, 0)::numeric
		        ) * 100,
		        2
		    ),
		    100
		) AS coverage_pct,
        CASE
            WHEN c.fragment_contour_fingerprint = c.query_contour_fingerprint THEN 20
            WHEN left(c.fragment_contour_fingerprint, 15) = left(c.query_contour_fingerprint, 15) THEN 10
            ELSE 0
        END AS contour_bonus,
        CASE
            WHEN c.fragment_coarse_fingerprint = c.query_coarse_fingerprint THEN 40
            WHEN left(c.fragment_coarse_fingerprint, 15) = left(c.query_coarse_fingerprint, 15) THEN 20
            ELSE 0
        END AS coarse_bonus,
        CASE
            WHEN COALESCE(r.max_consecutive_ngrams, 1) >= 6 THEN 140
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 5 THEN 100
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 4 THEN 65
            WHEN COALESCE(r.max_consecutive_ngrams, 1) = 3 THEN 30
            ELSE 0
        END AS continuity_bonus,
        row_number() OVER (
            PARTITION BY c.tune_id
            ORDER BY
                c.weighted_shared_ngrams DESC,
                c.exact_shared_ngrams DESC,
                COALESCE(r.max_consecutive_ngrams, 1) DESC,
                c.rarity_score DESC,
                c.has_rhythm_ngram_match DESC,
                c.setting_id
        ) AS rn
    FROM stage1_candidates c
    LEFT JOIN fragment_position_runs r
      ON r.fragment_id = c.fragment_id
),

candidate_fragments AS (
    SELECT *
    FROM (
        SELECT
            rf.*,
            row_number() OVER (
                ORDER BY
                    rf.weighted_shared_ngrams DESC,
                    rf.exact_shared_ngrams DESC,
                    rf.max_consecutive_ngrams DESC,
                    rf.rarity_score DESC,
                    rf.coverage_pct DESC
            ) AS candidate_rank
        FROM ranked_fragments rf
    ) x
    WHERE x.candidate_rank <= 350
),

reranked_fragments AS (
    SELECT
        cf.*,
        ed.edit_distance,
        ed.similarity_pct AS edit_similarity_pct,
        ROUND(ed.similarity_pct * 2.5)::integer AS edit_distance_bonus
    FROM candidate_fragments cf
    CROSS JOIN LATERAL thesession.compare_melody_edit_distance_from_intervals(
        cf.query_interval_fingerprint,
        '| ' || cf.sample_match || ' |'
    ) ed
),

rollup AS (
    SELECT
        rf.tune_id,
        min(rf.name) AS tune_name,
        min(rf.type) AS type,
        min(rf.meter) AS meter,
        min(rf.mode) AS mode,
        count(DISTINCT rf.setting_id) AS matching_settings,
        count(*) AS matching_fragments,
        max(rf.shared_ngrams) AS shared_ngrams,
        max(rf.exact_shared_ngrams) AS exact_shared_ngrams,
        max(rf.coarse_only_shared_ngrams) AS coarse_only_shared_ngrams,
        max(rf.weighted_shared_ngrams) AS weighted_shared_ngrams,
        max(rf.query_ngram_count) AS query_ngrams,
        max(rf.coverage_pct) AS coverage_pct,
        bool_or(rf.has_rhythm_ngram_match) AS has_rhythm_ngram_match,
        max(rf.rarity_score) AS rarity_score,
        max(rf.contour_bonus) AS contour_bonus,
        max(rf.coarse_bonus) AS coarse_bonus,
        max(rf.continuity_bonus) AS continuity_bonus,
        max(rf.edit_distance_bonus) AS edit_distance_bonus,
        min(rf.bar_start) FILTER (WHERE rf.rn = 1) AS best_bar_start,
        min(rf.sample_match) FILTER (WHERE rf.rn = 1) AS best_sample_match
    FROM reranked_fragments rf
    GROUP BY rf.tune_id
),

final_results AS (
    SELECT
        r.tune_id,
        COALESCE(tm.primary_name, r.tune_name) AS tune_name,
        COALESCE(tm.type, r.type) AS type,
        COALESCE(tm.meter, r.meter) AS meter,
        COALESCE(tm.mode, r.mode) AS mode,
        tm.tunebooks,
        tm.star_rating,
        COALESCE(tm.has_recording_albums, false) AS has_recording_albums,
        r.matching_settings,
        r.matching_fragments,
        r.shared_ngrams,
        r.query_ngrams,
        r.coverage_pct,
        r.has_rhythm_ngram_match,
        r.best_bar_start,
        r.best_sample_match,
        round(
            (
                r.coverage_pct::numeric * 2.0
                + r.weighted_shared_ngrams::numeric * 45.0
                + r.exact_shared_ngrams::numeric * 25.0
                + r.coarse_only_shared_ngrams::numeric * 8.0
                + r.rarity_score::numeric * 80.0
                + COALESCE(r.contour_bonus, 0)
                + COALESCE(r.coarse_bonus, 0)
                + COALESCE(r.continuity_bonus, 0)
                + COALESCE(r.edit_distance_bonus, 0)
				+ CASE
				    WHEN r.best_bar_start = 1 THEN 500
				    WHEN r.best_bar_start <= 4 THEN 250
				    WHEN r.best_bar_start <= 8 THEN 100
				    ELSE 0
				  END
				+ CASE WHEN r.has_rhythm_ngram_match THEN 10 ELSE 0 END
                + LEAST(r.matching_settings::numeric, 5) * 4
                + LEAST(r.matching_fragments::numeric, 10)
                + LEAST(COALESCE(tm.star_rating, 0)::numeric * 2, 10)
                + CASE
                    WHEN COALESCE(tm.tunebooks, 0) >= 200 THEN 5
                    WHEN COALESCE(tm.tunebooks, 0) >= 100 THEN 3
                    WHEN COALESCE(tm.tunebooks, 0) >= 50 THEN 2
                    ELSE 0
                  END
            )
        )::integer AS score
    FROM rollup r
    LEFT JOIN thesession.mv_tune_meta tm
      ON tm.tune_id = r.tune_id
    WHERE r.coverage_pct >= 20
)

SELECT
    fr.tune_id,
    fr.tune_name,
    fr.type,
    fr.meter,
    fr.mode,
    fr.tunebooks,
    fr.star_rating,
    fr.has_recording_albums,
    fr.matching_settings,
    fr.matching_fragments,
    fr.shared_ngrams,
    fr.query_ngrams,
    fr.coverage_pct,
    fr.has_rhythm_ngram_match,
    fr.best_bar_start,
    fr.best_sample_match,
    fr.score
FROM final_results fr
ORDER BY
    fr.score DESC,
    fr.coverage_pct DESC,
    fr.shared_ngrams DESC,
    fr.matching_settings DESC,
    fr.matching_fragments DESC,
    fr.tune_name
LIMIT p_limit;
$$;


ALTER FUNCTION thesession.zz_old_search_melody_2bar_fuzzy_stage2(p_abc text, p_rhythm_mode text, p_type text, p_meter text, p_limit integer) OWNER TO folkguitar;

--
-- TOC entry 357 (class 1259 OID 1158822)
-- Name: api_keys_id_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.api_keys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.api_keys_id_seq OWNER TO folkguitar;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 358 (class 1259 OID 1158823)
-- Name: api_keys; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.api_keys (
    id bigint DEFAULT nextval('thesession.api_keys_id_seq'::regclass) NOT NULL,
    key_hash character varying(64) NOT NULL,
    key_prefix character varying(16) NOT NULL,
    user_name text NOT NULL,
    user_email text NOT NULL,
    user_type character varying(50) NOT NULL,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    CONSTRAINT chk_api_keys_status CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('suspended'::character varying)::text, ('revoked'::character varying)::text]))),
    CONSTRAINT chk_api_keys_user_type CHECK (((user_type)::text = ANY (ARRAY[('public-api'::character varying)::text, ('commercial'::character varying)::text, ('internal'::character varying)::text])))
);


ALTER TABLE thesession.api_keys OWNER TO folkguitar;

--
-- TOC entry 300 (class 1259 OID 442114)
-- Name: feature_request; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.feature_request (
    id bigint NOT NULL,
    name text,
    email text NOT NULL,
    category text,
    priority text,
    title text,
    message text NOT NULL,
    page text,
    user_agent text,
    ip_address text,
    submitted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE thesession.feature_request OWNER TO folkguitar;

--
-- TOC entry 299 (class 1259 OID 442113)
-- Name: feature_request_id_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.feature_request_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.feature_request_id_seq OWNER TO folkguitar;

--
-- TOC entry 5211 (class 0 OID 0)
-- Dependencies: 299
-- Name: feature_request_id_seq; Type: SEQUENCE OWNED BY; Schema: thesession; Owner: folkguitar
--

ALTER SEQUENCE thesession.feature_request_id_seq OWNED BY thesession.feature_request.id;


--
-- TOC entry 350 (class 1259 OID 944234)
-- Name: member_country; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.member_country (
    member_id bigint NOT NULL,
    country_code text,
    country_name text,
    source text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE thesession.member_country OWNER TO folkguitar;

--
-- TOC entry 294 (class 1259 OID 401353)
-- Name: session_recording; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_recording (
    id bigint NOT NULL,
    artist_id bigint,
    recording text,
    track integer NOT NULL,
    tune_number integer NOT NULL,
    tune_id bigint,
    tune_name text,
    created_at timestamp with time zone DEFAULT now(),
    artist_name text
);


ALTER TABLE thesession.session_recording OWNER TO folkguitar;

--
-- TOC entry 326 (class 1259 OID 784599)
-- Name: mv_artist_name_search; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_artist_name_search AS
 SELECT artist_name,
    lower(artist_name) AS artist_name_lc,
    count(*) AS recording_rows,
    count(DISTINCT recording) AS recordings,
    count(DISTINCT tune_id) AS distinct_tunes
   FROM thesession.session_recording
  WHERE ((artist_name IS NOT NULL) AND (TRIM(BOTH FROM artist_name) <> ''::text) AND (artist_name <> 'Various Artists'::text))
  GROUP BY artist_name
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_artist_name_search OWNER TO folkguitar;

--
-- TOC entry 5212 (class 0 OID 0)
-- Dependencies: 326
-- Name: COLUMN mv_artist_name_search.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_name_search.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5213 (class 0 OID 0)
-- Dependencies: 326
-- Name: COLUMN mv_artist_name_search.artist_name_lc; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_name_search.artist_name_lc IS 'Lowercase name of the artist/performer (for index-friendly search)';


--
-- TOC entry 5214 (class 0 OID 0)
-- Dependencies: 326
-- Name: COLUMN mv_artist_name_search.recording_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_name_search.recording_rows IS 'Total tracks/recordings associated with this artist in the database';


--
-- TOC entry 5215 (class 0 OID 0)
-- Dependencies: 326
-- Name: COLUMN mv_artist_name_search.recordings; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_name_search.recordings IS 'Count of unique recordings/tracks by this artist';


--
-- TOC entry 5216 (class 0 OID 0)
-- Dependencies: 326
-- Name: COLUMN mv_artist_name_search.distinct_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_name_search.distinct_tunes IS 'Count of distinct traditional tunes recorded by this artist';


--
-- TOC entry 325 (class 1259 OID 784366)
-- Name: mv_artist_transition_features; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_artist_transition_features AS
 WITH ordered AS (
         SELECT session_recording.artist_name,
            session_recording.recording,
            session_recording.track,
            session_recording.tune_number,
            session_recording.tune_id AS source_tune_id,
            session_recording.tune_name AS source_tune_name,
            lead(session_recording.tune_id) OVER (PARTITION BY session_recording.artist_name, session_recording.recording, session_recording.track ORDER BY session_recording.tune_number) AS target_tune_id,
            lead(session_recording.tune_name) OVER (PARTITION BY session_recording.artist_name, session_recording.recording, session_recording.track ORDER BY session_recording.tune_number) AS target_tune_name
           FROM thesession.session_recording
          WHERE ((session_recording.artist_name IS NOT NULL) AND (TRIM(BOTH FROM session_recording.artist_name) <> ''::text) AND (session_recording.artist_name <> 'Various Artists'::text))
        ), transitions AS (
         SELECT ordered.artist_name,
            ordered.recording,
            ordered.track,
            ordered.source_tune_id,
            ordered.source_tune_name,
            ordered.target_tune_id,
            ordered.target_tune_name
           FROM ordered
          WHERE ((ordered.target_tune_id IS NOT NULL) AND (ordered.source_tune_id <> ordered.target_tune_id))
        ), artist_totals AS (
         SELECT transitions.artist_name,
            count(*) AS artist_total_transitions
           FROM transitions
          GROUP BY transitions.artist_name
        ), global_totals AS (
         SELECT transitions.source_tune_id,
            transitions.target_tune_id,
            count(*) AS global_transition_count
           FROM transitions
          GROUP BY transitions.source_tune_id, transitions.target_tune_id
        ), global_transition_sum AS (
         SELECT count(*) AS total_global_transitions
           FROM transitions
        )
 SELECT t.artist_name,
    t.source_tune_id,
    t.source_tune_name,
    t.target_tune_id,
    t.target_tune_name,
    count(*) AS transition_count,
    count(DISTINCT t.recording) AS distinct_recordings,
    count(DISTINCT ((t.recording || '|'::text) || t.track)) AS distinct_tracks,
    at.artist_total_transitions,
    gt.global_transition_count,
    round(((count(*))::numeric / (NULLIF(at.artist_total_transitions, 0))::numeric), 6) AS artist_transition_pct,
    round(((gt.global_transition_count)::numeric / (NULLIF(gts.total_global_transitions, 0))::numeric), 6) AS global_transition_pct,
    round(ln(((1)::numeric + (((count(*))::numeric / (NULLIF(at.artist_total_transitions, 0))::numeric) / NULLIF(((gt.global_transition_count)::numeric / (NULLIF(gts.total_global_transitions, 0))::numeric), (0)::numeric)))), 4) AS lift_score,
    round(((ln(((1 + count(*)))::double precision) * (ln(((1)::numeric + (((count(*))::numeric / (NULLIF(at.artist_total_transitions, 0))::numeric) / NULLIF(((gt.global_transition_count)::numeric / (NULLIF(gts.total_global_transitions, 0))::numeric), (0)::numeric)))))::double precision))::numeric, 4) AS weighted_score,
    round(((1)::numeric / sqrt((gt.global_transition_count)::numeric)), 6) AS rarity_weight
   FROM (((transitions t
     JOIN artist_totals at ON ((at.artist_name = t.artist_name)))
     JOIN global_totals gt ON (((gt.source_tune_id = t.source_tune_id) AND (gt.target_tune_id = t.target_tune_id))))
     CROSS JOIN global_transition_sum gts)
  GROUP BY t.artist_name, t.source_tune_id, t.source_tune_name, t.target_tune_id, t.target_tune_name, at.artist_total_transitions, gt.global_transition_count, gts.total_global_transitions
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_artist_transition_features OWNER TO folkguitar;

--
-- TOC entry 5217 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5218 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.source_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.source_tune_id IS 'ID of the source_tune';


--
-- TOC entry 5219 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.source_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.source_tune_name IS 'Name of the source_tune';


--
-- TOC entry 5220 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.target_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.target_tune_id IS 'ID of the target_tune';


--
-- TOC entry 5221 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.target_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.target_tune_name IS 'Name of the target_tune';


--
-- TOC entry 5222 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.transition_count IS 'Count of transitions';


--
-- TOC entry 5223 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.distinct_recordings; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.distinct_recordings IS 'Number of unique recordings by the artist containing this tune transition';


--
-- TOC entry 5224 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.distinct_tracks; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.distinct_tracks IS 'Number of unique tracks by the artist containing this tune transition';


--
-- TOC entry 5225 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.artist_total_transitions; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.artist_total_transitions IS 'Total set transitions recorded by this artist in the database';


--
-- TOC entry 5226 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.global_transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.global_transition_count IS 'Global number of times this tune transition occurs across all artists';


--
-- TOC entry 5227 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.artist_transition_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.artist_transition_pct IS 'Percentage of this artist''s transitions that are this specific tune transition';


--
-- TOC entry 5228 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.global_transition_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.global_transition_pct IS 'Global percentage of this tune transition across all artists';


--
-- TOC entry 5229 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.lift_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.lift_score IS 'Association rule lift score measuring how much more often this transition occurs for this artist than globally';


--
-- TOC entry 5230 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.weighted_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.weighted_score IS 'Calculated score weighting transition count and lift';


--
-- TOC entry 5231 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN mv_artist_transition_features.rarity_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_features.rarity_weight IS 'Weighting value based on tune or transition rarity';


--
-- TOC entry 327 (class 1259 OID 785038)
-- Name: mv_artist_pathway_related_artists; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_artist_pathway_related_artists AS
 WITH artist_transitions AS (
         SELECT mv_artist_transition_features.artist_name,
            mv_artist_transition_features.source_tune_id,
            mv_artist_transition_features.source_tune_name,
            mv_artist_transition_features.target_tune_id,
            mv_artist_transition_features.target_tune_name,
            mv_artist_transition_features.weighted_score,
            mv_artist_transition_features.transition_count,
            mv_artist_transition_features.global_transition_count
           FROM thesession.mv_artist_transition_features
          WHERE (mv_artist_transition_features.global_transition_count >= 2)
        ), exact_transition AS (
         SELECT a.artist_name AS artist_a,
            b.artist_name AS artist_b,
            a.source_tune_id,
            a.source_tune_name,
            a.target_tune_id,
            a.target_tune_name,
            'shared_transition'::text AS edge_reason,
            (100)::numeric AS reason_weight
           FROM (artist_transitions a
             JOIN artist_transitions b ON (((b.source_tune_id = a.source_tune_id) AND (b.target_tune_id = a.target_tune_id) AND (b.artist_name <> a.artist_name))))
        ), same_source AS (
         SELECT a.artist_name AS artist_a,
            b.artist_name AS artist_b,
            a.source_tune_id,
            a.source_tune_name,
            a.target_tune_id,
            a.target_tune_name,
            'same_start_tune'::text AS edge_reason,
            (25)::numeric AS reason_weight
           FROM (artist_transitions a
             JOIN artist_transitions b ON (((b.source_tune_id = a.source_tune_id) AND (b.artist_name <> a.artist_name))))
        ), same_target AS (
         SELECT a.artist_name AS artist_a,
            b.artist_name AS artist_b,
            a.source_tune_id,
            a.source_tune_name,
            a.target_tune_id,
            a.target_tune_name,
            'same_destination_tune'::text AS edge_reason,
            (20)::numeric AS reason_weight
           FROM (artist_transitions a
             JOIN artist_transitions b ON (((b.target_tune_id = a.target_tune_id) AND (b.artist_name <> a.artist_name))))
        ), combined AS (
         SELECT exact_transition.artist_a,
            exact_transition.artist_b,
            exact_transition.source_tune_id,
            exact_transition.source_tune_name,
            exact_transition.target_tune_id,
            exact_transition.target_tune_name,
            exact_transition.edge_reason,
            exact_transition.reason_weight
           FROM exact_transition
        UNION ALL
         SELECT same_source.artist_a,
            same_source.artist_b,
            same_source.source_tune_id,
            same_source.source_tune_name,
            same_source.target_tune_id,
            same_source.target_tune_name,
            same_source.edge_reason,
            same_source.reason_weight
           FROM same_source
        UNION ALL
         SELECT same_target.artist_a,
            same_target.artist_b,
            same_target.source_tune_id,
            same_target.source_tune_name,
            same_target.target_tune_id,
            same_target.target_tune_name,
            same_target.edge_reason,
            same_target.reason_weight
           FROM same_target
        )
 SELECT artist_a,
    artist_b,
    source_tune_id,
    source_tune_name,
    target_tune_id,
    target_tune_name,
    edge_reason,
    count(*) AS evidence_count,
    sum(reason_weight) AS relation_score
   FROM combined
  GROUP BY artist_a, artist_b, source_tune_id, source_tune_name, target_tune_id, target_tune_name, edge_reason
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_artist_pathway_related_artists OWNER TO folkguitar;

--
-- TOC entry 5232 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.artist_a; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.artist_a IS 'Name of the source artist';


--
-- TOC entry 5233 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.artist_b; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.artist_b IS 'Name of the related/destination artist';


--
-- TOC entry 5234 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.source_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.source_tune_id IS 'ID of the tune recorded by artist A';


--
-- TOC entry 5235 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.source_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.source_tune_name IS 'Name of the tune recorded by artist A';


--
-- TOC entry 5236 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.target_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.target_tune_id IS 'ID of the tune recorded by artist B';


--
-- TOC entry 5237 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.target_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.target_tune_name IS 'Name of the tune recorded by artist B';


--
-- TOC entry 5238 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.edge_reason; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.edge_reason IS 'Description of how the artists connect (e.g., recorded same set sequence or track)';


--
-- TOC entry 5239 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.evidence_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.evidence_count IS 'Number of transition tracks serving as evidence for connection';


--
-- TOC entry 5240 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN mv_artist_pathway_related_artists.relation_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_pathway_related_artists.relation_score IS 'Calculated strength of relationship between artist A and artist B';


--
-- TOC entry 329 (class 1259 OID 799827)
-- Name: mv_artist_transition_evidence; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_artist_transition_evidence AS
 WITH ordered AS (
         SELECT session_recording.artist_name,
            session_recording.recording,
            session_recording.track,
            session_recording.tune_number AS source_tune_number,
            session_recording.tune_id AS source_tune_id,
            session_recording.tune_name AS source_tune_name,
            lead(session_recording.tune_number) OVER (PARTITION BY session_recording.artist_name, session_recording.recording, session_recording.track ORDER BY session_recording.tune_number) AS target_tune_number,
            lead(session_recording.tune_id) OVER (PARTITION BY session_recording.artist_name, session_recording.recording, session_recording.track ORDER BY session_recording.tune_number) AS target_tune_id,
            lead(session_recording.tune_name) OVER (PARTITION BY session_recording.artist_name, session_recording.recording, session_recording.track ORDER BY session_recording.tune_number) AS target_tune_name
           FROM thesession.session_recording
          WHERE ((session_recording.artist_name IS NOT NULL) AND (TRIM(BOTH FROM session_recording.artist_name) <> ''::text) AND (session_recording.artist_name <> 'Various Artists'::text))
        )
 SELECT artist_name,
    recording,
    track,
    source_tune_number,
    target_tune_number,
    source_tune_id,
    source_tune_name,
    target_tune_id,
    target_tune_name
   FROM ordered
  WHERE ((target_tune_id IS NOT NULL) AND (source_tune_id <> target_tune_id))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_artist_transition_evidence OWNER TO folkguitar;

--
-- TOC entry 5241 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5242 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.recording; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.recording IS 'Field recording on mv_artist_transition_evidence';


--
-- TOC entry 5243 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.track IS 'Track number on the album or recording';


--
-- TOC entry 5244 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.source_tune_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.source_tune_number IS 'Field source_tune_number on mv_artist_transition_evidence';


--
-- TOC entry 5245 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.target_tune_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.target_tune_number IS 'Field target_tune_number on mv_artist_transition_evidence';


--
-- TOC entry 5246 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.source_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.source_tune_id IS 'ID of the source_tune';


--
-- TOC entry 5247 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.source_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.source_tune_name IS 'Name of the source_tune';


--
-- TOC entry 5248 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.target_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.target_tune_id IS 'ID of the target_tune';


--
-- TOC entry 5249 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN mv_artist_transition_evidence.target_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_artist_transition_evidence.target_tune_name IS 'Name of the target_tune';


--
-- TOC entry 293 (class 1259 OID 399777)
-- Name: tune_collection_item; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.tune_collection_item (
    id bigint NOT NULL,
    collection_id bigint NOT NULL,
    tune_id integer NOT NULL,
    tune_name text,
    tune_url text,
    identifier text,
    "position" integer,
    created_at timestamp with time zone DEFAULT now(),
    tune_slug text,
    page integer
);


ALTER TABLE thesession.tune_collection_item OWNER TO folkguitar;

--
-- TOC entry 305 (class 1259 OID 532929)
-- Name: mv_collection_overlap; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_collection_overlap AS
 WITH collection_tune_distinct AS (
         SELECT DISTINCT i.collection_id,
            i.tune_id
           FROM thesession.tune_collection_item i
          WHERE (i.tune_id IS NOT NULL)
        ), collection_sizes AS (
         SELECT ctd.collection_id,
            count(*) AS total_tunes
           FROM collection_tune_distinct ctd
          GROUP BY ctd.collection_id
        ), pair_shared AS (
         SELECT a.collection_id AS collection_id_1,
            b.collection_id AS collection_id_2,
            count(*) AS shared_tune_count
           FROM (collection_tune_distinct a
             JOIN collection_tune_distinct b ON (((a.tune_id = b.tune_id) AND (a.collection_id < b.collection_id))))
          GROUP BY a.collection_id, b.collection_id
        )
 SELECT ps.collection_id_1,
    ps.collection_id_2,
    ps.shared_tune_count,
    s1.total_tunes AS total_tunes_1,
    s2.total_tunes AS total_tunes_2,
    round((((ps.shared_tune_count)::numeric / (NULLIF(s1.total_tunes, 0))::numeric) * (100)::numeric), 2) AS overlap_pct_1,
    round((((ps.shared_tune_count)::numeric / (NULLIF(s2.total_tunes, 0))::numeric) * (100)::numeric), 2) AS overlap_pct_2,
    ((s1.total_tunes + s2.total_tunes) - ps.shared_tune_count) AS union_tune_count,
    round(((ps.shared_tune_count)::numeric / (NULLIF(((s1.total_tunes + s2.total_tunes) - ps.shared_tune_count), 0))::numeric), 4) AS jaccard_score
   FROM ((pair_shared ps
     JOIN collection_sizes s1 ON ((s1.collection_id = ps.collection_id_1)))
     JOIN collection_sizes s2 ON ((s2.collection_id = ps.collection_id_2)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_collection_overlap OWNER TO folkguitar;

--
-- TOC entry 5250 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.collection_id_1; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.collection_id_1 IS 'ID of the first tune collection';


--
-- TOC entry 5251 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.collection_id_2; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.collection_id_2 IS 'ID of the second tune collection';


--
-- TOC entry 5252 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.shared_tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.shared_tune_count IS 'Number of common tunes shared between the two collections';


--
-- TOC entry 5253 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.total_tunes_1; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.total_tunes_1 IS 'Total number of tunes in the first collection';


--
-- TOC entry 5254 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.total_tunes_2; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.total_tunes_2 IS 'Total number of tunes in the second collection';


--
-- TOC entry 5255 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.overlap_pct_1; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.overlap_pct_1 IS 'Percentage of collection 1''s tunes that are also in collection 2';


--
-- TOC entry 5256 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.overlap_pct_2; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.overlap_pct_2 IS 'Percentage of collection 2''s tunes that are also in collection 1';


--
-- TOC entry 5257 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.union_tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.union_tune_count IS 'Total unique tunes combined from both collections';


--
-- TOC entry 5258 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN mv_collection_overlap.jaccard_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_collection_overlap.jaccard_score IS 'Jaccard similarity coefficient (shared tunes divided by union of tunes)';


--
-- TOC entry 296 (class 1259 OID 401917)
-- Name: mv_tune_names; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_names AS
 WITH tune_name_counts AS (
         SELECT session_recording.tune_id,
            session_recording.tune_name,
            count(*) AS name_count
           FROM thesession.session_recording
          WHERE ((session_recording.tune_id IS NOT NULL) AND (session_recording.tune_name IS NOT NULL) AND (session_recording.tune_name <> ''::text))
          GROUP BY session_recording.tune_id, session_recording.tune_name
        )
 SELECT tune_id,
    ( SELECT tnc2.tune_name
           FROM tune_name_counts tnc2
          WHERE (tnc2.tune_id = tnc.tune_id)
          ORDER BY tnc2.name_count DESC, tnc2.tune_name
         LIMIT 1) AS primary_name,
    array_agg(DISTINCT tune_name ORDER BY tune_name) AS aliases
   FROM tune_name_counts tnc
  GROUP BY tune_id
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_names OWNER TO folkguitar;

--
-- TOC entry 5259 (class 0 OID 0)
-- Dependencies: 296
-- Name: COLUMN mv_tune_names.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_names.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5260 (class 0 OID 0)
-- Dependencies: 296
-- Name: COLUMN mv_tune_names.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_names.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5261 (class 0 OID 0)
-- Dependencies: 296
-- Name: COLUMN mv_tune_names.aliases; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_names.aliases IS 'Array of alternative names or titles for the tune';


--
-- TOC entry 308 (class 1259 OID 544129)
-- Name: session_recording_album; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_recording_album (
    recording_id bigint NOT NULL,
    provider text NOT NULL,
    album_link text,
    image_url text,
    alt text,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE thesession.session_recording_album OWNER TO folkguitar;

--
-- TOC entry 273 (class 1259 OID 290945)
-- Name: session_tune_popularity_raw; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_tune_popularity_raw (
    tune_id bigint NOT NULL,
    name text NOT NULL,
    tunebooks integer NOT NULL,
    imported_at timestamp without time zone DEFAULT now(),
    slug text
);


ALTER TABLE thesession.session_tune_popularity_raw OWNER TO folkguitar;

--
-- TOC entry 272 (class 1259 OID 290784)
-- Name: session_tunes_raw; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_tunes_raw (
    tune_id bigint NOT NULL,
    setting_id bigint NOT NULL,
    name text,
    type text,
    meter text,
    mode text,
    abc text,
    date timestamp without time zone,
    username text,
    composer text,
    imported_at timestamp without time zone DEFAULT now(),
    slug text,
    incipit text,
    preview_abc text,
    preview_abc_part_b text,
    preview_part_b_confidence text
);


ALTER TABLE thesession.session_tunes_raw OWNER TO folkguitar;

--
-- TOC entry 320 (class 1259 OID 605357)
-- Name: mv_tune_meta; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_meta AS
 WITH all_tune_ids AS (
         SELECT mv_tune_names.tune_id
           FROM thesession.mv_tune_names
        UNION
         SELECT session_tunes_raw.tune_id
           FROM thesession.session_tunes_raw
          WHERE (session_tunes_raw.tune_id IS NOT NULL)
        UNION
         SELECT session_tune_popularity_raw.tune_id
           FROM thesession.session_tune_popularity_raw
          WHERE (session_tune_popularity_raw.tune_id IS NOT NULL)
        UNION
         SELECT session_recording.tune_id
           FROM thesession.session_recording
          WHERE (session_recording.tune_id IS NOT NULL)
        ), latest_attrs AS (
         SELECT DISTINCT ON (r.tune_id) r.tune_id,
            r.type,
            r.meter,
            r.mode
           FROM thesession.session_tunes_raw r
          WHERE (r.tune_id IS NOT NULL)
          ORDER BY r.tune_id, r.imported_at DESC, r.date DESC
        ), latest_names AS (
         SELECT DISTINCT ON (r.tune_id) r.tune_id,
            r.name
           FROM thesession.session_tunes_raw r
          WHERE (r.tune_id IS NOT NULL)
          ORDER BY r.tune_id, r.imported_at DESC, r.date DESC
        ), latest_incipits AS (
         SELECT DISTINCT ON (r.tune_id) r.tune_id,
            r.incipit
           FROM thesession.session_tunes_raw r
          WHERE ((r.tune_id IS NOT NULL) AND (r.incipit IS NOT NULL) AND (btrim(r.incipit) <> ''::text))
          ORDER BY r.tune_id, r.imported_at DESC, r.date DESC
        ), popularity AS (
         SELECT p.tune_id,
            p.name,
            p.tunebooks,
                CASE
                    WHEN (p.tunebooks >= 212) THEN 5
                    WHEN (p.tunebooks >= 71) THEN 4
                    WHEN (p.tunebooks >= 27) THEN 3
                    WHEN (p.tunebooks >= 15) THEN 2
                    ELSE 1
                END AS star_rating
           FROM thesession.session_tune_popularity_raw p
        ), recording_albums AS (
         SELECT sr.tune_id,
            true AS has_recording_albums,
            array_agg(DISTINCT sra.recording_id ORDER BY sra.recording_id) AS recording_album_recording_ids
           FROM (thesession.session_recording sr
             JOIN thesession.session_recording_album sra ON ((sra.recording_id = sr.id)))
          WHERE (sr.tune_id IS NOT NULL)
          GROUP BY sr.tune_id
        )
 SELECT ids.tune_id,
    COALESCE(n.primary_name, ln.name, pop.name) AS primary_name,
    n.aliases,
    a.type,
    a.meter,
    a.mode,
    i.incipit,
    pop.tunebooks,
    pop.star_rating,
    COALESCE(ra.has_recording_albums, false) AS has_recording_albums,
    ra.recording_album_recording_ids
   FROM ((((((all_tune_ids ids
     LEFT JOIN thesession.mv_tune_names n ON ((n.tune_id = ids.tune_id)))
     LEFT JOIN latest_attrs a ON ((a.tune_id = ids.tune_id)))
     LEFT JOIN latest_names ln ON ((ln.tune_id = ids.tune_id)))
     LEFT JOIN latest_incipits i ON ((i.tune_id = ids.tune_id)))
     LEFT JOIN popularity pop ON ((pop.tune_id = ids.tune_id)))
     LEFT JOIN recording_albums ra ON ((ra.tune_id = ids.tune_id)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_meta OWNER TO folkguitar;

--
-- TOC entry 5262 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5263 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5264 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.aliases; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.aliases IS 'Array of alternative names or titles for the tune';


--
-- TOC entry 5265 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5266 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5267 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5268 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5269 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.tunebooks; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.tunebooks IS 'Field tunebooks on mv_tune_meta';


--
-- TOC entry 5270 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.star_rating; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.star_rating IS 'Average star rating of the tune on TheSession.org';


--
-- TOC entry 5271 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.has_recording_albums; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.has_recording_albums IS 'Boolean flag indicating if the tune has been recorded on commercial albums';


--
-- TOC entry 5272 (class 0 OID 0)
-- Dependencies: 320
-- Name: COLUMN mv_tune_meta.recording_album_recording_ids; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_meta.recording_album_recording_ids IS 'Field recording_album_recording_ids on mv_tune_meta';


--
-- TOC entry 309 (class 1259 OID 588954)
-- Name: session_member_tunebook; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_member_tunebook (
    member_id bigint NOT NULL,
    tune_id bigint NOT NULL,
    tune_name text,
    tune_url text,
    type text,
    tune_date timestamp without time zone,
    added_at timestamp without time zone,
    source_page integer,
    fetched_at timestamp without time zone DEFAULT now()
);


ALTER TABLE thesession.session_member_tunebook OWNER TO folkguitar;

--
-- TOC entry 351 (class 1259 OID 944329)
-- Name: mv_country_tune_popularity; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_country_tune_popularity AS
 WITH country_members AS (
         SELECT DISTINCT mc.member_id,
            mc.country_code,
            mc.country_name
           FROM thesession.member_country mc
          WHERE (mc.country_code IS NOT NULL)
        ), country_totals AS (
         SELECT cm.country_code,
            cm.country_name,
            count(DISTINCT cm.member_id) AS country_members,
            count(*) AS country_tunebook_rows
           FROM (country_members cm
             JOIN thesession.session_member_tunebook mt ON ((mt.member_id = cm.member_id)))
          GROUP BY cm.country_code, cm.country_name
        ), global_tune_totals AS (
         SELECT session_member_tunebook.tune_id,
            count(*) AS global_tunebook_count,
            count(DISTINCT session_member_tunebook.member_id) AS global_member_count
           FROM thesession.session_member_tunebook
          GROUP BY session_member_tunebook.tune_id
        ), global_total AS (
         SELECT count(*) AS global_tunebook_rows
           FROM thesession.session_member_tunebook
        ), country_tune AS (
         SELECT cm.country_code,
            cm.country_name,
            mt.tune_id,
            count(*) AS country_tunebook_count,
            count(DISTINCT mt.member_id) AS country_member_count
           FROM (country_members cm
             JOIN thesession.session_member_tunebook mt ON ((mt.member_id = cm.member_id)))
          GROUP BY cm.country_code, cm.country_name, mt.tune_id
        )
 SELECT ct.country_code,
    ct.country_name,
    ct.tune_id,
    tm.primary_name AS tune_name,
    tm.type,
    tm.meter,
    tm.mode,
    tm.incipit,
    ct.country_tunebook_count,
    ct.country_member_count,
    ctot.country_members,
    ctot.country_tunebook_rows,
    gtt.global_tunebook_count,
    gtt.global_member_count,
    gt.global_tunebook_rows,
    round(((ct.country_tunebook_count)::numeric / (NULLIF(ctot.country_tunebook_rows, 0))::numeric), 8) AS country_share,
    round(((gtt.global_tunebook_count)::numeric / (NULLIF(gt.global_tunebook_rows, 0))::numeric), 8) AS global_share,
    round((((ct.country_tunebook_count)::numeric / (NULLIF(ctot.country_tunebook_rows, 0))::numeric) / NULLIF(((gtt.global_tunebook_count)::numeric / (NULLIF(gt.global_tunebook_rows, 0))::numeric), (0)::numeric)), 4) AS lift_score,
    round(((ln(((1 + ct.country_tunebook_count))::double precision))::numeric * ln(((1)::numeric + (((ct.country_tunebook_count)::numeric / (NULLIF(ctot.country_tunebook_rows, 0))::numeric) / NULLIF(((gtt.global_tunebook_count)::numeric / (NULLIF(gt.global_tunebook_rows, 0))::numeric), (0)::numeric))))), 4) AS weighted_country_score
   FROM ((((country_tune ct
     JOIN country_totals ctot ON ((ctot.country_code = ct.country_code)))
     JOIN global_tune_totals gtt ON ((gtt.tune_id = ct.tune_id)))
     CROSS JOIN global_total gt)
     LEFT JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = ct.tune_id)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_country_tune_popularity OWNER TO folkguitar;

--
-- TOC entry 5273 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_code; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_code IS 'ISO 2-letter country code of the session/member location';


--
-- TOC entry 5274 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_name IS 'Name of the country';


--
-- TOC entry 5275 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5276 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.tune_name IS 'Name of the tune';


--
-- TOC entry 5277 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5278 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5279 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5280 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5281 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_tunebook_count IS 'Number of members in this country who have this tune in their tunebook';


--
-- TOC entry 5282 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_member_count IS 'Total number of active Session members located in this country';


--
-- TOC entry 5283 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_members; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_members IS 'Array or count of members from this country';


--
-- TOC entry 5284 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_tunebook_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_tunebook_rows IS 'Total tunebook rows for all members in this country';


--
-- TOC entry 5285 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.global_tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.global_tunebook_count IS 'Global number of member tunebooks containing this tune';


--
-- TOC entry 5286 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.global_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.global_member_count IS 'Global number of active Session members';


--
-- TOC entry 5287 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.global_tunebook_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.global_tunebook_rows IS 'Total global tunebook entries/rows';


--
-- TOC entry 5288 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.country_share; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.country_share IS 'Tune''s percentage share of the country''s total tunebook entries';


--
-- TOC entry 5289 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.global_share; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.global_share IS 'Tune''s percentage share of the global total tunebook entries';


--
-- TOC entry 5290 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.lift_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.lift_score IS 'Ratio of country share to global share (lift > 1 indicates local popularity)';


--
-- TOC entry 5291 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN mv_country_tune_popularity.weighted_country_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_popularity.weighted_country_score IS 'Weighted popularity score for the tune in this country';


--
-- TOC entry 352 (class 1259 OID 944404)
-- Name: mv_country_similarity; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_country_similarity AS
 WITH country_vectors AS (
         SELECT mv_country_tune_popularity.country_name,
            mv_country_tune_popularity.tune_id,
            mv_country_tune_popularity.weighted_country_score
           FROM thesession.mv_country_tune_popularity
          WHERE (mv_country_tune_popularity.country_member_count >= 2)
        ), pairwise AS (
         SELECT a.country_name AS country_a,
            b.country_name AS country_b,
            count(*) AS shared_tunes,
            sum((a.weighted_country_score * b.weighted_country_score)) AS dot_product,
            sqrt(sum((a.weighted_country_score * a.weighted_country_score))) AS norm_a,
            sqrt(sum((b.weighted_country_score * b.weighted_country_score))) AS norm_b
           FROM (country_vectors a
             JOIN country_vectors b ON (((a.tune_id = b.tune_id) AND (a.country_name < b.country_name))))
          GROUP BY a.country_name, b.country_name
        )
 SELECT country_a,
    country_b,
    shared_tunes,
    round((dot_product / NULLIF((norm_a * norm_b), (0)::numeric)), 4) AS cosine_similarity,
    round(((((dot_product / NULLIF((norm_a * norm_b), (0)::numeric)))::double precision * ln(((1 + shared_tunes))::double precision)))::numeric, 4) AS adjusted_similarity
   FROM pairwise
  WHERE (shared_tunes >= 50)
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_country_similarity OWNER TO folkguitar;

--
-- TOC entry 5292 (class 0 OID 0)
-- Dependencies: 352
-- Name: COLUMN mv_country_similarity.country_a; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_similarity.country_a IS 'First country code/name';


--
-- TOC entry 5293 (class 0 OID 0)
-- Dependencies: 352
-- Name: COLUMN mv_country_similarity.country_b; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_similarity.country_b IS 'Second country code/name';


--
-- TOC entry 5294 (class 0 OID 0)
-- Dependencies: 352
-- Name: COLUMN mv_country_similarity.shared_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_similarity.shared_tunes IS 'Number of common tunes played/bookmarked in both countries';


--
-- TOC entry 5295 (class 0 OID 0)
-- Dependencies: 352
-- Name: COLUMN mv_country_similarity.cosine_similarity; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_similarity.cosine_similarity IS 'Cosine similarity score between the two countries'' tune popularity vectors';


--
-- TOC entry 5296 (class 0 OID 0)
-- Dependencies: 352
-- Name: COLUMN mv_country_similarity.adjusted_similarity; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_similarity.adjusted_similarity IS 'Adjusted similarity score accounting for country size and common biases';


--
-- TOC entry 323 (class 1259 OID 684022)
-- Name: session_member_bookmark_setting; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_member_bookmark_setting (
    member_id bigint NOT NULL,
    setting_id bigint NOT NULL,
    tune_id bigint NOT NULL,
    tune_name text,
    bookmarked_at timestamp without time zone NOT NULL
);


ALTER TABLE thesession.session_member_bookmark_setting OWNER TO folkguitar;

--
-- TOC entry 275 (class 1259 OID 291016)
-- Name: session_set_items_raw; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_set_items_raw (
    tuneset bigint NOT NULL,
    settingorder integer NOT NULL,
    tune_id bigint,
    setting_id bigint NOT NULL,
    name text,
    type text,
    meter text,
    mode text,
    abc text,
    slug text
);


ALTER TABLE thesession.session_set_items_raw OWNER TO folkguitar;

--
-- TOC entry 274 (class 1259 OID 291007)
-- Name: session_sets_raw; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_sets_raw (
    tuneset bigint NOT NULL,
    date timestamp without time zone,
    member_id bigint,
    username text,
    imported_at timestamp without time zone DEFAULT now()
);


ALTER TABLE thesession.session_sets_raw OWNER TO folkguitar;

--
-- TOC entry 353 (class 1259 OID 951604)
-- Name: mv_member_tune_signal; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_member_tune_signal AS
 SELECT mt.member_id,
    mt.tune_id,
    'tunebook'::text AS signal_type,
    1.00 AS signal_weight
   FROM thesession.session_member_tunebook mt
UNION ALL
 SELECT b.member_id,
    t.tune_id,
    'bookmark'::text AS signal_type,
    0.45 AS signal_weight
   FROM (thesession.session_member_bookmark_setting b
     JOIN thesession.session_tunes_raw t ON ((t.setting_id = b.setting_id)))
UNION ALL
 SELECT s.member_id,
    i.tune_id,
    'set'::text AS signal_type,
    1.50 AS signal_weight
   FROM (thesession.session_sets_raw s
     JOIN thesession.session_set_items_raw i ON ((i.tuneset = s.tuneset)))
  WHERE (i.tune_id IS NOT NULL)
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_member_tune_signal OWNER TO folkguitar;

--
-- TOC entry 5297 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN mv_member_tune_signal.member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_tune_signal.member_id IS 'Canonical ID of the Session member';


--
-- TOC entry 5298 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN mv_member_tune_signal.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_tune_signal.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5299 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN mv_member_tune_signal.signal_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_tune_signal.signal_type IS 'Type of relationship (e.g., tunebook, bookmark, set_submitter)';


--
-- TOC entry 5300 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN mv_member_tune_signal.signal_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_tune_signal.signal_weight IS 'Weight score representing the strength of the signal';


--
-- TOC entry 354 (class 1259 OID 951631)
-- Name: mv_country_tune_signal_popularity; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_country_tune_signal_popularity AS
 WITH country_signals AS (
         SELECT mc.country_code,
            mc.country_name,
            s.member_id,
            s.tune_id,
            s.signal_type,
            s.signal_weight
           FROM (thesession.mv_member_tune_signal s
             JOIN thesession.member_country mc ON ((mc.member_id = s.member_id)))
          WHERE (mc.country_code IS NOT NULL)
        ), country_totals AS (
         SELECT country_signals.country_code,
            country_signals.country_name,
            count(DISTINCT country_signals.member_id) AS country_signal_members,
            count(*) AS country_signal_rows,
            sum(country_signals.signal_weight) AS country_signal_weight
           FROM country_signals
          GROUP BY country_signals.country_code, country_signals.country_name
        ), global_tune_totals AS (
         SELECT mv_member_tune_signal.tune_id,
            count(*) AS global_signal_count,
            count(DISTINCT mv_member_tune_signal.member_id) AS global_signal_members,
            sum(mv_member_tune_signal.signal_weight) AS global_signal_weight
           FROM thesession.mv_member_tune_signal
          GROUP BY mv_member_tune_signal.tune_id
        ), global_total AS (
         SELECT count(*) AS global_signal_rows,
            sum(mv_member_tune_signal.signal_weight) AS global_signal_weight
           FROM thesession.mv_member_tune_signal
        ), country_tune AS (
         SELECT country_signals.country_code,
            country_signals.country_name,
            country_signals.tune_id,
            count(*) AS country_signal_count,
            count(DISTINCT country_signals.member_id) AS country_member_count,
            sum(country_signals.signal_weight) AS country_tune_weight,
            count(*) FILTER (WHERE (country_signals.signal_type = 'tunebook'::text)) AS tunebook_count,
            count(*) FILTER (WHERE (country_signals.signal_type = 'bookmark'::text)) AS bookmark_count,
            count(*) FILTER (WHERE (country_signals.signal_type = 'set'::text)) AS set_count
           FROM country_signals
          GROUP BY country_signals.country_code, country_signals.country_name, country_signals.tune_id
        )
 SELECT ct.country_code,
    ct.country_name,
    ct.tune_id,
    tm.primary_name AS tune_name,
    tm.type,
    tm.meter,
    tm.mode,
    tm.incipit,
    ct.country_signal_count,
    ct.country_member_count,
    ct.country_tune_weight,
    ct.tunebook_count,
    ct.bookmark_count,
    ct.set_count,
    ctot.country_signal_members,
    ctot.country_signal_rows,
    ctot.country_signal_weight,
    gtt.global_signal_count,
    gtt.global_signal_members,
    gtt.global_signal_weight,
    gt.global_signal_rows,
    gt.global_signal_weight AS total_global_signal_weight,
    round((ct.country_tune_weight / NULLIF(ctot.country_signal_weight, (0)::numeric)), 8) AS country_share,
    round((gtt.global_signal_weight / NULLIF(gt.global_signal_weight, (0)::numeric)), 8) AS global_share,
    round(((ct.country_tune_weight / NULLIF(ctot.country_signal_weight, (0)::numeric)) / NULLIF((gtt.global_signal_weight / NULLIF(gt.global_signal_weight, (0)::numeric)), (0)::numeric)), 4) AS lift_score,
    round((ln(((1)::numeric + ct.country_tune_weight)) * ln(((1)::numeric + ((ct.country_tune_weight / NULLIF(ctot.country_signal_weight, (0)::numeric)) / NULLIF((gtt.global_signal_weight / NULLIF(gt.global_signal_weight, (0)::numeric)), (0)::numeric))))), 4) AS weighted_country_score
   FROM ((((country_tune ct
     JOIN country_totals ctot ON ((ctot.country_code = ct.country_code)))
     JOIN global_tune_totals gtt ON ((gtt.tune_id = ct.tune_id)))
     CROSS JOIN global_total gt)
     LEFT JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = ct.tune_id)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_country_tune_signal_popularity OWNER TO folkguitar;

--
-- TOC entry 5301 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_code; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_code IS 'ISO 2-letter country code of the session/member location';


--
-- TOC entry 5302 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_name IS 'Name of the country';


--
-- TOC entry 5303 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5304 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.tune_name IS 'Name of the tune';


--
-- TOC entry 5305 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5306 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5307 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5308 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5309 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_signal_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_signal_count IS 'Combined local popularity signal count in this country';


--
-- TOC entry 5310 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_member_count IS 'Total members in this country contributing to signal';


--
-- TOC entry 5311 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_tune_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_tune_weight IS 'Normalized local weight of the tune in this country';


--
-- TOC entry 5312 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.tunebook_count IS 'Number of member tunebooks containing this tune';


--
-- TOC entry 5313 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.bookmark_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.bookmark_count IS 'Number of members who have bookmarked/saved this tune';


--
-- TOC entry 5314 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.set_count IS 'Count of sets';


--
-- TOC entry 5315 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_signal_members; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_signal_members IS 'Number of unique members in this country contributing to this tune''s signal';


--
-- TOC entry 5316 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_signal_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_signal_rows IS 'Total local signal rows/entries in this country';


--
-- TOC entry 5317 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_signal_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_signal_weight IS 'Sum of signal weights for this tune in this country';


--
-- TOC entry 5318 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.global_signal_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.global_signal_count IS 'Global combined signal count for this tune';


--
-- TOC entry 5319 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.global_signal_members; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.global_signal_members IS 'Global number of members contributing to this tune''s signal';


--
-- TOC entry 5320 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.global_signal_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.global_signal_weight IS 'Sum of global signal weights for this tune';


--
-- TOC entry 5321 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.global_signal_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.global_signal_rows IS 'Total global signal rows/entries';


--
-- TOC entry 5322 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.total_global_signal_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.total_global_signal_weight IS 'Total global signal weight sum across all tunes';


--
-- TOC entry 5323 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.country_share; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.country_share IS 'Tune''s signal weight share in this country';


--
-- TOC entry 5324 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.global_share; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.global_share IS 'Tune''s signal weight share globally';


--
-- TOC entry 5325 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.lift_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.lift_score IS 'Ratio of country signal share to global signal share';


--
-- TOC entry 5326 (class 0 OID 0)
-- Dependencies: 354
-- Name: COLUMN mv_country_tune_signal_popularity.weighted_country_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_country_tune_signal_popularity.weighted_country_score IS 'Weighted signal popularity score for this country';


--
-- TOC entry 332 (class 1259 OID 807360)
-- Name: mv_melody_setting_bars; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_setting_bars AS
 WITH src AS (
         SELECT session_tunes_raw.setting_id,
            session_tunes_raw.tune_id,
            session_tunes_raw.name,
            session_tunes_raw.type,
            session_tunes_raw.meter,
            session_tunes_raw.mode,
            thesession.abc_clean_for_melody(session_tunes_raw.abc) AS clean_abc
           FROM thesession.session_tunes_raw
          WHERE ((session_tunes_raw.abc IS NOT NULL) AND (btrim(session_tunes_raw.abc) <> ''::text))
        ), raw_bars AS (
         SELECT s.setting_id,
            s.tune_id,
            s.name,
            s.type,
            s.meter,
            s.mode,
            b.raw_bar_number,
            btrim(b.bar_text) AS bar_text
           FROM (src s
             CROSS JOIN LATERAL regexp_split_to_table(s.clean_abc, '\|+'::text) WITH ORDINALITY b(bar_text, raw_bar_number))
        ), note_rows AS (
         SELECT rb.setting_id,
            rb.tune_id,
            rb.name,
            rb.type,
            rb.meter,
            rb.mode,
            rb.raw_bar_number,
            rb.bar_text,
            m.note_order,
            m.matches[1] AS note_token,
            thesession.abc_token_pitch(m.matches[1]) AS pitch,
            thesession.abc_token_rhythm(m.matches[1]) AS rhythm
           FROM (raw_bars rb
             CROSS JOIN LATERAL regexp_matches(rb.bar_text, '([A-Ga-g][,'']*[0-9/]*)'::text, 'g'::text) WITH ORDINALITY m(matches, note_order))
        ), bar_rollup AS (
         SELECT note_rows.setting_id,
            note_rows.tune_id,
            note_rows.name,
            note_rows.type,
            note_rows.meter,
            note_rows.mode,
            note_rows.raw_bar_number,
            note_rows.bar_text,
            array_agg(note_rows.note_token ORDER BY note_rows.note_order) AS note_tokens,
            array_agg(note_rows.pitch ORDER BY note_rows.note_order) AS pitches,
            array_agg(note_rows.rhythm ORDER BY note_rows.note_order) AS rhythms,
            count(*) AS note_count
           FROM note_rows
          GROUP BY note_rows.setting_id, note_rows.tune_id, note_rows.name, note_rows.type, note_rows.meter, note_rows.mode, note_rows.raw_bar_number, note_rows.bar_text
        )
 SELECT row_number() OVER (PARTITION BY setting_id ORDER BY raw_bar_number) AS bar_number,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    raw_bar_number,
    bar_text,
    note_tokens,
    pitches,
    rhythms,
    note_count
   FROM bar_rollup
  WHERE (note_count > 0)
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_setting_bars OWNER TO folkguitar;

--
-- TOC entry 5327 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.bar_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.bar_number IS 'Bar number within the tune setting';


--
-- TOC entry 5328 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.setting_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.setting_id IS 'Canonical ID of the specific tune setting/transcription';


--
-- TOC entry 5329 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5330 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.name IS 'Field name on mv_melody_setting_bars';


--
-- TOC entry 5331 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5332 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5333 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5334 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.raw_bar_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.raw_bar_number IS 'Field raw_bar_number on mv_melody_setting_bars';


--
-- TOC entry 5335 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.bar_text; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.bar_text IS 'Melody notes in this bar in ABC format';


--
-- TOC entry 5336 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.note_tokens; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.note_tokens IS 'Field note_tokens on mv_melody_setting_bars';


--
-- TOC entry 5337 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.pitches; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.pitches IS 'Field pitches on mv_melody_setting_bars';


--
-- TOC entry 5338 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.rhythms; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.rhythms IS 'Field rhythms on mv_melody_setting_bars';


--
-- TOC entry 5339 (class 0 OID 0)
-- Dependencies: 332
-- Name: COLUMN mv_melody_setting_bars.note_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_setting_bars.note_count IS 'Number of notes in the bar';


--
-- TOC entry 333 (class 1259 OID 807407)
-- Name: mv_melody_2bar_fragments_old; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_old AS
 SELECT concat(b1.setting_id, ':', b1.bar_number, '-', b2.bar_number) AS fragment_id,
    b1.setting_id,
    b1.tune_id,
    b1.name,
    b1.type,
    b1.meter,
    b1.mode,
    b1.bar_number AS bar_start,
    b2.bar_number AS bar_end,
    b1.raw_bar_number AS raw_bar_start,
    b2.raw_bar_number AS raw_bar_end,
    b1.bar_text AS bar_1_text,
    b2.bar_text AS bar_2_text,
    b1.note_count AS bar_1_note_count,
    b2.note_count AS bar_2_note_count,
    (b1.note_tokens || b2.note_tokens) AS note_tokens,
    (b1.pitches || b2.pitches) AS pitches,
    (b1.rhythms || b2.rhythms) AS rhythms,
    array_length((b1.pitches || b2.pitches), 1) AS note_count,
    thesession.melody_interval_fingerprint((b1.pitches || b2.pitches)) AS interval_fingerprint,
    array_to_string((b1.rhythms || b2.rhythms), ','::text) AS rhythm_fingerprint
   FROM (thesession.mv_melody_setting_bars b1
     JOIN thesession.mv_melody_setting_bars b2 ON (((b2.setting_id = b1.setting_id) AND (b2.bar_number = (b1.bar_number + 1)))))
  WHERE ((b1.note_count >= 4) AND (b2.note_count >= 4) AND (array_length((b1.pitches || b2.pitches), 1) >= 8))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_old OWNER TO folkguitar;

--
-- TOC entry 334 (class 1259 OID 807700)
-- Name: mv_melody_2bar_fragment_ngrams_old; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_fragment_ngrams_old AS
 WITH fragments AS (
         SELECT mv_melody_2bar_fragments_old.fragment_id,
            mv_melody_2bar_fragments_old.setting_id,
            mv_melody_2bar_fragments_old.tune_id,
            mv_melody_2bar_fragments_old.name,
            mv_melody_2bar_fragments_old.type,
            mv_melody_2bar_fragments_old.meter,
            mv_melody_2bar_fragments_old.mode,
            mv_melody_2bar_fragments_old.bar_start,
            mv_melody_2bar_fragments_old.bar_end,
            mv_melody_2bar_fragments_old.bar_1_text,
            mv_melody_2bar_fragments_old.bar_2_text,
            mv_melody_2bar_fragments_old.interval_fingerprint,
            mv_melody_2bar_fragments_old.rhythm_fingerprint,
            string_to_array(mv_melody_2bar_fragments_old.interval_fingerprint, ','::text) AS interval_parts,
            string_to_array(mv_melody_2bar_fragments_old.rhythm_fingerprint, ','::text) AS rhythm_parts
           FROM thesession.mv_melody_2bar_fragments_old
          WHERE ((mv_melody_2bar_fragments_old.interval_fingerprint IS NOT NULL) AND (btrim(mv_melody_2bar_fragments_old.interval_fingerprint) <> ''::text))
        ), ngrams AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.interval_fingerprint,
            f.rhythm_fingerprint,
            f.interval_parts,
            f.rhythm_parts,
            4 AS ngram_size,
            gs.pos AS ngram_position,
            array_to_string(f.interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS interval_ngram,
            array_to_string(f.rhythm_parts[gs.pos:(gs.pos + 4)], ','::text) AS rhythm_ngram
           FROM (fragments f
             CROSS JOIN LATERAL generate_series(1, GREATEST(((array_length(f.interval_parts, 1) - 4) + 1), 0)) gs(pos))
        )
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    ngram_size,
    ngram_position,
    interval_ngram,
    rhythm_ngram
   FROM ngrams
  WHERE ((interval_ngram IS NOT NULL) AND (btrim(interval_ngram) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_fragment_ngrams_old OWNER TO folkguitar;

--
-- TOC entry 343 (class 1259 OID 889504)
-- Name: mv_melody_2bar_fragments_test; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_test AS
 SELECT concat(b1.setting_id, ':', b1.bar_number, '-', b2.bar_number) AS fragment_id,
    b1.setting_id,
    b1.tune_id,
    b1.name,
    b1.type,
    b1.meter,
    b1.mode,
    b1.bar_number AS bar_start,
    b2.bar_number AS bar_end,
    b1.bar_text AS bar_1_text,
    b2.bar_text AS bar_2_text,
    b1.note_count AS bar_1_note_count,
    b2.note_count AS bar_2_note_count,
    (b1.note_tokens || b2.note_tokens) AS note_tokens,
    (b1.pitches || b2.pitches) AS pitches,
    (b1.rhythms || b2.rhythms) AS rhythms,
    array_length((b1.pitches || b2.pitches), 1) AS note_count,
    thesession.melody_interval_fingerprint((b1.pitches || b2.pitches)) AS interval_fingerprint,
    array_to_string((b1.rhythms || b2.rhythms), ','::text) AS rhythm_fingerprint
   FROM (thesession.mv_melody_setting_bars b1
     JOIN thesession.mv_melody_setting_bars b2 ON (((b2.setting_id = b1.setting_id) AND (b2.bar_number = (b1.bar_number + 1)))))
  WHERE (((b1.note_count >= 4) AND (b2.note_count >= 4) AND (array_length((b1.pitches || b2.pitches), 1) >= 8)) OR ((lower(COALESCE(b1.type, ''::text)) = 'polka'::text) AND (COALESCE(b1.meter, ''::text) = '2/4'::text) AND (b1.note_count >= 2) AND (b2.note_count >= 2) AND (array_length((b1.pitches || b2.pitches), 1) >= 5)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_test OWNER TO folkguitar;

--
-- TOC entry 344 (class 1259 OID 889525)
-- Name: mv_melody_2bar_fragments_v5; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_v5 AS
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    bar_1_note_count,
    bar_2_note_count,
    note_tokens,
    pitches,
    rhythms,
    note_count,
    interval_fingerprint,
    rhythm_fingerprint
   FROM thesession.mv_melody_2bar_fragments_test
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_fragments_v5 OWNER TO folkguitar;

--
-- TOC entry 5340 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.fragment_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.fragment_id IS 'Unique identifier of the 2-bar melody fragment';


--
-- TOC entry 5341 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.setting_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.setting_id IS 'Canonical ID of the specific tune setting/transcription';


--
-- TOC entry 5342 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5343 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.name IS 'Field name on mv_melody_2bar_fragments_v5';


--
-- TOC entry 5344 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5345 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5346 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5347 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_start; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_start IS 'Starting bar number of the melody fragment within the setting';


--
-- TOC entry 5348 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_end; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_end IS 'Ending bar number of the melody fragment within the setting';


--
-- TOC entry 5349 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_1_text; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_1_text IS 'Melody notes in the first bar of the fragment';


--
-- TOC entry 5350 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_2_text; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_2_text IS 'Melody notes in the second bar of the fragment';


--
-- TOC entry 5351 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_1_note_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_1_note_count IS 'Count of bar 1 notes';


--
-- TOC entry 5352 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.bar_2_note_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.bar_2_note_count IS 'Count of bar 2 notes';


--
-- TOC entry 5353 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.note_tokens; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.note_tokens IS 'Field note_tokens on mv_melody_2bar_fragments_v5';


--
-- TOC entry 5354 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.pitches; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.pitches IS 'Field pitches on mv_melody_2bar_fragments_v5';


--
-- TOC entry 5355 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.rhythms; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.rhythms IS 'Field rhythms on mv_melody_2bar_fragments_v5';


--
-- TOC entry 5356 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.note_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.note_count IS 'Total number of notes in the 2-bar fragment';


--
-- TOC entry 5357 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.interval_fingerprint; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.interval_fingerprint IS 'Condensed interval representation for matching';


--
-- TOC entry 5358 (class 0 OID 0)
-- Dependencies: 344
-- Name: COLUMN mv_melody_2bar_fragments_v5.rhythm_fingerprint; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragments_v5.rhythm_fingerprint IS 'Condensed rhythm/duration representation for matching';


--
-- TOC entry 345 (class 1259 OID 889669)
-- Name: mv_melody_2bar_fragment_ngrams_v5; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_fragment_ngrams_v5 AS
 WITH fragments AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            fp.interval_fingerprint,
            fp.rhythm_fingerprint,
            thesession.melody_contour_fingerprint(fp.interval_fingerprint) AS fragment_contour_fingerprint,
            thesession.melody_coarse_interval_fingerprint(fp.interval_fingerprint) AS fragment_coarse_fingerprint,
            string_to_array(fp.interval_fingerprint, ','::text) AS interval_parts,
            string_to_array(thesession.melody_coarse_interval_fingerprint(fp.interval_fingerprint), ','::text) AS coarse_interval_parts,
            string_to_array(fp.rhythm_fingerprint, ','::text) AS rhythm_parts
           FROM (thesession.mv_melody_2bar_fragments_v5 f
             CROSS JOIN LATERAL thesession.melody_2bar_fuzzy_fingerprint_from_abc((((('| '::text || f.bar_1_text) || ' | '::text) || f.bar_2_text) || ' |'::text)) fp(bar_count, note_count, interval_fingerprint, rhythm_fingerprint))
          WHERE ((fp.interval_fingerprint IS NOT NULL) AND (btrim(fp.interval_fingerprint) <> ''::text))
        ), ngrams AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.fragment_contour_fingerprint,
            f.fragment_coarse_fingerprint,
            4 AS ngram_size,
            gs.pos AS ngram_position,
            array_to_string(f.interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS interval_ngram,
            array_to_string(f.coarse_interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS coarse_interval_ngram,
            array_to_string(f.rhythm_parts[gs.pos:(gs.pos + 4)], ','::text) AS rhythm_ngram
           FROM (fragments f
             CROSS JOIN LATERAL generate_series(1, GREATEST(((array_length(f.interval_parts, 1) - 4) + 1), 0)) gs(pos))
        )
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    fragment_contour_fingerprint,
    fragment_coarse_fingerprint,
    ngram_size,
    ngram_position,
    interval_ngram,
    coarse_interval_ngram,
    rhythm_ngram
   FROM ngrams
  WHERE ((interval_ngram IS NOT NULL) AND (btrim(interval_ngram) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_fragment_ngrams_v5 OWNER TO folkguitar;

--
-- TOC entry 5359 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.fragment_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.fragment_id IS 'Unique identifier of the 2-bar melody fragment';


--
-- TOC entry 5360 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.setting_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.setting_id IS 'Canonical ID of the specific tune setting/transcription';


--
-- TOC entry 5361 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5362 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.name IS 'Field name on mv_melody_2bar_fragment_ngrams_v5';


--
-- TOC entry 5363 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5364 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5365 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5366 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.bar_start; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.bar_start IS 'Starting bar number of the melody fragment within the setting';


--
-- TOC entry 5367 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.bar_end; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.bar_end IS 'Ending bar number of the melody fragment within the setting';


--
-- TOC entry 5368 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.bar_1_text; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.bar_1_text IS 'Melody notes in the first bar of the fragment';


--
-- TOC entry 5369 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.bar_2_text; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.bar_2_text IS 'Melody notes in the second bar of the fragment';


--
-- TOC entry 5370 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.fragment_contour_fingerprint; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.fragment_contour_fingerprint IS 'Melodic contour fingerprint representing the pitch rises and falls';


--
-- TOC entry 5371 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.fragment_coarse_fingerprint; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.fragment_coarse_fingerprint IS 'Coarse interval fingerprint for wider interval matches';


--
-- TOC entry 5372 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.ngram_size; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.ngram_size IS 'Size of the n-gram snippet';


--
-- TOC entry 5373 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.ngram_position; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.ngram_position IS 'Starting position of the n-gram in the fragment';


--
-- TOC entry 5374 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.interval_ngram; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.interval_ngram IS 'Interval transition n-gram representation';


--
-- TOC entry 5375 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.coarse_interval_ngram; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.coarse_interval_ngram IS 'Coarse interval transition n-gram representation';


--
-- TOC entry 5376 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN mv_melody_2bar_fragment_ngrams_v5.rhythm_ngram; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_fragment_ngrams_v5.rhythm_ngram IS 'Rhythm duration n-gram representation';


--
-- TOC entry 335 (class 1259 OID 807745)
-- Name: mv_melody_2bar_ngram_stats_old; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_ngram_stats_old AS
 SELECT interval_ngram,
    count(*) AS row_count,
    count(DISTINCT tune_id) AS tune_count,
    count(DISTINCT fragment_id) AS fragment_count
   FROM thesession.mv_melody_2bar_fragment_ngrams_old
  GROUP BY interval_ngram
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_ngram_stats_old OWNER TO folkguitar;

--
-- TOC entry 346 (class 1259 OID 889741)
-- Name: mv_melody_2bar_ngram_stats_v5; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_melody_2bar_ngram_stats_v5 AS
 SELECT interval_ngram,
    coarse_interval_ngram,
    count(*) AS row_count,
    count(DISTINCT tune_id) AS tune_count,
    count(DISTINCT fragment_id) AS fragment_count,
    ((1.0)::double precision / sqrt((count(*))::double precision)) AS rarity_weight
   FROM thesession.mv_melody_2bar_fragment_ngrams_v5
  GROUP BY interval_ngram, coarse_interval_ngram
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_melody_2bar_ngram_stats_v5 OWNER TO folkguitar;

--
-- TOC entry 5377 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.interval_ngram; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.interval_ngram IS 'Interval transition n-gram value';


--
-- TOC entry 5378 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.coarse_interval_ngram; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.coarse_interval_ngram IS 'Coarse interval transition n-gram value';


--
-- TOC entry 5379 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.row_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.row_count IS 'Total occurrences of this n-gram in the fragments';


--
-- TOC entry 5380 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.tune_count IS 'Number of unique tunes containing this n-gram';


--
-- TOC entry 5381 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.fragment_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.fragment_count IS 'Number of unique fragments containing this n-gram';


--
-- TOC entry 5382 (class 0 OID 0)
-- Dependencies: 346
-- Name: COLUMN mv_melody_2bar_ngram_stats_v5.rarity_weight; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_melody_2bar_ngram_stats_v5.rarity_weight IS 'Field rarity_weight on mv_melody_2bar_ngram_stats_v5';


--
-- TOC entry 298 (class 1259 OID 436178)
-- Name: session_member; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_member (
    id bigint NOT NULL,
    name text NOT NULL,
    url text NOT NULL,
    latitude numeric(10,8),
    longitude numeric(11,8),
    joined_at timestamp without time zone,
    bio text,
    tunebook_count integer DEFAULT 0,
    trips_count integer DEFAULT 0,
    sets_count integer DEFAULT 0,
    settings_count integer DEFAULT 0,
    recordings_count integer DEFAULT 0,
    sessions_count integer DEFAULT 0,
    events_count integer DEFAULT 0,
    discussions_count integer DEFAULT 0,
    comments_count integer DEFAULT 0,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    bookmarks_scraped boolean DEFAULT false,
    bookmarks_scraped_at timestamp without time zone
);


ALTER TABLE thesession.session_member OWNER TO folkguitar;

--
-- TOC entry 310 (class 1259 OID 591895)
-- Name: mv_member_search; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_member_search AS
 SELECT id AS member_id,
    name AS username,
    lower(name) AS username_lc,
    url,
    joined_at,
    COALESCE(tunebook_count, 0) AS tunebook_count,
    COALESCE(sets_count, 0) AS sets_count,
    COALESCE(settings_count, 0) AS settings_count,
    COALESCE(recordings_count, 0) AS recordings_count,
    COALESCE(sessions_count, 0) AS sessions_count,
    COALESCE(comments_count, 0) AS comments_count,
    COALESCE(discussions_count, 0) AS discussions_count,
    COALESCE(events_count, 0) AS events_count,
    COALESCE(trips_count, 0) AS trips_count
   FROM thesession.session_member m
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_member_search OWNER TO folkguitar;

--
-- TOC entry 5383 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.member_id IS 'Canonical ID of the Session member';


--
-- TOC entry 5384 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.username; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.username IS 'Field username on mv_member_search';


--
-- TOC entry 5385 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.username_lc; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.username_lc IS 'Field username_lc on mv_member_search';


--
-- TOC entry 5386 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.url; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.url IS 'Field url on mv_member_search';


--
-- TOC entry 5387 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.joined_at; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.joined_at IS 'Field joined_at on mv_member_search';


--
-- TOC entry 5388 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.tunebook_count IS 'Number of tunes in the member''s tunebook';


--
-- TOC entry 5389 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.sets_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.sets_count IS 'Count of setss';


--
-- TOC entry 5390 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.settings_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.settings_count IS 'Total settings/transcriptions of this tune on TheSession.org';


--
-- TOC entry 5391 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.recordings_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.recordings_count IS 'Count of recordingss';


--
-- TOC entry 5392 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.sessions_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.sessions_count IS 'Count of sessionss';


--
-- TOC entry 5393 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.comments_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.comments_count IS 'Count of commentss';


--
-- TOC entry 5394 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.discussions_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.discussions_count IS 'Count of discussionss';


--
-- TOC entry 5395 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.events_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.events_count IS 'Count of eventss';


--
-- TOC entry 5396 (class 0 OID 0)
-- Dependencies: 310
-- Name: COLUMN mv_member_search.trips_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_search.trips_count IS 'Count of tripss';


--
-- TOC entry 302 (class 1259 OID 482417)
-- Name: mv_member_set_activity; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_member_set_activity AS
 WITH monthly AS (
         SELECT session_sets_raw.member_id,
            'month'::text AS period_type,
            (date_trunc('month'::text, session_sets_raw.date))::date AS period_start,
            count(*) AS sets_added
           FROM thesession.session_sets_raw
          WHERE ((session_sets_raw.member_id IS NOT NULL) AND (session_sets_raw.date IS NOT NULL))
          GROUP BY session_sets_raw.member_id, (date_trunc('month'::text, session_sets_raw.date))
        ), weekly AS (
         SELECT session_sets_raw.member_id,
            'week'::text AS period_type,
            (date_trunc('week'::text, session_sets_raw.date))::date AS period_start,
            count(*) AS sets_added
           FROM thesession.session_sets_raw
          WHERE ((session_sets_raw.member_id IS NOT NULL) AND (session_sets_raw.date IS NOT NULL))
          GROUP BY session_sets_raw.member_id, (date_trunc('week'::text, session_sets_raw.date))
        ), base AS (
         SELECT monthly.member_id,
            monthly.period_type,
            monthly.period_start,
            monthly.sets_added
           FROM monthly
        UNION ALL
         SELECT weekly.member_id,
            weekly.period_type,
            weekly.period_start,
            weekly.sets_added
           FROM weekly
        )
 SELECT member_id,
    period_type,
    period_start,
    sets_added,
    sum(sets_added) OVER (PARTITION BY member_id, period_type ORDER BY period_start ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_sets
   FROM base
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_member_set_activity OWNER TO folkguitar;

--
-- TOC entry 5397 (class 0 OID 0)
-- Dependencies: 302
-- Name: COLUMN mv_member_set_activity.member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_activity.member_id IS 'Canonical ID of the Session member';


--
-- TOC entry 5398 (class 0 OID 0)
-- Dependencies: 302
-- Name: COLUMN mv_member_set_activity.period_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_activity.period_type IS 'Field period_type on mv_member_set_activity';


--
-- TOC entry 5399 (class 0 OID 0)
-- Dependencies: 302
-- Name: COLUMN mv_member_set_activity.period_start; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_activity.period_start IS 'Field period_start on mv_member_set_activity';


--
-- TOC entry 5400 (class 0 OID 0)
-- Dependencies: 302
-- Name: COLUMN mv_member_set_activity.sets_added; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_activity.sets_added IS 'Field sets_added on mv_member_set_activity';


--
-- TOC entry 5401 (class 0 OID 0)
-- Dependencies: 302
-- Name: COLUMN mv_member_set_activity.cumulative_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_activity.cumulative_sets IS 'Field cumulative_sets on mv_member_set_activity';


--
-- TOC entry 303 (class 1259 OID 482427)
-- Name: mv_member_set_summary; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_member_set_summary AS
 WITH name_counts AS (
         SELECT session_sets_raw.member_id,
            session_sets_raw.username,
            count(*) AS cnt
           FROM thesession.session_sets_raw
          WHERE ((session_sets_raw.member_id IS NOT NULL) AND (session_sets_raw.username IS NOT NULL))
          GROUP BY session_sets_raw.member_id, session_sets_raw.username
        ), best_name AS (
         SELECT name_counts.member_id,
            name_counts.username,
            name_counts.cnt,
            row_number() OVER (PARTITION BY name_counts.member_id ORDER BY name_counts.cnt DESC, name_counts.username) AS rn
           FROM name_counts
        ), monthly_counts AS (
         SELECT session_sets_raw.member_id,
            (date_trunc('month'::text, session_sets_raw.date))::date AS month_start,
            count(*) AS sets_added
           FROM thesession.session_sets_raw
          WHERE ((session_sets_raw.member_id IS NOT NULL) AND (session_sets_raw.date IS NOT NULL))
          GROUP BY session_sets_raw.member_id, (date_trunc('month'::text, session_sets_raw.date))
        ), summary_base AS (
         SELECT s.member_id,
            (min(s.date))::date AS first_set_date,
            (max(s.date))::date AS last_set_date,
            count(*) AS total_sets
           FROM thesession.session_sets_raw s
          WHERE ((s.member_id IS NOT NULL) AND (s.date IS NOT NULL))
          GROUP BY s.member_id
        ), peak_month AS (
         SELECT monthly_counts.member_id,
            monthly_counts.month_start AS most_active_month,
            monthly_counts.sets_added AS most_active_month_count,
            row_number() OVER (PARTITION BY monthly_counts.member_id ORDER BY monthly_counts.sets_added DESC, monthly_counts.month_start) AS rn
           FROM monthly_counts
        )
 SELECT sb.member_id,
    bn.username,
    sb.total_sets,
    sb.first_set_date,
    sb.last_set_date,
    pm.most_active_month,
    pm.most_active_month_count
   FROM ((summary_base sb
     LEFT JOIN best_name bn ON (((bn.member_id = sb.member_id) AND (bn.rn = 1))))
     LEFT JOIN peak_month pm ON (((pm.member_id = sb.member_id) AND (pm.rn = 1))))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_member_set_summary OWNER TO folkguitar;

--
-- TOC entry 5402 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.member_id IS 'Canonical ID of the Session member';


--
-- TOC entry 5403 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.username; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.username IS 'Field username on mv_member_set_summary';


--
-- TOC entry 5404 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.total_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.total_sets IS 'Field total_sets on mv_member_set_summary';


--
-- TOC entry 5405 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.first_set_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.first_set_date IS 'Field first_set_date on mv_member_set_summary';


--
-- TOC entry 5406 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.last_set_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.last_set_date IS 'Field last_set_date on mv_member_set_summary';


--
-- TOC entry 5407 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.most_active_month; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.most_active_month IS 'Field most_active_month on mv_member_set_summary';


--
-- TOC entry 5408 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN mv_member_set_summary.most_active_month_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_member_set_summary.most_active_month_count IS 'Count of most active months';


--
-- TOC entry 297 (class 1259 OID 403644)
-- Name: mv_tune_set_transitions; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_set_transitions AS
 WITH ordered AS (
         SELECT s.tuneset,
            s.settingorder,
            s.tune_id AS source_tune,
            lead(s.tune_id) OVER (PARTITION BY s.tuneset ORDER BY s.settingorder) AS target_tune
           FROM thesession.session_set_items_raw s
        ), counts AS (
         SELECT ordered.source_tune,
            ordered.target_tune,
            (count(*))::integer AS transition_count
           FROM ordered
          WHERE ((ordered.source_tune IS NOT NULL) AND (ordered.target_tune IS NOT NULL) AND (ordered.source_tune <> ordered.target_tune))
          GROUP BY ordered.source_tune, ordered.target_tune
        ), totals AS (
         SELECT counts.source_tune,
            (sum(counts.transition_count))::integer AS source_total
           FROM counts
          GROUP BY counts.source_tune
        ), ranked AS (
         SELECT c.source_tune,
            c.target_tune,
            c.transition_count,
            t.source_total,
            round((((c.transition_count)::numeric * 100.0) / (NULLIF(t.source_total, 0))::numeric), 2) AS transition_pct,
            row_number() OVER (PARTITION BY c.source_tune ORDER BY c.transition_count DESC, c.target_tune) AS transition_rank
           FROM (counts c
             JOIN totals t ON ((t.source_tune = c.source_tune)))
        )
 SELECT source_tune,
    target_tune,
    transition_count,
    source_total,
    transition_pct,
    transition_rank
   FROM ranked
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_set_transitions OWNER TO folkguitar;

--
-- TOC entry 5409 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.source_tune; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.source_tune IS 'ID of the source tune';


--
-- TOC entry 5410 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.target_tune; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.target_tune IS 'ID of the target tune';


--
-- TOC entry 5411 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.transition_count IS 'Number of times sets transition from source_tune to target_tune';


--
-- TOC entry 5412 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.source_total; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.source_total IS 'Total transitions originating from the source_tune';


--
-- TOC entry 5413 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.transition_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.transition_pct IS 'Percentage of source_tune transitions that go to target_tune';


--
-- TOC entry 5414 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN mv_tune_set_transitions.transition_rank; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_set_transitions.transition_rank IS 'Rank of this transition among all transitions from source_tune';


--
-- TOC entry 321 (class 1259 OID 605364)
-- Name: mv_mode_set_transitions; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_mode_set_transitions AS
 WITH base AS (
         SELECT sm.mode AS source_mode_label,
            tm.mode AS target_mode_label,
            t.transition_count
           FROM ((thesession.mv_tune_set_transitions t
             JOIN thesession.mv_tune_meta sm ON ((sm.tune_id = t.source_tune)))
             JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = t.target_tune)))
          WHERE ((sm.mode IS NOT NULL) AND (btrim(sm.mode) <> ''::text) AND (tm.mode IS NOT NULL) AND (btrim(tm.mode) <> ''::text))
        ), counts AS (
         SELECT base.source_mode_label,
                CASE
                    WHEN (base.source_mode_label ~~* '%major'::text) THEN 'major'::text
                    WHEN (base.source_mode_label ~~* '%minor'::text) THEN 'minor'::text
                    WHEN (base.source_mode_label ~~* '%dorian'::text) THEN 'dorian'::text
                    WHEN (base.source_mode_label ~~* '%mixolydian'::text) THEN 'mixolydian'::text
                    ELSE 'other'::text
                END AS source_mode_family,
            base.target_mode_label,
                CASE
                    WHEN (base.target_mode_label ~~* '%major'::text) THEN 'major'::text
                    WHEN (base.target_mode_label ~~* '%minor'::text) THEN 'minor'::text
                    WHEN (base.target_mode_label ~~* '%dorian'::text) THEN 'dorian'::text
                    WHEN (base.target_mode_label ~~* '%mixolydian'::text) THEN 'mixolydian'::text
                    ELSE 'other'::text
                END AS target_mode_family,
            (sum(base.transition_count))::integer AS transition_count
           FROM base
          GROUP BY base.source_mode_label,
                CASE
                    WHEN (base.source_mode_label ~~* '%major'::text) THEN 'major'::text
                    WHEN (base.source_mode_label ~~* '%minor'::text) THEN 'minor'::text
                    WHEN (base.source_mode_label ~~* '%dorian'::text) THEN 'dorian'::text
                    WHEN (base.source_mode_label ~~* '%mixolydian'::text) THEN 'mixolydian'::text
                    ELSE 'other'::text
                END, base.target_mode_label,
                CASE
                    WHEN (base.target_mode_label ~~* '%major'::text) THEN 'major'::text
                    WHEN (base.target_mode_label ~~* '%minor'::text) THEN 'minor'::text
                    WHEN (base.target_mode_label ~~* '%dorian'::text) THEN 'dorian'::text
                    WHEN (base.target_mode_label ~~* '%mixolydian'::text) THEN 'mixolydian'::text
                    ELSE 'other'::text
                END
        ), totals AS (
         SELECT counts.source_mode_label,
            (sum(counts.transition_count))::integer AS source_total
           FROM counts
          GROUP BY counts.source_mode_label
        ), ranked AS (
         SELECT c.source_mode_label,
            c.source_mode_family,
            c.target_mode_label,
            c.target_mode_family,
            c.transition_count,
            t.source_total,
            round((((c.transition_count)::numeric * 100.0) / (NULLIF(t.source_total, 0))::numeric), 2) AS transition_pct,
            row_number() OVER (PARTITION BY c.source_mode_label ORDER BY c.transition_count DESC, c.target_mode_label) AS transition_rank
           FROM (counts c
             JOIN totals t ON ((t.source_mode_label = c.source_mode_label)))
        )
 SELECT source_mode_label,
    source_mode_family,
    target_mode_label,
    target_mode_family,
    transition_count,
    source_total,
    transition_pct,
    transition_rank
   FROM ranked
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_mode_set_transitions OWNER TO folkguitar;

--
-- TOC entry 5415 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.source_mode_label; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.source_mode_label IS 'Field source_mode_label on mv_mode_set_transitions';


--
-- TOC entry 5416 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.source_mode_family; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.source_mode_family IS 'Field source_mode_family on mv_mode_set_transitions';


--
-- TOC entry 5417 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.target_mode_label; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.target_mode_label IS 'Field target_mode_label on mv_mode_set_transitions';


--
-- TOC entry 5418 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.target_mode_family; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.target_mode_family IS 'Field target_mode_family on mv_mode_set_transitions';


--
-- TOC entry 5419 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.transition_count IS 'Number of times sets transition from source_mode to target_mode';


--
-- TOC entry 5420 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.source_total; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.source_total IS 'Total transitions originating from the source_mode';


--
-- TOC entry 5421 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.transition_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.transition_pct IS 'Percentage of source_mode transitions that go to target_mode';


--
-- TOC entry 5422 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN mv_mode_set_transitions.transition_rank; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_mode_set_transitions.transition_rank IS 'Rank of this mode transition among all transitions from source_mode';


--
-- TOC entry 331 (class 1259 OID 800337)
-- Name: mv_recording_set_search; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_recording_set_search AS
 WITH recording_rows AS (
         SELECT sr.id AS recording_id,
            sr.artist_id,
            sr.artist_name,
            sr.recording,
            sr.track,
            sr.tune_number,
            sr.tune_id,
            sr.tune_name AS recording_tune_name
           FROM thesession.session_recording sr
          WHERE (sr.tune_id IS NOT NULL)
        ), most_popular_setting AS (
         SELECT DISTINCT ON (str.tune_id) str.tune_id,
            str.setting_id,
            str.name,
            str.type,
            str.meter,
            str.mode,
            str.incipit,
            str.preview_abc,
            str.preview_abc_part_b,
            str.preview_part_b_confidence
           FROM (thesession.session_tunes_raw str
             LEFT JOIN thesession.session_tune_popularity_raw pop ON ((pop.tune_id = str.tune_id)))
          WHERE (str.tune_id IS NOT NULL)
          ORDER BY str.tune_id, COALESCE(pop.tunebooks, 0) DESC, str.date DESC NULLS LAST, str.setting_id
        ), enriched_rows AS (
         SELECT rr.recording_id,
            rr.artist_id,
            rr.artist_name,
            rr.recording,
            rr.track,
            rr.tune_number,
            rr.tune_id,
            rr.recording_tune_name,
            mps.setting_id,
            COALESCE(tm.primary_name, mps.name, rr.recording_tune_name) AS canonical_tune_name,
            COALESCE(tm.type, mps.type) AS type,
            COALESCE(tm.meter, mps.meter) AS meter,
            COALESCE(tm.mode, mps.mode) AS mode,
            COALESCE(tm.incipit, mps.incipit) AS incipit,
                CASE
                    WHEN ((tm.primary_name IS NOT NULL) AND (rr.recording_tune_name IS NOT NULL) AND (lower(tm.primary_name) <> lower(rr.recording_tune_name))) THEN true
                    ELSE false
                END AS has_alias_resolution
           FROM ((recording_rows rr
             LEFT JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = rr.tune_id)))
             LEFT JOIN most_popular_setting mps ON ((mps.tune_id = rr.tune_id)))
        ), rollup AS (
         SELECT er.recording_id,
            min(er.artist_id) AS artist_id,
            min(er.artist_name) AS artist_name,
            min(er.recording) AS recording,
            er.track,
            count(*) AS tune_count,
            count(DISTINCT er.tune_id) AS distinct_tune_count,
            array_agg(er.tune_id ORDER BY er.tune_number) AS tune_ids,
            array_agg(er.setting_id ORDER BY er.tune_number) AS setting_ids,
            array_agg(DISTINCT er.tune_id ORDER BY er.tune_id) AS distinct_tune_ids,
            array_agg(er.canonical_tune_name ORDER BY er.tune_number) AS canonical_tune_names,
            array_agg(er.recording_tune_name ORDER BY er.tune_number) AS recording_tune_names,
            array_agg(er.type ORDER BY er.tune_number) AS types,
            array_agg(er.meter ORDER BY er.tune_number) AS meters,
            array_agg(er.mode ORDER BY er.tune_number) AS modes,
            array_agg(er.incipit ORDER BY er.tune_number) AS incipits,
            bool_or(er.has_alias_resolution) AS has_alias_resolution,
            (count(*) > count(DISTINCT er.tune_id)) AS has_repeated_tunes,
            array_to_string(array_agg((er.tune_id)::text ORDER BY er.tune_number), '>'::text) AS ordered_signature,
            array_to_string(ARRAY( SELECT DISTINCT (x.x)::text AS x
                   FROM unnest(array_agg(er.tune_id)) x(x)
                  ORDER BY (x.x)::text), '|'::text) AS unordered_signature
           FROM enriched_rows er
          GROUP BY er.recording_id, er.track
        )
 SELECT recording_id,
    artist_id,
    artist_name,
    recording,
    track,
    tune_count,
    distinct_tune_count,
    tune_ids,
    setting_ids,
    distinct_tune_ids,
    canonical_tune_names,
    recording_tune_names,
    types,
    meters,
    modes,
    incipits,
    has_alias_resolution,
    has_repeated_tunes,
    ordered_signature,
    unordered_signature
   FROM rollup
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_recording_set_search OWNER TO folkguitar;

--
-- TOC entry 5423 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.recording_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.recording_id IS 'ID of the recording';


--
-- TOC entry 5424 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.artist_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.artist_id IS 'Canonical ID of the recording artist';


--
-- TOC entry 5425 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5426 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.recording; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.recording IS 'Field recording on mv_recording_set_search';


--
-- TOC entry 5427 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.track IS 'Track number on the album or recording';


--
-- TOC entry 5428 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.tune_count IS 'Count of tunes';


--
-- TOC entry 5429 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.distinct_tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.distinct_tune_count IS 'Count of distinct tunes';


--
-- TOC entry 5430 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.tune_ids; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.tune_ids IS 'Array of tune IDs played on the track';


--
-- TOC entry 5431 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.setting_ids; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.setting_ids IS 'Field setting_ids on mv_recording_set_search';


--
-- TOC entry 5432 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.distinct_tune_ids; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.distinct_tune_ids IS 'Field distinct_tune_ids on mv_recording_set_search';


--
-- TOC entry 5433 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.canonical_tune_names; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.canonical_tune_names IS 'Field canonical_tune_names on mv_recording_set_search';


--
-- TOC entry 5434 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.recording_tune_names; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.recording_tune_names IS 'Field recording_tune_names on mv_recording_set_search';


--
-- TOC entry 5435 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.types; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.types IS 'Field types on mv_recording_set_search';


--
-- TOC entry 5436 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.meters; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.meters IS 'Field meters on mv_recording_set_search';


--
-- TOC entry 5437 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.modes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.modes IS 'Field modes on mv_recording_set_search';


--
-- TOC entry 5438 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.incipits; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.incipits IS 'Field incipits on mv_recording_set_search';


--
-- TOC entry 5439 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.has_alias_resolution; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.has_alias_resolution IS 'Field has_alias_resolution on mv_recording_set_search';


--
-- TOC entry 5440 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.has_repeated_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.has_repeated_tunes IS 'Field has_repeated_tunes on mv_recording_set_search';


--
-- TOC entry 5441 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.ordered_signature; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.ordered_signature IS 'Field ordered_signature on mv_recording_set_search';


--
-- TOC entry 5442 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN mv_recording_set_search.unordered_signature; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_recording_set_search.unordered_signature IS 'Field unordered_signature on mv_recording_set_search';


--
-- TOC entry 301 (class 1259 OID 446880)
-- Name: mv_set_signatures; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_set_signatures AS
 WITH set_rows AS (
         SELECT r_1.tuneset,
            r_1.member_id,
            r_1.username,
            r_1.date,
            count(*) AS tune_count,
            string_agg(COALESCE((i.tune_id)::text, 'null'::text), '>'::text ORDER BY i.settingorder, i.setting_id) AS signature,
            jsonb_agg(i.tune_id ORDER BY i.settingorder, i.setting_id) AS tune_ids_json,
            jsonb_agg(i.name ORDER BY i.settingorder, i.setting_id) AS tune_names_json,
            jsonb_agg(i.type ORDER BY i.settingorder, i.setting_id) AS type_sequence_json,
            jsonb_agg(i.mode ORDER BY i.settingorder, i.setting_id) AS mode_sequence_json
           FROM (thesession.session_sets_raw r_1
             JOIN thesession.session_set_items_raw i ON ((i.tuneset = r_1.tuneset)))
          GROUP BY r_1.tuneset, r_1.member_id, r_1.username, r_1.date
        ), signature_rollup AS (
         SELECT set_rows.signature,
            min(set_rows.tune_count) AS tune_count,
            count(*) AS set_count,
            count(DISTINCT set_rows.member_id) AS distinct_users,
            min(set_rows.date) AS first_seen,
            max(set_rows.date) AS last_seen
           FROM set_rows
          GROUP BY set_rows.signature
        ), signature_sample AS (
         SELECT DISTINCT ON (set_rows.signature) set_rows.signature,
            set_rows.tune_ids_json,
            set_rows.tune_names_json,
            set_rows.type_sequence_json,
            set_rows.mode_sequence_json
           FROM set_rows
          ORDER BY set_rows.signature, set_rows.tuneset
        )
 SELECT r.signature,
    r.tune_count,
    r.set_count,
    r.distinct_users,
    r.first_seen,
    r.last_seen,
    ((s.tune_ids_json ->> 0))::bigint AS first_tune_id,
    (s.tune_names_json ->> 0) AS first_tune_name,
    ((s.tune_ids_json ->> (jsonb_array_length(s.tune_ids_json) - 1)))::bigint AS last_tune_id,
    (s.tune_names_json ->> (jsonb_array_length(s.tune_names_json) - 1)) AS last_tune_name,
    s.tune_ids_json,
    s.tune_names_json,
    s.type_sequence_json,
    s.mode_sequence_json,
    (r.set_count > 1) AS is_repeated,
    array_to_string(ARRAY( SELECT jsonb_array_elements_text(s.tune_names_json) AS jsonb_array_elements_text), ' → '::text) AS signature_label
   FROM (signature_rollup r
     JOIN signature_sample s ON ((s.signature = r.signature)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_set_signatures OWNER TO folkguitar;

--
-- TOC entry 5443 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.signature; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.signature IS 'Field signature on mv_set_signatures';


--
-- TOC entry 5444 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.tune_count IS 'Count of tunes';


--
-- TOC entry 5445 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.set_count IS 'Count of sets';


--
-- TOC entry 5446 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.distinct_users; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.distinct_users IS 'Field distinct_users on mv_set_signatures';


--
-- TOC entry 5447 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.first_seen; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.first_seen IS 'Field first_seen on mv_set_signatures';


--
-- TOC entry 5448 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.last_seen; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.last_seen IS 'Field last_seen on mv_set_signatures';


--
-- TOC entry 5449 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.first_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.first_tune_id IS 'ID of the first_tune';


--
-- TOC entry 5450 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.first_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.first_tune_name IS 'Name of the first_tune';


--
-- TOC entry 5451 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.last_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.last_tune_id IS 'ID of the last_tune';


--
-- TOC entry 5452 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.last_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.last_tune_name IS 'Name of the last_tune';


--
-- TOC entry 5453 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.tune_ids_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.tune_ids_json IS 'Field tune_ids_json on mv_set_signatures';


--
-- TOC entry 5454 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.tune_names_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.tune_names_json IS 'Field tune_names_json on mv_set_signatures';


--
-- TOC entry 5455 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.type_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.type_sequence_json IS 'Field type_sequence_json on mv_set_signatures';


--
-- TOC entry 5456 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.mode_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.mode_sequence_json IS 'Field mode_sequence_json on mv_set_signatures';


--
-- TOC entry 5457 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.is_repeated; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.is_repeated IS 'Field is_repeated on mv_set_signatures';


--
-- TOC entry 5458 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN mv_set_signatures.signature_label; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_signatures.signature_label IS 'Field signature_label on mv_set_signatures';


--
-- TOC entry 322 (class 1259 OID 605385)
-- Name: mv_set_search; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_set_search AS
 WITH item_rows AS (
         SELECT s.tuneset,
            s.member_id,
            s.username,
            s.date,
            s.imported_at,
            i.settingorder,
            i.setting_id,
            i.tune_id,
            COALESCE(tm.primary_name, i.name) AS tune_name,
            COALESCE(tm.type, i.type) AS type,
            COALESCE(tm.meter, i.meter) AS meter,
            COALESCE(tm.mode, i.mode) AS mode,
            tm.incipit
           FROM ((thesession.session_sets_raw s
             JOIN thesession.session_set_items_raw i ON ((i.tuneset = s.tuneset)))
             LEFT JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = i.tune_id)))
        ), set_rollup AS (
         SELECT ir.tuneset,
            min(ir.member_id) AS member_id,
            min(ir.username) AS username,
            min(ir.date) AS date,
            min(ir.imported_at) AS imported_at,
            count(*) AS tune_count,
            string_agg(COALESCE((ir.tune_id)::text, 'null'::text), '>'::text ORDER BY ir.settingorder, ir.setting_id) AS signature,
            jsonb_agg(ir.setting_id ORDER BY ir.settingorder, ir.setting_id) AS setting_ids_json,
            jsonb_agg(ir.tune_id ORDER BY ir.settingorder, ir.setting_id) AS tune_ids_json,
            jsonb_agg(ir.tune_name ORDER BY ir.settingorder, ir.setting_id) AS tune_names_json,
            jsonb_agg(ir.type ORDER BY ir.settingorder, ir.setting_id) AS type_sequence_json,
            jsonb_agg(ir.mode ORDER BY ir.settingorder, ir.setting_id) AS mode_sequence_json,
            jsonb_agg(ir.meter ORDER BY ir.settingorder, ir.setting_id) AS meter_sequence_json,
            jsonb_agg(ir.incipit ORDER BY ir.settingorder, ir.setting_id) AS incipit_sequence_json,
            min(ir.settingorder) AS first_settingorder,
            max(ir.settingorder) AS last_settingorder
           FROM item_rows ir
          GROUP BY ir.tuneset
        ), contains_rollup AS (
         SELECT ir.tuneset,
            jsonb_agg(DISTINCT ir.tune_id ORDER BY ir.tune_id) FILTER (WHERE (ir.tune_id IS NOT NULL)) AS contains_tune_ids_json,
            jsonb_agg(DISTINCT ir.type ORDER BY ir.type) FILTER (WHERE ((ir.type IS NOT NULL) AND (btrim(ir.type) <> ''::text))) AS contains_types_json,
            jsonb_agg(DISTINCT ir.mode ORDER BY ir.mode) FILTER (WHERE ((ir.mode IS NOT NULL) AND (btrim(ir.mode) <> ''::text))) AS contains_modes_json,
            jsonb_agg(DISTINCT ir.meter ORDER BY ir.meter) FILTER (WHERE ((ir.meter IS NOT NULL) AND (btrim(ir.meter) <> ''::text))) AS contains_meters_json
           FROM item_rows ir
          GROUP BY ir.tuneset
        ), first_last AS (
         SELECT ir.tuneset,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.tune_id
                    ELSE NULL::bigint
                END) AS first_tune_id,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.tune_name
                    ELSE NULL::text
                END) AS first_tune_name,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.type
                    ELSE NULL::text
                END) AS first_type,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.mode
                    ELSE NULL::text
                END) AS first_mode,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.meter
                    ELSE NULL::text
                END) AS first_meter,
            max(
                CASE
                    WHEN (ir.rn_first = 1) THEN ir.incipit
                    ELSE NULL::text
                END) AS first_incipit,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.tune_id
                    ELSE NULL::bigint
                END) AS last_tune_id,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.tune_name
                    ELSE NULL::text
                END) AS last_tune_name,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.type
                    ELSE NULL::text
                END) AS last_type,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.mode
                    ELSE NULL::text
                END) AS last_mode,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.meter
                    ELSE NULL::text
                END) AS last_meter,
            max(
                CASE
                    WHEN (ir.rn_last = 1) THEN ir.incipit
                    ELSE NULL::text
                END) AS last_incipit
           FROM ( SELECT ir_1.tuneset,
                    ir_1.member_id,
                    ir_1.username,
                    ir_1.date,
                    ir_1.imported_at,
                    ir_1.settingorder,
                    ir_1.setting_id,
                    ir_1.tune_id,
                    ir_1.tune_name,
                    ir_1.type,
                    ir_1.meter,
                    ir_1.mode,
                    ir_1.incipit,
                    row_number() OVER (PARTITION BY ir_1.tuneset ORDER BY ir_1.settingorder, ir_1.setting_id) AS rn_first,
                    row_number() OVER (PARTITION BY ir_1.tuneset ORDER BY ir_1.settingorder DESC, ir_1.setting_id DESC) AS rn_last
                   FROM item_rows ir_1) ir
          GROUP BY ir.tuneset
        )
 SELECT sr.tuneset,
    sr.member_id,
    sr.username,
    sr.date,
    sr.imported_at,
    sr.tune_count,
    sr.signature,
    array_to_string(ARRAY( SELECT jsonb_array_elements_text(sr.tune_names_json) AS jsonb_array_elements_text), ' → '::text) AS signature_label,
    fl.first_tune_id,
    fl.first_tune_name,
    fl.first_type,
    fl.first_mode,
    fl.first_meter,
    fl.first_incipit,
    fl.last_tune_id,
    fl.last_tune_name,
    fl.last_type,
    fl.last_mode,
    fl.last_meter,
    fl.last_incipit,
    sr.setting_ids_json,
    sr.tune_ids_json,
    sr.tune_names_json,
    sr.type_sequence_json,
    sr.mode_sequence_json,
    sr.meter_sequence_json,
    sr.incipit_sequence_json,
    cr.contains_tune_ids_json,
    cr.contains_types_json,
    cr.contains_modes_json,
    cr.contains_meters_json,
    COALESCE(ms.is_repeated, false) AS is_repeated,
    COALESCE(ms.set_count, (1)::bigint) AS signature_set_count,
    COALESCE(ms.distinct_users, (1)::bigint) AS signature_distinct_users,
    ms.first_seen AS signature_first_seen,
    ms.last_seen AS signature_last_seen
   FROM (((set_rollup sr
     JOIN first_last fl ON ((fl.tuneset = sr.tuneset)))
     LEFT JOIN contains_rollup cr ON ((cr.tuneset = sr.tuneset)))
     LEFT JOIN thesession.mv_set_signatures ms ON ((ms.signature = sr.signature)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_set_search OWNER TO folkguitar;

--
-- TOC entry 5459 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.tuneset; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.tuneset IS 'Field tuneset on mv_set_search';


--
-- TOC entry 5460 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.member_id IS 'ID of the member who submitted the set';


--
-- TOC entry 5461 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.username; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.username IS 'Field username on mv_set_search';


--
-- TOC entry 5462 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.date IS 'Field date on mv_set_search';


--
-- TOC entry 5463 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.imported_at; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.imported_at IS 'Field imported_at on mv_set_search';


--
-- TOC entry 5464 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.tune_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.tune_count IS 'Count of tunes';


--
-- TOC entry 5465 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature IS 'Field signature on mv_set_search';


--
-- TOC entry 5466 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature_label; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature_label IS 'Field signature_label on mv_set_search';


--
-- TOC entry 5467 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_tune_id IS 'ID of the first_tune';


--
-- TOC entry 5468 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_tune_name IS 'Name of the first_tune';


--
-- TOC entry 5469 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_type IS 'Field first_type on mv_set_search';


--
-- TOC entry 5470 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_mode IS 'Field first_mode on mv_set_search';


--
-- TOC entry 5471 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_meter IS 'Field first_meter on mv_set_search';


--
-- TOC entry 5472 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.first_incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.first_incipit IS 'Field first_incipit on mv_set_search';


--
-- TOC entry 5473 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_tune_id IS 'ID of the last_tune';


--
-- TOC entry 5474 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_tune_name IS 'Name of the last_tune';


--
-- TOC entry 5475 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_type IS 'Field last_type on mv_set_search';


--
-- TOC entry 5476 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_mode IS 'Field last_mode on mv_set_search';


--
-- TOC entry 5477 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_meter IS 'Field last_meter on mv_set_search';


--
-- TOC entry 5478 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.last_incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.last_incipit IS 'Field last_incipit on mv_set_search';


--
-- TOC entry 5479 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.setting_ids_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.setting_ids_json IS 'Field setting_ids_json on mv_set_search';


--
-- TOC entry 5480 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.tune_ids_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.tune_ids_json IS 'Field tune_ids_json on mv_set_search';


--
-- TOC entry 5481 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.tune_names_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.tune_names_json IS 'Field tune_names_json on mv_set_search';


--
-- TOC entry 5482 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.type_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.type_sequence_json IS 'Field type_sequence_json on mv_set_search';


--
-- TOC entry 5483 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.mode_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.mode_sequence_json IS 'Field mode_sequence_json on mv_set_search';


--
-- TOC entry 5484 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.meter_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.meter_sequence_json IS 'Field meter_sequence_json on mv_set_search';


--
-- TOC entry 5485 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.incipit_sequence_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.incipit_sequence_json IS 'Field incipit_sequence_json on mv_set_search';


--
-- TOC entry 5486 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.contains_tune_ids_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.contains_tune_ids_json IS 'Field contains_tune_ids_json on mv_set_search';


--
-- TOC entry 5487 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.contains_types_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.contains_types_json IS 'Field contains_types_json on mv_set_search';


--
-- TOC entry 5488 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.contains_modes_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.contains_modes_json IS 'Field contains_modes_json on mv_set_search';


--
-- TOC entry 5489 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.contains_meters_json; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.contains_meters_json IS 'Field contains_meters_json on mv_set_search';


--
-- TOC entry 5490 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.is_repeated; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.is_repeated IS 'Field is_repeated on mv_set_search';


--
-- TOC entry 5491 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature_set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature_set_count IS 'Count of signature sets';


--
-- TOC entry 5492 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature_distinct_users; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature_distinct_users IS 'Field signature_distinct_users on mv_set_search';


--
-- TOC entry 5493 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature_first_seen; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature_first_seen IS 'Field signature_first_seen on mv_set_search';


--
-- TOC entry 5494 (class 0 OID 0)
-- Dependencies: 322
-- Name: COLUMN mv_set_search.signature_last_seen; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_set_search.signature_last_seen IS 'Field signature_last_seen on mv_set_search';


--
-- TOC entry 328 (class 1259 OID 796945)
-- Name: mv_setting_bookmarkers; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_setting_bookmarkers AS
 WITH owner_members AS (
         SELECT session_member.name,
            min(session_member.id) AS id
           FROM thesession.session_member
          WHERE (session_member.name IS NOT NULL)
          GROUP BY session_member.name
        )
 SELECT owner_member.id AS setting_owner_member_id,
    owner.username AS setting_owner_name,
    b.member_id AS bookmarker_member_id,
    bm.name AS bookmarker_name,
    b.setting_id,
    b.tune_id,
    b.tune_name,
    b.bookmarked_at,
    owner.incipit,
    owner.date AS setting_date,
    tm.primary_name,
    tm.type,
    tm.mode,
    tm.meter,
    tm.star_rating,
    tm.tunebooks,
    tm.has_recording_albums,
    (tm.star_rating IS NOT NULL) AS popularity_known
   FROM ((((thesession.session_member_bookmark_setting b
     JOIN thesession.session_tunes_raw owner ON ((owner.setting_id = b.setting_id)))
     LEFT JOIN owner_members owner_member ON ((owner_member.name = owner.username)))
     LEFT JOIN thesession.session_member bm ON ((bm.id = b.member_id)))
     LEFT JOIN thesession.mv_tune_meta tm ON ((tm.tune_id = b.tune_id)))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_setting_bookmarkers OWNER TO folkguitar;

--
-- TOC entry 5495 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.setting_owner_member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.setting_owner_member_id IS 'ID of the setting_owner_member';


--
-- TOC entry 5496 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.setting_owner_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.setting_owner_name IS 'Name of the setting_owner';


--
-- TOC entry 5497 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.bookmarker_member_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.bookmarker_member_id IS 'ID of the bookmarker_member';


--
-- TOC entry 5498 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.bookmarker_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.bookmarker_name IS 'Name of the bookmarker';


--
-- TOC entry 5499 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.setting_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.setting_id IS 'Canonical ID of the specific tune setting/transcription';


--
-- TOC entry 5500 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5501 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.tune_name IS 'Name of the tune';


--
-- TOC entry 5502 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.bookmarked_at; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.bookmarked_at IS 'Date/time the bookmark was saved';


--
-- TOC entry 5503 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5504 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.setting_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.setting_date IS 'Field setting_date on mv_setting_bookmarkers';


--
-- TOC entry 5505 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5506 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5507 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5508 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5509 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.star_rating; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.star_rating IS 'Average star rating of the tune on TheSession.org';


--
-- TOC entry 5510 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.tunebooks; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.tunebooks IS 'Field tunebooks on mv_setting_bookmarkers';


--
-- TOC entry 5511 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.has_recording_albums; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.has_recording_albums IS 'Boolean flag indicating if the tune has been recorded on commercial albums';


--
-- TOC entry 5512 (class 0 OID 0)
-- Dependencies: 328
-- Name: COLUMN mv_setting_bookmarkers.popularity_known; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_setting_bookmarkers.popularity_known IS 'Field popularity_known on mv_setting_bookmarkers';


--
-- TOC entry 347 (class 1259 OID 919581)
-- Name: mv_static_recording_pages; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_static_recording_pages AS
 WITH base AS (
         SELECT DISTINCT ON (sr.id) sr.id AS recording_id,
            sr.recording,
            sr.artist_name,
            thesession.slugify_unaccent(((sr.recording || ' recorded by '::text) || sr.artist_name)) AS base_slug
           FROM thesession.session_recording sr
          WHERE ((sr.id IS NOT NULL) AND (sr.recording IS NOT NULL) AND (btrim(sr.recording) <> ''::text) AND (sr.artist_name IS NOT NULL) AND (btrim(sr.artist_name) <> ''::text))
          ORDER BY sr.id, sr.track, sr.tune_number
        ), deduped AS (
         SELECT b.recording_id,
            b.recording,
            b.artist_name,
            b.base_slug,
            count(*) OVER (PARTITION BY b.base_slug) AS slug_count
           FROM base b
        )
 SELECT recording_id,
    recording,
    artist_name,
        CASE
            WHEN (slug_count = 1) THEN base_slug
            ELSE ((base_slug || '-'::text) || (recording_id)::text)
        END AS slug,
    (('/recordings/'::text ||
        CASE
            WHEN (slug_count = 1) THEN base_slug
            ELSE ((base_slug || '-'::text) || (recording_id)::text)
        END) || '/'::text) AS path,
    (('https://thesession.tradtuneexplorer.com/recordings/'::text ||
        CASE
            WHEN (slug_count = 1) THEN base_slug
            ELSE ((base_slug || '-'::text) || (recording_id)::text)
        END) || '/'::text) AS canonical_url
   FROM deduped
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_static_recording_pages OWNER TO folkguitar;

--
-- TOC entry 5513 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.recording_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.recording_id IS 'ID of the recording';


--
-- TOC entry 5514 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.recording; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.recording IS 'Field recording on mv_static_recording_pages';


--
-- TOC entry 5515 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5516 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.slug; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.slug IS 'Field slug on mv_static_recording_pages';


--
-- TOC entry 5517 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.path; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.path IS 'Field path on mv_static_recording_pages';


--
-- TOC entry 5518 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN mv_static_recording_pages.canonical_url; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_static_recording_pages.canonical_url IS 'Field canonical_url on mv_static_recording_pages';


--
-- TOC entry 330 (class 1259 OID 799907)
-- Name: mv_transition_artist_overlap; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_transition_artist_overlap AS
 WITH artist_transitions AS (
         SELECT DISTINCT mv_artist_transition_features.artist_name,
            mv_artist_transition_features.source_tune_id,
            mv_artist_transition_features.source_tune_name,
            mv_artist_transition_features.target_tune_id,
            mv_artist_transition_features.target_tune_name,
            mv_artist_transition_features.global_transition_count
           FROM thesession.mv_artist_transition_features
          WHERE (mv_artist_transition_features.global_transition_count >= 2)
        ), overlap_rows AS (
         SELECT a.artist_name AS artist_a,
            b.artist_name AS artist_b,
            a.source_tune_id,
            a.source_tune_name,
            a.target_tune_id,
            a.target_tune_name,
            a.global_transition_count
           FROM (artist_transitions a
             JOIN artist_transitions b ON (((b.source_tune_id = a.source_tune_id) AND (b.target_tune_id = a.target_tune_id) AND (b.artist_name > a.artist_name))))
        )
 SELECT DISTINCT ON (artist_a, artist_b, source_tune_id, target_tune_id) artist_a,
    artist_b,
    source_tune_id,
    source_tune_name,
    target_tune_id,
    target_tune_name,
    global_transition_count
   FROM overlap_rows
  ORDER BY artist_a, artist_b, source_tune_id, target_tune_id, source_tune_name, target_tune_name
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_transition_artist_overlap OWNER TO folkguitar;

--
-- TOC entry 5519 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.artist_a; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.artist_a IS 'Field artist_a on mv_transition_artist_overlap';


--
-- TOC entry 5520 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.artist_b; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.artist_b IS 'Field artist_b on mv_transition_artist_overlap';


--
-- TOC entry 5521 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.source_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.source_tune_id IS 'ID of the source_tune';


--
-- TOC entry 5522 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.source_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.source_tune_name IS 'Name of the source_tune';


--
-- TOC entry 5523 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.target_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.target_tune_id IS 'ID of the target_tune';


--
-- TOC entry 5524 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.target_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.target_tune_name IS 'Name of the target_tune';


--
-- TOC entry 5525 (class 0 OID 0)
-- Dependencies: 330
-- Name: COLUMN mv_transition_artist_overlap.global_transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_transition_artist_overlap.global_transition_count IS 'Count of global transitions';


--
-- TOC entry 295 (class 1259 OID 401906)
-- Name: mv_tune_transitions; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_transitions AS
 WITH transitions AS (
         SELECT r1.tune_id AS source_tune,
            r2.tune_id AS target_tune,
            count(*) AS transition_count
           FROM (thesession.session_recording r1
             JOIN thesession.session_recording r2 ON (((r1.id = r2.id) AND (r1.track = r2.track) AND (r2.tune_number = (r1.tune_number + 1)))))
          WHERE ((r1.tune_id IS NOT NULL) AND (r2.tune_id IS NOT NULL) AND (r1.tune_id <> r2.tune_id))
          GROUP BY r1.tune_id, r2.tune_id
        ), source_totals AS (
         SELECT transitions.source_tune,
            sum(transitions.transition_count) AS source_total
           FROM transitions
          GROUP BY transitions.source_tune
        ), ranked AS (
         SELECT t.source_tune,
            t.target_tune,
            t.transition_count,
            st.source_total,
            round(((100.0 * (t.transition_count)::numeric) / NULLIF(st.source_total, (0)::numeric)), 2) AS transition_pct,
            row_number() OVER (PARTITION BY t.source_tune ORDER BY t.transition_count DESC, t.target_tune) AS transition_rank
           FROM (transitions t
             JOIN source_totals st ON ((st.source_tune = t.source_tune)))
        )
 SELECT source_tune,
    target_tune,
    transition_count,
    source_total,
    transition_pct,
    transition_rank
   FROM ranked
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_transitions OWNER TO folkguitar;

--
-- TOC entry 5526 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.source_tune; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.source_tune IS 'ID of the source tune in the transition';


--
-- TOC entry 5527 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.target_tune; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.target_tune IS 'ID of the target tune in the transition';


--
-- TOC entry 5528 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.transition_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.transition_count IS 'Number of times this transition occurs in commercial recordings';


--
-- TOC entry 5529 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.source_total; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.source_total IS 'Total transitions originating from the source_tune across all recordings';


--
-- TOC entry 5530 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.transition_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.transition_pct IS 'Percentage of source_tune transitions that go to target_tune';


--
-- TOC entry 5531 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN mv_tune_transitions.transition_rank; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transitions.transition_rank IS 'Rank of this transition among all transitions from source_tune';


--
-- TOC entry 356 (class 1259 OID 1117015)
-- Name: mv_tune_analytics; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_analytics AS
 WITH tune_base AS (
         SELECT tm.tune_id,
            tm.primary_name,
            thesession.slugify_unaccent(tm.primary_name) AS slug,
            tm.aliases,
            tm.type,
            tm.meter,
            tm.mode,
            tm.incipit,
            COALESCE(tm.tunebooks, 0) AS tunebook_count,
            COALESCE(tm.star_rating, 0) AS star_rating,
            COALESCE(tm.has_recording_albums, false) AS has_recording_albums
           FROM thesession.mv_tune_meta tm
          WHERE (tm.tune_id IS NOT NULL)
        ), settings AS (
         SELECT session_tunes_raw.tune_id,
            count(*) AS settings_count,
            count(DISTINCT session_tunes_raw.username) FILTER (WHERE ((session_tunes_raw.username IS NOT NULL) AND (btrim(session_tunes_raw.username) <> ''::text))) AS setting_user_count,
            count(DISTINCT session_tunes_raw.mode) FILTER (WHERE ((session_tunes_raw.mode IS NOT NULL) AND (btrim(session_tunes_raw.mode) <> ''::text))) AS distinct_modes_count,
            count(DISTINCT session_tunes_raw.meter) FILTER (WHERE ((session_tunes_raw.meter IS NOT NULL) AND (btrim(session_tunes_raw.meter) <> ''::text))) AS distinct_meters_count,
            (min(session_tunes_raw.date))::date AS first_setting_date,
            (max(session_tunes_raw.date))::date AS latest_setting_date
           FROM thesession.session_tunes_raw
          WHERE (session_tunes_raw.tune_id IS NOT NULL)
          GROUP BY session_tunes_raw.tune_id
        ), recordings AS (
         SELECT session_recording.tune_id,
            count(*) AS recording_occurrence_count,
            count(DISTINCT session_recording.id) AS recording_count,
            count(DISTINCT session_recording.recording) FILTER (WHERE ((session_recording.recording IS NOT NULL) AND (btrim(session_recording.recording) <> ''::text))) AS recording_title_count,
            count(DISTINCT COALESCE(('id:'::text || (session_recording.artist_id)::text), ('name:'::text || lower(btrim(session_recording.artist_name))))) FILTER (WHERE ((session_recording.artist_name IS NOT NULL) AND (btrim(session_recording.artist_name) <> ''::text) AND (session_recording.artist_name <> 'Various Artists'::text))) AS recording_artist_count,
            count(DISTINCT session_recording.track) AS recording_track_count
           FROM thesession.session_recording
          WHERE (session_recording.tune_id IS NOT NULL)
          GROUP BY session_recording.tune_id
        ), recording_albums AS (
         SELECT sr.tune_id,
            count(DISTINCT sra.recording_id) AS recording_album_count,
            count(DISTINCT sra.provider) AS recording_album_provider_count
           FROM (thesession.session_recording sr
             JOIN thesession.session_recording_album sra ON ((sra.recording_id = sr.id)))
          WHERE (sr.tune_id IS NOT NULL)
          GROUP BY sr.tune_id
        ), bookmarks AS (
         SELECT session_member_bookmark_setting.tune_id,
            count(*) AS bookmark_count,
            count(DISTINCT session_member_bookmark_setting.member_id) AS bookmark_member_count,
            (min(session_member_bookmark_setting.bookmarked_at))::date AS first_bookmarked_date,
            (max(session_member_bookmark_setting.bookmarked_at))::date AS latest_bookmarked_date
           FROM thesession.session_member_bookmark_setting
          WHERE (session_member_bookmark_setting.tune_id IS NOT NULL)
          GROUP BY session_member_bookmark_setting.tune_id
        ), member_tunebooks AS (
         SELECT session_member_tunebook.tune_id,
            count(*) AS member_tunebook_rows,
            count(DISTINCT session_member_tunebook.member_id) AS member_tunebook_count,
            (min(session_member_tunebook.added_at))::date AS first_tunebook_added_date,
            (max(session_member_tunebook.added_at))::date AS latest_tunebook_added_date
           FROM thesession.session_member_tunebook
          WHERE (session_member_tunebook.tune_id IS NOT NULL)
          GROUP BY session_member_tunebook.tune_id
        ), set_usage AS (
         SELECT i.tune_id,
            count(*) AS set_appearance_count,
            count(DISTINCT i.tuneset) AS distinct_set_count,
            count(DISTINCT s.member_id) FILTER (WHERE (s.member_id IS NOT NULL)) AS set_member_count,
            round(avg(i.settingorder), 2) AS average_set_position,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((i.settingorder)::double precision)))::numeric AS median_set_position,
            count(*) FILTER (WHERE (i.settingorder = 1)) AS set_starter_count,
            count(*) FILTER (WHERE (i.settingorder > 1)) AS non_starter_set_count,
            (min(s.date))::date AS first_seen_in_sets,
            (max(s.date))::date AS latest_seen_in_sets
           FROM (thesession.session_set_items_raw i
             JOIN thesession.session_sets_raw s ON ((s.tuneset = i.tuneset)))
          WHERE (i.tune_id IS NOT NULL)
          GROUP BY i.tune_id
        ), collections AS (
         SELECT tune_collection_item.tune_id,
            count(*) AS collection_appearance_count,
            count(DISTINCT tune_collection_item.collection_id) AS collection_count
           FROM thesession.tune_collection_item
          WHERE (tune_collection_item.tune_id IS NOT NULL)
          GROUP BY tune_collection_item.tune_id
        ), recording_transition_out AS (
         SELECT mv_tune_transitions.source_tune AS tune_id,
            (sum(mv_tune_transitions.transition_count))::bigint AS recording_transition_out_count,
            count(*) AS recording_distinct_next_tunes
           FROM thesession.mv_tune_transitions
          GROUP BY mv_tune_transitions.source_tune
        ), recording_transition_in AS (
         SELECT mv_tune_transitions.target_tune AS tune_id,
            (sum(mv_tune_transitions.transition_count))::bigint AS recording_transition_in_count,
            count(*) AS recording_distinct_previous_tunes
           FROM thesession.mv_tune_transitions
          GROUP BY mv_tune_transitions.target_tune
        ), top_recording_next AS (
         SELECT x.tune_id,
            x.top_recording_next_tune_id,
            x.top_recording_next_count,
            x.top_recording_next_pct,
            x.rn
           FROM ( SELECT mv_tune_transitions.source_tune AS tune_id,
                    mv_tune_transitions.target_tune AS top_recording_next_tune_id,
                    mv_tune_transitions.transition_count AS top_recording_next_count,
                    mv_tune_transitions.transition_pct AS top_recording_next_pct,
                    row_number() OVER (PARTITION BY mv_tune_transitions.source_tune ORDER BY mv_tune_transitions.transition_count DESC, mv_tune_transitions.target_tune) AS rn
                   FROM thesession.mv_tune_transitions) x
          WHERE (x.rn = 1)
        ), top_recording_previous AS (
         SELECT x.tune_id,
            x.top_recording_previous_tune_id,
            x.top_recording_previous_count,
            x.top_recording_previous_pct,
            x.rn
           FROM ( SELECT mv_tune_transitions.target_tune AS tune_id,
                    mv_tune_transitions.source_tune AS top_recording_previous_tune_id,
                    mv_tune_transitions.transition_count AS top_recording_previous_count,
                    mv_tune_transitions.transition_pct AS top_recording_previous_pct,
                    row_number() OVER (PARTITION BY mv_tune_transitions.target_tune ORDER BY mv_tune_transitions.transition_count DESC, mv_tune_transitions.source_tune) AS rn
                   FROM thesession.mv_tune_transitions) x
          WHERE (x.rn = 1)
        ), set_transition_out AS (
         SELECT mv_tune_set_transitions.source_tune AS tune_id,
            sum(mv_tune_set_transitions.transition_count) AS set_transition_out_count,
            count(*) AS set_distinct_next_tunes
           FROM thesession.mv_tune_set_transitions
          GROUP BY mv_tune_set_transitions.source_tune
        ), set_transition_in AS (
         SELECT mv_tune_set_transitions.target_tune AS tune_id,
            sum(mv_tune_set_transitions.transition_count) AS set_transition_in_count,
            count(*) AS set_distinct_previous_tunes
           FROM thesession.mv_tune_set_transitions
          GROUP BY mv_tune_set_transitions.target_tune
        ), top_set_next AS (
         SELECT x.tune_id,
            x.top_set_next_tune_id,
            x.top_set_next_count,
            x.top_set_next_pct,
            x.rn
           FROM ( SELECT mv_tune_set_transitions.source_tune AS tune_id,
                    mv_tune_set_transitions.target_tune AS top_set_next_tune_id,
                    mv_tune_set_transitions.transition_count AS top_set_next_count,
                    mv_tune_set_transitions.transition_pct AS top_set_next_pct,
                    row_number() OVER (PARTITION BY mv_tune_set_transitions.source_tune ORDER BY mv_tune_set_transitions.transition_count DESC, mv_tune_set_transitions.target_tune) AS rn
                   FROM thesession.mv_tune_set_transitions) x
          WHERE (x.rn = 1)
        ), top_set_previous AS (
         SELECT x.tune_id,
            x.top_set_previous_tune_id,
            x.top_set_previous_count,
            x.top_set_previous_pct,
            x.rn
           FROM ( SELECT mv_tune_set_transitions.target_tune AS tune_id,
                    mv_tune_set_transitions.source_tune AS top_set_previous_tune_id,
                    mv_tune_set_transitions.transition_count AS top_set_previous_count,
                    mv_tune_set_transitions.transition_pct AS top_set_previous_pct,
                    row_number() OVER (PARTITION BY mv_tune_set_transitions.target_tune ORDER BY mv_tune_set_transitions.transition_count DESC, mv_tune_set_transitions.source_tune) AS rn
                   FROM thesession.mv_tune_set_transitions) x
          WHERE (x.rn = 1)
        ), country_signal AS (
         SELECT mv_country_tune_signal_popularity.tune_id,
            count(DISTINCT mv_country_tune_signal_popularity.country_code) AS country_count,
            max(mv_country_tune_signal_popularity.weighted_country_score) AS max_country_score,
            max(mv_country_tune_signal_popularity.lift_score) AS max_country_lift
           FROM thesession.mv_country_tune_signal_popularity
          WHERE (mv_country_tune_signal_popularity.tune_id IS NOT NULL)
          GROUP BY mv_country_tune_signal_popularity.tune_id
        ), combined AS (
         SELECT b.tune_id,
            b.primary_name,
            b.slug,
            b.aliases,
            b.type,
            b.meter,
            b.mode,
            b.incipit,
            b.tunebook_count,
            b.star_rating,
            b.has_recording_albums,
            COALESCE(st.settings_count, (0)::bigint) AS settings_count,
            COALESCE(st.setting_user_count, (0)::bigint) AS setting_user_count,
            COALESCE(st.distinct_modes_count, (0)::bigint) AS distinct_modes_count,
            COALESCE(st.distinct_meters_count, (0)::bigint) AS distinct_meters_count,
            st.first_setting_date,
            st.latest_setting_date,
            COALESCE(r.recording_occurrence_count, (0)::bigint) AS recording_occurrence_count,
            COALESCE(r.recording_count, (0)::bigint) AS recording_count,
            COALESCE(r.recording_title_count, (0)::bigint) AS recording_title_count,
            COALESCE(r.recording_artist_count, (0)::bigint) AS recording_artist_count,
            COALESCE(r.recording_track_count, (0)::bigint) AS recording_track_count,
            COALESCE(ra.recording_album_count, (0)::bigint) AS recording_album_count,
            COALESCE(ra.recording_album_provider_count, (0)::bigint) AS recording_album_provider_count,
            COALESCE(bm.bookmark_count, (0)::bigint) AS bookmark_count,
            COALESCE(bm.bookmark_member_count, (0)::bigint) AS bookmark_member_count,
            bm.first_bookmarked_date,
            bm.latest_bookmarked_date,
            COALESCE(mt.member_tunebook_rows, (0)::bigint) AS member_tunebook_rows,
            COALESCE(mt.member_tunebook_count, (0)::bigint) AS member_tunebook_count,
            mt.first_tunebook_added_date,
            mt.latest_tunebook_added_date,
            COALESCE(su.set_appearance_count, (0)::bigint) AS set_appearance_count,
            COALESCE(su.distinct_set_count, (0)::bigint) AS distinct_set_count,
            COALESCE(su.set_member_count, (0)::bigint) AS set_member_count,
            su.average_set_position,
            su.median_set_position,
            COALESCE(su.set_starter_count, (0)::bigint) AS set_starter_count,
            COALESCE(su.non_starter_set_count, (0)::bigint) AS non_starter_set_count,
            su.first_seen_in_sets,
            su.latest_seen_in_sets,
            COALESCE(col.collection_appearance_count, (0)::bigint) AS collection_appearance_count,
            COALESCE(col.collection_count, (0)::bigint) AS collection_count,
            COALESCE(rto.recording_transition_out_count, (0)::bigint) AS recording_transition_out_count,
            COALESCE(rti.recording_transition_in_count, (0)::bigint) AS recording_transition_in_count,
            COALESCE(rto.recording_distinct_next_tunes, (0)::bigint) AS recording_distinct_next_tunes,
            COALESCE(rti.recording_distinct_previous_tunes, (0)::bigint) AS recording_distinct_previous_tunes,
            trn.top_recording_next_tune_id,
            trn.top_recording_next_count,
            trn.top_recording_next_pct,
            trp.top_recording_previous_tune_id,
            trp.top_recording_previous_count,
            trp.top_recording_previous_pct,
            COALESCE(sto.set_transition_out_count, (0)::bigint) AS set_transition_out_count,
            COALESCE(sti.set_transition_in_count, (0)::bigint) AS set_transition_in_count,
            COALESCE(sto.set_distinct_next_tunes, (0)::bigint) AS set_distinct_next_tunes,
            COALESCE(sti.set_distinct_previous_tunes, (0)::bigint) AS set_distinct_previous_tunes,
            tsn.top_set_next_tune_id,
            tsn.top_set_next_count,
            tsn.top_set_next_pct,
            tsp.top_set_previous_tune_id,
            tsp.top_set_previous_count,
            tsp.top_set_previous_pct,
            COALESCE(cs.country_count, (0)::bigint) AS country_count,
            COALESCE(cs.max_country_score, (0)::numeric) AS max_country_score,
            COALESCE(cs.max_country_lift, (0)::numeric) AS max_country_lift
           FROM ((((((((((((((((tune_base b
             LEFT JOIN settings st ON ((st.tune_id = b.tune_id)))
             LEFT JOIN recordings r ON ((r.tune_id = b.tune_id)))
             LEFT JOIN recording_albums ra ON ((ra.tune_id = b.tune_id)))
             LEFT JOIN bookmarks bm ON ((bm.tune_id = b.tune_id)))
             LEFT JOIN member_tunebooks mt ON ((mt.tune_id = b.tune_id)))
             LEFT JOIN set_usage su ON ((su.tune_id = b.tune_id)))
             LEFT JOIN collections col ON ((col.tune_id = b.tune_id)))
             LEFT JOIN recording_transition_out rto ON ((rto.tune_id = b.tune_id)))
             LEFT JOIN recording_transition_in rti ON ((rti.tune_id = b.tune_id)))
             LEFT JOIN top_recording_next trn ON ((trn.tune_id = b.tune_id)))
             LEFT JOIN top_recording_previous trp ON ((trp.tune_id = b.tune_id)))
             LEFT JOIN set_transition_out sto ON ((sto.tune_id = b.tune_id)))
             LEFT JOIN set_transition_in sti ON ((sti.tune_id = b.tune_id)))
             LEFT JOIN top_set_next tsn ON ((tsn.tune_id = b.tune_id)))
             LEFT JOIN top_set_previous tsp ON ((tsp.tune_id = b.tune_id)))
             LEFT JOIN country_signal cs ON ((cs.tune_id = b.tune_id)))
        ), percentiles AS (
         SELECT c.tune_id,
            c.primary_name,
            c.slug,
            c.aliases,
            c.type,
            c.meter,
            c.mode,
            c.incipit,
            c.tunebook_count,
            c.star_rating,
            c.has_recording_albums,
            c.settings_count,
            c.setting_user_count,
            c.distinct_modes_count,
            c.distinct_meters_count,
            c.first_setting_date,
            c.latest_setting_date,
            c.recording_occurrence_count,
            c.recording_count,
            c.recording_title_count,
            c.recording_artist_count,
            c.recording_track_count,
            c.recording_album_count,
            c.recording_album_provider_count,
            c.bookmark_count,
            c.bookmark_member_count,
            c.first_bookmarked_date,
            c.latest_bookmarked_date,
            c.member_tunebook_rows,
            c.member_tunebook_count,
            c.first_tunebook_added_date,
            c.latest_tunebook_added_date,
            c.set_appearance_count,
            c.distinct_set_count,
            c.set_member_count,
            c.average_set_position,
            c.median_set_position,
            c.set_starter_count,
            c.non_starter_set_count,
            c.first_seen_in_sets,
            c.latest_seen_in_sets,
            c.collection_appearance_count,
            c.collection_count,
            c.recording_transition_out_count,
            c.recording_transition_in_count,
            c.recording_distinct_next_tunes,
            c.recording_distinct_previous_tunes,
            c.top_recording_next_tune_id,
            c.top_recording_next_count,
            c.top_recording_next_pct,
            c.top_recording_previous_tune_id,
            c.top_recording_previous_count,
            c.top_recording_previous_pct,
            c.set_transition_out_count,
            c.set_transition_in_count,
            c.set_distinct_next_tunes,
            c.set_distinct_previous_tunes,
            c.top_set_next_tune_id,
            c.top_set_next_count,
            c.top_set_next_pct,
            c.top_set_previous_tune_id,
            c.top_set_previous_count,
            c.top_set_previous_pct,
            c.country_count,
            c.max_country_score,
            c.max_country_lift,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.recording_count))::numeric AS recording_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.recording_artist_count))::numeric AS artist_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.recording_album_count))::numeric AS album_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.settings_count))::numeric AS settings_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.bookmark_count))::numeric AS bookmark_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.set_appearance_count))::numeric AS set_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.tunebook_count))::numeric AS tunebook_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY (c.recording_transition_out_count + c.recording_transition_in_count)))::numeric AS recording_transition_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY (c.set_transition_out_count + c.set_transition_in_count)))::numeric AS set_transition_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.country_count))::numeric AS country_percentile_by_type,
            rank() OVER (PARTITION BY c.type ORDER BY c.recording_count DESC, c.primary_name) AS recording_rank_by_type,
            rank() OVER (PARTITION BY c.type ORDER BY c.set_appearance_count DESC, c.primary_name) AS set_rank_by_type,
            rank() OVER (PARTITION BY c.type ORDER BY c.bookmark_count DESC, c.primary_name) AS bookmark_rank_by_type,
            rank() OVER (PARTITION BY c.type ORDER BY c.tunebook_count DESC, c.primary_name) AS tunebook_rank_by_type
           FROM combined c
        ), signals AS (
         SELECT p.tune_id,
            p.primary_name,
            p.slug,
            p.aliases,
            p.type,
            p.meter,
            p.mode,
            p.incipit,
            p.tunebook_count,
            p.star_rating,
            p.has_recording_albums,
            p.settings_count,
            p.setting_user_count,
            p.distinct_modes_count,
            p.distinct_meters_count,
            p.first_setting_date,
            p.latest_setting_date,
            p.recording_occurrence_count,
            p.recording_count,
            p.recording_title_count,
            p.recording_artist_count,
            p.recording_track_count,
            p.recording_album_count,
            p.recording_album_provider_count,
            p.bookmark_count,
            p.bookmark_member_count,
            p.first_bookmarked_date,
            p.latest_bookmarked_date,
            p.member_tunebook_rows,
            p.member_tunebook_count,
            p.first_tunebook_added_date,
            p.latest_tunebook_added_date,
            p.set_appearance_count,
            p.distinct_set_count,
            p.set_member_count,
            p.average_set_position,
            p.median_set_position,
            p.set_starter_count,
            p.non_starter_set_count,
            p.first_seen_in_sets,
            p.latest_seen_in_sets,
            p.collection_appearance_count,
            p.collection_count,
            p.recording_transition_out_count,
            p.recording_transition_in_count,
            p.recording_distinct_next_tunes,
            p.recording_distinct_previous_tunes,
            p.top_recording_next_tune_id,
            p.top_recording_next_count,
            p.top_recording_next_pct,
            p.top_recording_previous_tune_id,
            p.top_recording_previous_count,
            p.top_recording_previous_pct,
            p.set_transition_out_count,
            p.set_transition_in_count,
            p.set_distinct_next_tunes,
            p.set_distinct_previous_tunes,
            p.top_set_next_tune_id,
            p.top_set_next_count,
            p.top_set_next_pct,
            p.top_set_previous_tune_id,
            p.top_set_previous_count,
            p.top_set_previous_pct,
            p.country_count,
            p.max_country_score,
            p.max_country_lift,
            p.recording_percentile_by_type,
            p.artist_percentile_by_type,
            p.album_percentile_by_type,
            p.settings_percentile_by_type,
            p.bookmark_percentile_by_type,
            p.set_percentile_by_type,
            p.tunebook_percentile_by_type,
            p.recording_transition_percentile_by_type,
            p.set_transition_percentile_by_type,
            p.country_percentile_by_type,
            p.recording_rank_by_type,
            p.set_rank_by_type,
            p.bookmark_rank_by_type,
            p.tunebook_rank_by_type,
            ((p.tunebook_count = 0) AND (p.bookmark_count = 0) AND (p.set_appearance_count = 0)) AS is_zero_exposure,
                CASE
                    WHEN ((p.recording_count >= 20) AND (p.recording_artist_count >= 15)) THEN 'strong'::text
                    WHEN ((p.recording_count >= 10) AND (p.recording_artist_count >= 8)) THEN 'medium'::text
                    WHEN (p.recording_count >= 5) THEN 'weak'::text
                    ELSE 'thin'::text
                END AS evidence_level,
            round((((((0.40 * p.recording_percentile_by_type) + (0.30 * p.artist_percentile_by_type)) + (0.15 * p.album_percentile_by_type)) + (0.15 * p.settings_percentile_by_type)) * (100)::numeric), 2) AS quality_signal,
            round(((((0.40 * p.set_percentile_by_type) + (0.30 * p.bookmark_percentile_by_type)) + (0.30 * p.tunebook_percentile_by_type)) * (100)::numeric), 2) AS exposure_signal,
            round((((((0.45 * p.set_percentile_by_type) + (0.25 * p.tunebook_percentile_by_type)) + (0.15 * p.bookmark_percentile_by_type)) + (0.15 * p.set_transition_percentile_by_type)) * (100)::numeric), 2) AS session_signal,
            round(((((0.45 * p.recording_percentile_by_type) + (0.35 * p.artist_percentile_by_type)) + (0.20 * p.recording_transition_percentile_by_type)) * (100)::numeric), 2) AS recording_signal,
            round(((((((0.30 * p.recording_percentile_by_type) + (0.25 * p.artist_percentile_by_type)) + (0.20 * p.set_transition_percentile_by_type)) + (0.15 * p.tunebook_percentile_by_type)) + (0.10 * p.country_percentile_by_type)) * (100)::numeric), 2) AS influence_signal,
            round(((1.0 - (((0.40 * p.set_percentile_by_type) + (0.30 * p.bookmark_percentile_by_type)) + (0.30 * p.tunebook_percentile_by_type))) * (100)::numeric), 2) AS obscurity_signal
           FROM percentiles p
        ), scores AS (
         SELECT s.tune_id,
            s.primary_name,
            s.slug,
            s.aliases,
            s.type,
            s.meter,
            s.mode,
            s.incipit,
            s.tunebook_count,
            s.star_rating,
            s.has_recording_albums,
            s.settings_count,
            s.setting_user_count,
            s.distinct_modes_count,
            s.distinct_meters_count,
            s.first_setting_date,
            s.latest_setting_date,
            s.recording_occurrence_count,
            s.recording_count,
            s.recording_title_count,
            s.recording_artist_count,
            s.recording_track_count,
            s.recording_album_count,
            s.recording_album_provider_count,
            s.bookmark_count,
            s.bookmark_member_count,
            s.first_bookmarked_date,
            s.latest_bookmarked_date,
            s.member_tunebook_rows,
            s.member_tunebook_count,
            s.first_tunebook_added_date,
            s.latest_tunebook_added_date,
            s.set_appearance_count,
            s.distinct_set_count,
            s.set_member_count,
            s.average_set_position,
            s.median_set_position,
            s.set_starter_count,
            s.non_starter_set_count,
            s.first_seen_in_sets,
            s.latest_seen_in_sets,
            s.collection_appearance_count,
            s.collection_count,
            s.recording_transition_out_count,
            s.recording_transition_in_count,
            s.recording_distinct_next_tunes,
            s.recording_distinct_previous_tunes,
            s.top_recording_next_tune_id,
            s.top_recording_next_count,
            s.top_recording_next_pct,
            s.top_recording_previous_tune_id,
            s.top_recording_previous_count,
            s.top_recording_previous_pct,
            s.set_transition_out_count,
            s.set_transition_in_count,
            s.set_distinct_next_tunes,
            s.set_distinct_previous_tunes,
            s.top_set_next_tune_id,
            s.top_set_next_count,
            s.top_set_next_pct,
            s.top_set_previous_tune_id,
            s.top_set_previous_count,
            s.top_set_previous_pct,
            s.country_count,
            s.max_country_score,
            s.max_country_lift,
            s.recording_percentile_by_type,
            s.artist_percentile_by_type,
            s.album_percentile_by_type,
            s.settings_percentile_by_type,
            s.bookmark_percentile_by_type,
            s.set_percentile_by_type,
            s.tunebook_percentile_by_type,
            s.recording_transition_percentile_by_type,
            s.set_transition_percentile_by_type,
            s.country_percentile_by_type,
            s.recording_rank_by_type,
            s.set_rank_by_type,
            s.bookmark_rank_by_type,
            s.tunebook_rank_by_type,
            s.is_zero_exposure,
            s.evidence_level,
            s.quality_signal,
            s.exposure_signal,
            s.session_signal,
            s.recording_signal,
            s.influence_signal,
            s.obscurity_signal,
            round(((s.quality_signal - s.exposure_signal) - (
                CASE
                    WHEN s.is_zero_exposure THEN 8
                    ELSE 0
                END)::numeric), 2) AS hidden_gem_score,
            round(((s.quality_signal - (s.bookmark_percentile_by_type * (40)::numeric)) - (s.tunebook_percentile_by_type * (25)::numeric)), 2) AS forgotten_classic_score,
            round((s.session_signal + (s.settings_percentile_by_type * (20)::numeric)), 2) AS beginner_score,
            round((s.influence_signal + (s.recording_signal * 0.25)), 2) AS influential_score
           FROM signals s
        )
 SELECT tune_id,
    primary_name,
    slug,
    aliases,
    type,
    meter,
    mode,
    incipit,
    tunebook_count,
    star_rating,
    has_recording_albums,
    settings_count,
    setting_user_count,
    distinct_modes_count,
    distinct_meters_count,
    first_setting_date,
    latest_setting_date,
    recording_occurrence_count,
    recording_count,
    recording_title_count,
    recording_artist_count,
    recording_track_count,
    recording_album_count,
    recording_album_provider_count,
    bookmark_count,
    bookmark_member_count,
    first_bookmarked_date,
    latest_bookmarked_date,
    member_tunebook_rows,
    member_tunebook_count,
    first_tunebook_added_date,
    latest_tunebook_added_date,
    set_appearance_count,
    distinct_set_count,
    set_member_count,
    average_set_position,
    median_set_position,
    set_starter_count,
    non_starter_set_count,
    first_seen_in_sets,
    latest_seen_in_sets,
    collection_appearance_count,
    collection_count,
    recording_transition_out_count,
    recording_transition_in_count,
    recording_distinct_next_tunes,
    recording_distinct_previous_tunes,
    top_recording_next_tune_id,
    top_recording_next_count,
    top_recording_next_pct,
    top_recording_previous_tune_id,
    top_recording_previous_count,
    top_recording_previous_pct,
    set_transition_out_count,
    set_transition_in_count,
    set_distinct_next_tunes,
    set_distinct_previous_tunes,
    top_set_next_tune_id,
    top_set_next_count,
    top_set_next_pct,
    top_set_previous_tune_id,
    top_set_previous_count,
    top_set_previous_pct,
    country_count,
    max_country_score,
    max_country_lift,
    recording_percentile_by_type,
    artist_percentile_by_type,
    album_percentile_by_type,
    settings_percentile_by_type,
    bookmark_percentile_by_type,
    set_percentile_by_type,
    tunebook_percentile_by_type,
    recording_transition_percentile_by_type,
    set_transition_percentile_by_type,
    country_percentile_by_type,
    recording_rank_by_type,
    set_rank_by_type,
    bookmark_rank_by_type,
    tunebook_rank_by_type,
    is_zero_exposure,
    evidence_level,
    quality_signal,
    exposure_signal,
    session_signal,
    recording_signal,
    influence_signal,
    obscurity_signal,
    hidden_gem_score,
    forgotten_classic_score,
    beginner_score,
    influential_score,
        CASE
            WHEN ((hidden_gem_score >= (50)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text])) AND (NOT is_zero_exposure)) THEN 'safe_hidden_gem'::text
            WHEN ((hidden_gem_score >= (50)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text])) AND is_zero_exposure) THEN 'deep_cut'::text
            WHEN ((hidden_gem_score >= (30)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text]))) THEN 'possible_hidden_gem'::text
            WHEN ((evidence_level = 'weak'::text) AND (hidden_gem_score >= (40)::numeric)) THEN 'needs_review'::text
            ELSE 'not_candidate'::text
        END AS hidden_gem_tier,
        CASE
            WHEN ((recording_count >= 10) AND (recording_artist_count >= 5) AND (set_percentile_by_type <= 0.35) AND (bookmark_percentile_by_type <= 0.35)) THEN 'recorded_but_underplayed'::text
            WHEN ((recording_artist_count >= 8) AND (tunebook_percentile_by_type <= 0.40)) THEN 'many_artists_low_tunebooks'::text
            WHEN ((settings_count >= 10) AND (recording_count >= 5) AND (set_appearance_count <= 10)) THEN 'many_settings_low_session_use'::text
            ELSE 'general_candidate'::text
        END AS hidden_gem_reason_code,
    now() AS analytics_updated_at
   FROM scores
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_analytics OWNER TO folkguitar;

--
-- TOC entry 5532 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.tune_id IS 'ID of the traditional tune';


--
-- TOC entry 5533 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5534 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.slug; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.slug IS 'Field slug on mv_tune_analytics';


--
-- TOC entry 5535 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.aliases; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.aliases IS 'Array of alternative names or titles for the tune';


--
-- TOC entry 5536 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5537 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5538 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5539 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5540 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.tunebook_count IS 'Number of member tunebooks containing this tune';


--
-- TOC entry 5541 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.star_rating; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.star_rating IS 'Average star rating of the tune on TheSession.org';


--
-- TOC entry 5542 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.has_recording_albums; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.has_recording_albums IS 'Boolean flag indicating if the tune has been recorded on commercial albums';


--
-- TOC entry 5543 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.settings_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.settings_count IS 'Total settings/transcriptions of this tune on TheSession.org';


--
-- TOC entry 5544 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.setting_user_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.setting_user_count IS 'Count of setting users';


--
-- TOC entry 5545 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.distinct_modes_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.distinct_modes_count IS 'Number of distinct modes/keys this tune is played in';


--
-- TOC entry 5546 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.distinct_meters_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.distinct_meters_count IS 'Count of distinct meterss';


--
-- TOC entry 5547 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.first_setting_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.first_setting_date IS 'Field first_setting_date on mv_tune_analytics';


--
-- TOC entry 5548 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.latest_setting_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.latest_setting_date IS 'Field latest_setting_date on mv_tune_analytics';


--
-- TOC entry 5549 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_occurrence_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_occurrence_count IS 'Count of recording occurrences';


--
-- TOC entry 5550 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_count IS 'Total number of commercial recordings featuring this tune';


--
-- TOC entry 5551 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_title_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_title_count IS 'Count of recording titles';


--
-- TOC entry 5552 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_artist_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_artist_count IS 'Number of unique recording artists who have recorded this tune';


--
-- TOC entry 5553 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_track_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_track_count IS 'Count of recording tracks';


--
-- TOC entry 5554 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_album_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_album_count IS 'Number of unique albums featuring this tune';


--
-- TOC entry 5555 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_album_provider_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_album_provider_count IS 'Count of recording album providers';


--
-- TOC entry 5556 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.bookmark_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.bookmark_count IS 'Number of members who have bookmarked/saved this tune';


--
-- TOC entry 5557 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.bookmark_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.bookmark_member_count IS 'Count of bookmark members';


--
-- TOC entry 5558 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.first_bookmarked_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.first_bookmarked_date IS 'Field first_bookmarked_date on mv_tune_analytics';


--
-- TOC entry 5559 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.latest_bookmarked_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.latest_bookmarked_date IS 'Field latest_bookmarked_date on mv_tune_analytics';


--
-- TOC entry 5560 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.member_tunebook_rows; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.member_tunebook_rows IS 'Field member_tunebook_rows on mv_tune_analytics';


--
-- TOC entry 5561 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.member_tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.member_tunebook_count IS 'Count of member tunebooks';


--
-- TOC entry 5562 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.first_tunebook_added_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.first_tunebook_added_date IS 'Field first_tunebook_added_date on mv_tune_analytics';


--
-- TOC entry 5563 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.latest_tunebook_added_date; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.latest_tunebook_added_date IS 'Field latest_tunebook_added_date on mv_tune_analytics';


--
-- TOC entry 5564 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_appearance_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_appearance_count IS 'Number of session sets/sequences that include this tune';


--
-- TOC entry 5565 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.distinct_set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.distinct_set_count IS 'Number of distinct sets containing this tune';


--
-- TOC entry 5566 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_member_count IS 'Number of unique session players who have contributed sets containing this tune';


--
-- TOC entry 5567 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.average_set_position; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.average_set_position IS 'Average position of the tune within sets (e.g., 1st, 2nd, 3rd)';


--
-- TOC entry 5568 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.median_set_position; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.median_set_position IS 'Field median_set_position on mv_tune_analytics';


--
-- TOC entry 5569 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_starter_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_starter_count IS 'Count of set starters';


--
-- TOC entry 5570 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.non_starter_set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.non_starter_set_count IS 'Count of non starter sets';


--
-- TOC entry 5571 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.first_seen_in_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.first_seen_in_sets IS 'Earliest date this tune appeared in a session set';


--
-- TOC entry 5572 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.latest_seen_in_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.latest_seen_in_sets IS 'Most recent date this tune appeared in a session set';


--
-- TOC entry 5573 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.collection_appearance_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.collection_appearance_count IS 'Count of collection appearances';


--
-- TOC entry 5574 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.collection_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.collection_count IS 'Count of collections';


--
-- TOC entry 5575 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_transition_out_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_transition_out_count IS 'Count of recording transition outs';


--
-- TOC entry 5576 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_transition_in_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_transition_in_count IS 'Count of recording transition ins';


--
-- TOC entry 5577 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_distinct_next_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_distinct_next_tunes IS 'Field recording_distinct_next_tunes on mv_tune_analytics';


--
-- TOC entry 5578 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_distinct_previous_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_distinct_previous_tunes IS 'Field recording_distinct_previous_tunes on mv_tune_analytics';


--
-- TOC entry 5579 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_next_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_next_tune_id IS 'ID of the top_recording_next_tune';


--
-- TOC entry 5580 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_next_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_next_count IS 'Count of top recording nexts';


--
-- TOC entry 5581 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_next_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_next_pct IS 'Field top_recording_next_pct on mv_tune_analytics';


--
-- TOC entry 5582 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_previous_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_previous_tune_id IS 'ID of the top_recording_previous_tune';


--
-- TOC entry 5583 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_previous_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_previous_count IS 'Count of top recording previouss';


--
-- TOC entry 5584 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_recording_previous_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_recording_previous_pct IS 'Field top_recording_previous_pct on mv_tune_analytics';


--
-- TOC entry 5585 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_transition_out_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_transition_out_count IS 'Count of set transition outs';


--
-- TOC entry 5586 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_transition_in_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_transition_in_count IS 'Count of set transition ins';


--
-- TOC entry 5587 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_distinct_next_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_distinct_next_tunes IS 'Field set_distinct_next_tunes on mv_tune_analytics';


--
-- TOC entry 5588 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_distinct_previous_tunes; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_distinct_previous_tunes IS 'Field set_distinct_previous_tunes on mv_tune_analytics';


--
-- TOC entry 5589 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_next_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_next_tune_id IS 'ID of the top_set_next_tune';


--
-- TOC entry 5590 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_next_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_next_count IS 'Count of top set nexts';


--
-- TOC entry 5591 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_next_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_next_pct IS 'Field top_set_next_pct on mv_tune_analytics';


--
-- TOC entry 5592 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_previous_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_previous_tune_id IS 'ID of the top_set_previous_tune';


--
-- TOC entry 5593 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_previous_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_previous_count IS 'Count of top set previouss';


--
-- TOC entry 5594 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.top_set_previous_pct; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.top_set_previous_pct IS 'Field top_set_previous_pct on mv_tune_analytics';


--
-- TOC entry 5595 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.country_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.country_count IS 'Count of countrys';


--
-- TOC entry 5596 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.max_country_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.max_country_score IS 'Field max_country_score on mv_tune_analytics';


--
-- TOC entry 5597 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.max_country_lift; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.max_country_lift IS 'Field max_country_lift on mv_tune_analytics';


--
-- TOC entry 5598 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_percentile_by_type IS 'Field recording_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5599 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.artist_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.artist_percentile_by_type IS 'Field artist_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5600 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.album_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.album_percentile_by_type IS 'Field album_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5601 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.settings_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.settings_percentile_by_type IS 'Field settings_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5602 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.bookmark_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.bookmark_percentile_by_type IS 'Field bookmark_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5603 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_percentile_by_type IS 'Field set_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5604 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.tunebook_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.tunebook_percentile_by_type IS 'Field tunebook_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5605 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_transition_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_transition_percentile_by_type IS 'Field recording_transition_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5606 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_transition_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_transition_percentile_by_type IS 'Field set_transition_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5607 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.country_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.country_percentile_by_type IS 'Field country_percentile_by_type on mv_tune_analytics';


--
-- TOC entry 5608 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_rank_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_rank_by_type IS 'Field recording_rank_by_type on mv_tune_analytics';


--
-- TOC entry 5609 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.set_rank_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.set_rank_by_type IS 'Field set_rank_by_type on mv_tune_analytics';


--
-- TOC entry 5610 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.bookmark_rank_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.bookmark_rank_by_type IS 'Field bookmark_rank_by_type on mv_tune_analytics';


--
-- TOC entry 5611 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.tunebook_rank_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.tunebook_rank_by_type IS 'Field tunebook_rank_by_type on mv_tune_analytics';


--
-- TOC entry 5612 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.is_zero_exposure; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.is_zero_exposure IS 'Field is_zero_exposure on mv_tune_analytics';


--
-- TOC entry 5613 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.evidence_level; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.evidence_level IS 'Confidence rating of the data quality (e.g., strong, medium, weak)';


--
-- TOC entry 5614 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.quality_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.quality_signal IS 'Calculated quality rating score based on recordings, settings, and ratings';


--
-- TOC entry 5615 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.exposure_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.exposure_signal IS 'Calculated exposure/popularity rating score in sessions and tunebooks';


--
-- TOC entry 5616 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.session_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.session_signal IS 'Field session_signal on mv_tune_analytics';


--
-- TOC entry 5617 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.recording_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.recording_signal IS 'Field recording_signal on mv_tune_analytics';


--
-- TOC entry 5618 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.influence_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.influence_signal IS 'Field influence_signal on mv_tune_analytics';


--
-- TOC entry 5619 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.obscurity_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.obscurity_signal IS 'Field obscurity_signal on mv_tune_analytics';


--
-- TOC entry 5620 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.hidden_gem_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.hidden_gem_score IS 'Field hidden_gem_score on mv_tune_analytics';


--
-- TOC entry 5621 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.forgotten_classic_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.forgotten_classic_score IS 'Field forgotten_classic_score on mv_tune_analytics';


--
-- TOC entry 5622 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.beginner_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.beginner_score IS 'Field beginner_score on mv_tune_analytics';


--
-- TOC entry 5623 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.influential_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.influential_score IS 'Field influential_score on mv_tune_analytics';


--
-- TOC entry 5624 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.hidden_gem_tier; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.hidden_gem_tier IS 'Field hidden_gem_tier on mv_tune_analytics';


--
-- TOC entry 5625 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.hidden_gem_reason_code; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.hidden_gem_reason_code IS 'Field hidden_gem_reason_code on mv_tune_analytics';


--
-- TOC entry 5626 (class 0 OID 0)
-- Dependencies: 356
-- Name: COLUMN mv_tune_analytics.analytics_updated_at; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_analytics.analytics_updated_at IS 'Timestamp of when these analytics were calculated/updated';


--
-- TOC entry 355 (class 1259 OID 1116986)
-- Name: mv_tune_hidden_gem_features; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_hidden_gem_features AS
 WITH tune_base AS (
         SELECT tm.tune_id,
            tm.primary_name,
            tm.type,
            tm.meter,
            tm.mode,
            tm.incipit,
            COALESCE(tm.tunebooks, 0) AS tunebook_count,
            COALESCE(tm.star_rating, 0) AS star_rating,
            COALESCE(tm.has_recording_albums, false) AS has_recording_albums
           FROM thesession.mv_tune_meta tm
          WHERE (tm.tune_id IS NOT NULL)
        ), settings AS (
         SELECT session_tunes_raw.tune_id,
            count(*) AS settings_count,
            count(DISTINCT session_tunes_raw.mode) FILTER (WHERE ((session_tunes_raw.mode IS NOT NULL) AND (btrim(session_tunes_raw.mode) <> ''::text))) AS distinct_modes_count
           FROM thesession.session_tunes_raw
          WHERE (session_tunes_raw.tune_id IS NOT NULL)
          GROUP BY session_tunes_raw.tune_id
        ), recordings AS (
         SELECT session_recording.tune_id,
            count(*) AS recording_occurrence_count,
            count(DISTINCT session_recording.id) AS recording_count,
            count(DISTINCT COALESCE(('id:'::text || (session_recording.artist_id)::text), ('name:'::text || lower(btrim(session_recording.artist_name))))) FILTER (WHERE ((session_recording.artist_name IS NOT NULL) AND (btrim(session_recording.artist_name) <> ''::text))) AS recording_artist_count
           FROM thesession.session_recording
          WHERE (session_recording.tune_id IS NOT NULL)
          GROUP BY session_recording.tune_id
        ), recording_albums AS (
         SELECT sr.tune_id,
            count(DISTINCT sra.recording_id) AS recording_album_count
           FROM (thesession.session_recording sr
             JOIN thesession.session_recording_album sra ON ((sra.recording_id = sr.id)))
          WHERE (sr.tune_id IS NOT NULL)
          GROUP BY sr.tune_id
        ), bookmarks AS (
         SELECT session_member_bookmark_setting.tune_id,
            count(*) AS bookmark_count,
            count(DISTINCT session_member_bookmark_setting.member_id) AS bookmark_member_count
           FROM thesession.session_member_bookmark_setting
          WHERE (session_member_bookmark_setting.tune_id IS NOT NULL)
          GROUP BY session_member_bookmark_setting.tune_id
        ), set_usage AS (
         SELECT i.tune_id,
            count(*) AS set_appearance_count,
            count(DISTINCT i.tuneset) AS distinct_set_count,
            count(DISTINCT s.member_id) FILTER (WHERE (s.member_id IS NOT NULL)) AS set_member_count,
            round(avg(i.settingorder), 2) AS average_set_position,
            (min(s.date))::date AS first_seen_in_sets,
            (max(s.date))::date AS latest_seen_in_sets
           FROM (thesession.session_set_items_raw i
             JOIN thesession.session_sets_raw s ON ((s.tuneset = i.tuneset)))
          WHERE (i.tune_id IS NOT NULL)
          GROUP BY i.tune_id
        ), combined AS (
         SELECT b.tune_id,
            b.primary_name,
            b.type,
            b.meter,
            b.mode,
            b.incipit,
            b.tunebook_count,
            b.star_rating,
            b.has_recording_albums,
            COALESCE(st.settings_count, (0)::bigint) AS settings_count,
            COALESCE(st.distinct_modes_count, (0)::bigint) AS distinct_modes_count,
            COALESCE(r.recording_occurrence_count, (0)::bigint) AS recording_occurrence_count,
            COALESCE(r.recording_count, (0)::bigint) AS recording_count,
            COALESCE(r.recording_artist_count, (0)::bigint) AS recording_artist_count,
            COALESCE(ra.recording_album_count, (0)::bigint) AS recording_album_count,
            COALESCE(bm.bookmark_count, (0)::bigint) AS bookmark_count,
            COALESCE(bm.bookmark_member_count, (0)::bigint) AS bookmark_member_count,
            COALESCE(su.set_appearance_count, (0)::bigint) AS set_appearance_count,
            COALESCE(su.distinct_set_count, (0)::bigint) AS distinct_set_count,
            COALESCE(su.set_member_count, (0)::bigint) AS set_member_count,
            su.average_set_position,
            su.first_seen_in_sets,
            su.latest_seen_in_sets
           FROM (((((tune_base b
             LEFT JOIN settings st ON ((st.tune_id = b.tune_id)))
             LEFT JOIN recordings r ON ((r.tune_id = b.tune_id)))
             LEFT JOIN recording_albums ra ON ((ra.tune_id = b.tune_id)))
             LEFT JOIN bookmarks bm ON ((bm.tune_id = b.tune_id)))
             LEFT JOIN set_usage su ON ((su.tune_id = b.tune_id)))
        ), percentiles AS (
         SELECT c.tune_id,
            c.primary_name,
            c.type,
            c.meter,
            c.mode,
            c.incipit,
            c.tunebook_count,
            c.star_rating,
            c.has_recording_albums,
            c.settings_count,
            c.distinct_modes_count,
            c.recording_occurrence_count,
            c.recording_count,
            c.recording_artist_count,
            c.recording_album_count,
            c.bookmark_count,
            c.bookmark_member_count,
            c.set_appearance_count,
            c.distinct_set_count,
            c.set_member_count,
            c.average_set_position,
            c.first_seen_in_sets,
            c.latest_seen_in_sets,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.recording_count))::numeric AS recording_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.recording_artist_count))::numeric AS artist_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.bookmark_count))::numeric AS bookmark_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.set_appearance_count))::numeric AS set_percentile_by_type,
            (percent_rank() OVER (PARTITION BY c.type ORDER BY c.tunebook_count))::numeric AS tunebook_percentile_by_type
           FROM combined c
        ), signals AS (
         SELECT p.tune_id,
            p.primary_name,
            p.type,
            p.meter,
            p.mode,
            p.incipit,
            p.tunebook_count,
            p.star_rating,
            p.has_recording_albums,
            p.settings_count,
            p.distinct_modes_count,
            p.recording_occurrence_count,
            p.recording_count,
            p.recording_artist_count,
            p.recording_album_count,
            p.bookmark_count,
            p.bookmark_member_count,
            p.set_appearance_count,
            p.distinct_set_count,
            p.set_member_count,
            p.average_set_position,
            p.first_seen_in_sets,
            p.latest_seen_in_sets,
            p.recording_percentile_by_type,
            p.artist_percentile_by_type,
            p.bookmark_percentile_by_type,
            p.set_percentile_by_type,
            p.tunebook_percentile_by_type,
            ((p.tunebook_count = 0) AND (p.bookmark_count = 0) AND (p.set_appearance_count = 0)) AS is_zero_exposure,
                CASE
                    WHEN ((p.recording_count >= 20) AND (p.recording_artist_count >= 15)) THEN 'strong'::text
                    WHEN ((p.recording_count >= 10) AND (p.recording_artist_count >= 8)) THEN 'medium'::text
                    WHEN (p.recording_count >= 5) THEN 'weak'::text
                    ELSE 'thin'::text
                END AS evidence_level,
            round((((((0.40 * p.recording_percentile_by_type) + (0.30 * p.artist_percentile_by_type)) + (0.15 * LEAST(((p.recording_album_count)::numeric / 10.0), 1.0))) + (0.15 * LEAST(((p.settings_count)::numeric / 20.0), 1.0))) * (100)::numeric), 2) AS quality_signal,
            round(((((0.40 * p.set_percentile_by_type) + (0.30 * p.bookmark_percentile_by_type)) + (0.30 * p.tunebook_percentile_by_type)) * (100)::numeric), 2) AS exposure_signal
           FROM percentiles p
        ), scored AS (
         SELECT s.tune_id,
            s.primary_name,
            s.type,
            s.meter,
            s.mode,
            s.incipit,
            s.tunebook_count,
            s.star_rating,
            s.has_recording_albums,
            s.settings_count,
            s.distinct_modes_count,
            s.recording_occurrence_count,
            s.recording_count,
            s.recording_artist_count,
            s.recording_album_count,
            s.bookmark_count,
            s.bookmark_member_count,
            s.set_appearance_count,
            s.distinct_set_count,
            s.set_member_count,
            s.average_set_position,
            s.first_seen_in_sets,
            s.latest_seen_in_sets,
            s.recording_percentile_by_type,
            s.artist_percentile_by_type,
            s.bookmark_percentile_by_type,
            s.set_percentile_by_type,
            s.tunebook_percentile_by_type,
            s.is_zero_exposure,
            s.evidence_level,
            s.quality_signal,
            s.exposure_signal,
            round(((s.quality_signal - s.exposure_signal) - (
                CASE
                    WHEN s.is_zero_exposure THEN 8
                    ELSE 0
                END)::numeric), 2) AS hidden_gem_score
           FROM signals s
        )
 SELECT tune_id,
    primary_name,
    type,
    meter,
    mode,
    incipit,
    tunebook_count,
    star_rating,
    has_recording_albums,
    settings_count,
    distinct_modes_count,
    recording_occurrence_count,
    recording_count,
    recording_artist_count,
    recording_album_count,
    bookmark_count,
    bookmark_member_count,
    set_appearance_count,
    distinct_set_count,
    set_member_count,
    average_set_position,
    first_seen_in_sets,
    latest_seen_in_sets,
    recording_percentile_by_type,
    artist_percentile_by_type,
    bookmark_percentile_by_type,
    set_percentile_by_type,
    tunebook_percentile_by_type,
    is_zero_exposure,
    evidence_level,
    quality_signal,
    exposure_signal,
    hidden_gem_score,
        CASE
            WHEN ((hidden_gem_score >= (50)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text])) AND (NOT is_zero_exposure)) THEN 'safe_hidden_gem'::text
            WHEN ((hidden_gem_score >= (50)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text])) AND is_zero_exposure) THEN 'deep_cut'::text
            WHEN ((hidden_gem_score >= (30)::numeric) AND (evidence_level = ANY (ARRAY['strong'::text, 'medium'::text]))) THEN 'possible_hidden_gem'::text
            WHEN ((evidence_level = 'weak'::text) AND (hidden_gem_score >= (40)::numeric)) THEN 'needs_review'::text
            ELSE 'not_candidate'::text
        END AS hidden_gem_tier,
        CASE
            WHEN ((recording_count >= 10) AND (recording_artist_count >= 5) AND (set_percentile_by_type <= 0.35) AND (bookmark_percentile_by_type <= 0.35)) THEN 'recorded_but_underplayed'::text
            WHEN ((recording_artist_count >= 8) AND (tunebook_percentile_by_type <= 0.40)) THEN 'many_artists_low_tunebooks'::text
            WHEN ((settings_count >= 10) AND (recording_count >= 5) AND (set_appearance_count <= 10)) THEN 'many_settings_low_session_use'::text
            ELSE 'general_candidate'::text
        END AS hidden_gem_reason_code,
    now() AS analytics_updated_at
   FROM scored
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_hidden_gem_features OWNER TO folkguitar;

--
-- TOC entry 5627 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5628 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5629 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.type IS 'Rhythm type of the tune (e.g., reel, jig, hornpipe, polka, slide, slip jig)';


--
-- TOC entry 5630 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.meter; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.meter IS 'Time signature/meter of the tune setting (e.g., 4/4, 6/8, 9/8)';


--
-- TOC entry 5631 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.mode; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.mode IS 'Modal key of the setting (e.g., Gmajor, Adorian, Edorian, Dmixolydian)';


--
-- TOC entry 5632 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.incipit; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.incipit IS 'Opening ABC notation snippet (first 1-2 bars) of the tune melody';


--
-- TOC entry 5633 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.tunebook_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.tunebook_count IS 'Number of member tunebooks containing this tune';


--
-- TOC entry 5634 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.star_rating; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.star_rating IS 'Average star rating of the tune on TheSession.org';


--
-- TOC entry 5635 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.has_recording_albums; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.has_recording_albums IS 'Boolean flag indicating if the tune has been recorded on commercial albums';


--
-- TOC entry 5636 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.settings_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.settings_count IS 'Total settings/transcriptions of this tune on TheSession.org';


--
-- TOC entry 5637 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.distinct_modes_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.distinct_modes_count IS 'Number of distinct modes/keys this tune is played in';


--
-- TOC entry 5638 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.recording_occurrence_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.recording_occurrence_count IS 'Count of recording occurrences';


--
-- TOC entry 5639 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.recording_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.recording_count IS 'Total number of commercial recordings featuring this tune';


--
-- TOC entry 5640 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.recording_artist_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.recording_artist_count IS 'Number of unique recording artists who have recorded this tune';


--
-- TOC entry 5641 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.recording_album_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.recording_album_count IS 'Number of unique albums featuring this tune';


--
-- TOC entry 5642 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.bookmark_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.bookmark_count IS 'Number of members who have bookmarked/saved this tune';


--
-- TOC entry 5643 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.bookmark_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.bookmark_member_count IS 'Count of bookmark members';


--
-- TOC entry 5644 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.set_appearance_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.set_appearance_count IS 'Number of session sets/sequences that include this tune';


--
-- TOC entry 5645 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.distinct_set_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.distinct_set_count IS 'Number of distinct sets containing this tune';


--
-- TOC entry 5646 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.set_member_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.set_member_count IS 'Number of unique session players who have contributed sets containing this tune';


--
-- TOC entry 5647 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.average_set_position; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.average_set_position IS 'Average position of the tune within sets (e.g., 1st, 2nd, 3rd)';


--
-- TOC entry 5648 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.first_seen_in_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.first_seen_in_sets IS 'Earliest date this tune appeared in a session set';


--
-- TOC entry 5649 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.latest_seen_in_sets; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.latest_seen_in_sets IS 'Most recent date this tune appeared in a session set';


--
-- TOC entry 5650 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.recording_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.recording_percentile_by_type IS 'Percentile rank of commercial recordings compared to other tunes of the same rhythm type';


--
-- TOC entry 5651 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.artist_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.artist_percentile_by_type IS 'Percentile rank of distinct recording artists compared to same rhythm type';


--
-- TOC entry 5652 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.bookmark_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.bookmark_percentile_by_type IS 'Percentile rank of member bookmark saves compared to same rhythm type';


--
-- TOC entry 5653 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.set_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.set_percentile_by_type IS 'Percentile rank of session set appearances compared to same rhythm type';


--
-- TOC entry 5654 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.tunebook_percentile_by_type; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.tunebook_percentile_by_type IS 'Percentile rank of tunebook additions compared to same rhythm type';


--
-- TOC entry 5655 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.is_zero_exposure; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.is_zero_exposure IS 'Boolean indicating if the tune has absolutely zero session exposure';


--
-- TOC entry 5656 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.evidence_level; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.evidence_level IS 'Confidence rating of the data quality (e.g., strong, medium, weak)';


--
-- TOC entry 5657 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.quality_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.quality_signal IS 'Calculated quality rating score based on recordings, settings, and ratings';


--
-- TOC entry 5658 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.exposure_signal; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.exposure_signal IS 'Calculated exposure/popularity rating score in sessions and tunebooks';


--
-- TOC entry 5659 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.hidden_gem_score; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.hidden_gem_score IS 'Calculated score indicating how much of a hidden gem the tune is';


--
-- TOC entry 5660 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.hidden_gem_tier; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.hidden_gem_tier IS 'Tier level classification of the hidden gem (e.g., gold, silver, bronze)';


--
-- TOC entry 5661 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.hidden_gem_reason_code; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.hidden_gem_reason_code IS 'Text code explaining why this tune is classified as a hidden gem';


--
-- TOC entry 5662 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN mv_tune_hidden_gem_features.analytics_updated_at; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_hidden_gem_features.analytics_updated_at IS 'Timestamp of when these analytics were calculated/updated';


--
-- TOC entry 342 (class 1259 OID 881680)
-- Name: mv_tune_name_search; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_name_search AS
 SELECT tm.tune_id,
    tm.primary_name,
    tm.primary_name AS search_name,
    true AS is_primary
   FROM thesession.mv_tune_meta tm
  WHERE ((tm.primary_name IS NOT NULL) AND (btrim(tm.primary_name) <> ''::text))
UNION
 SELECT tm.tune_id,
    tm.primary_name,
    a.alias AS search_name,
    false AS is_primary
   FROM (thesession.mv_tune_meta tm
     CROSS JOIN LATERAL unnest(COALESCE(tm.aliases, ARRAY[]::text[])) a(alias))
  WHERE ((a.alias IS NOT NULL) AND (btrim(a.alias) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_name_search OWNER TO folkguitar;

--
-- TOC entry 5663 (class 0 OID 0)
-- Dependencies: 342
-- Name: COLUMN mv_tune_name_search.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_name_search.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5664 (class 0 OID 0)
-- Dependencies: 342
-- Name: COLUMN mv_tune_name_search.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_name_search.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5665 (class 0 OID 0)
-- Dependencies: 342
-- Name: COLUMN mv_tune_name_search.search_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_name_search.search_name IS 'Name of the search';


--
-- TOC entry 5666 (class 0 OID 0)
-- Dependencies: 342
-- Name: COLUMN mv_tune_name_search.is_primary; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_name_search.is_primary IS 'Field is_primary on mv_tune_name_search';


--
-- TOC entry 306 (class 1259 OID 539944)
-- Name: mv_tune_recording_artists; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_recording_artists AS
 SELECT tune_id,
    artist_id,
    COALESCE(NULLIF(TRIM(BOTH FROM artist_name), ''::text), '[Unknown artist]'::text) AS artist_name,
    COALESCE(('id:'::text || (artist_id)::text), ('name:'::text || lower(TRIM(BOTH FROM artist_name)))) AS artist_key,
    count(*) AS occurrence_count,
    count(DISTINCT id) AS recording_count,
    min(recording) AS sample_recording,
    min(track) AS min_track,
    max(track) AS max_track
   FROM thesession.session_recording sr
  WHERE ((tune_id IS NOT NULL) AND (NULLIF(TRIM(BOTH FROM artist_name), ''::text) IS NOT NULL))
  GROUP BY tune_id, artist_id, COALESCE(NULLIF(TRIM(BOTH FROM artist_name), ''::text), '[Unknown artist]'::text), COALESCE(('id:'::text || (artist_id)::text), ('name:'::text || lower(TRIM(BOTH FROM artist_name))))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_recording_artists OWNER TO folkguitar;

--
-- TOC entry 5667 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5668 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.artist_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.artist_id IS 'Canonical ID of the recording artist';


--
-- TOC entry 5669 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5670 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.artist_key; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.artist_key IS 'URL slug / unique key of the recording artist';


--
-- TOC entry 5671 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.occurrence_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.occurrence_count IS 'Number of times this artist has recorded this specific tune';


--
-- TOC entry 5672 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.recording_count; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.recording_count IS 'Total number of commercial recordings featuring this tune';


--
-- TOC entry 5673 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.sample_recording; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.sample_recording IS 'Title of a sample recording of this tune by the artist';


--
-- TOC entry 5674 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.min_track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.min_track IS 'First track number on which the artist recorded this tune';


--
-- TOC entry 5675 (class 0 OID 0)
-- Dependencies: 306
-- Name: COLUMN mv_tune_recording_artists.max_track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_artists.max_track IS 'Last track number on which the artist recorded this tune';


--
-- TOC entry 307 (class 1259 OID 540066)
-- Name: mv_tune_recording_detail; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_recording_detail AS
 SELECT sr.tune_id,
    COALESCE(mtn.primary_name, sr.tune_name) AS primary_name,
    mtn.aliases,
    sr.id AS recording_id,
    sr.recording,
    sr.artist_id,
    sr.artist_name,
    sr.track,
    sr.tune_number,
    sr.tune_name AS recording_tune_name
   FROM (thesession.session_recording sr
     LEFT JOIN thesession.mv_tune_names mtn ON ((mtn.tune_id = sr.tune_id)))
  WHERE ((sr.tune_id IS NOT NULL) AND (NULLIF(TRIM(BOTH FROM sr.artist_name), ''::text) IS NOT NULL))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_recording_detail OWNER TO folkguitar;

--
-- TOC entry 5676 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.tune_id IS 'Canonical ID of the traditional tune';


--
-- TOC entry 5677 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.primary_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.primary_name IS 'Canonical primary name of the traditional tune';


--
-- TOC entry 5678 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.aliases; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.aliases IS 'Array of alternative names or titles for the tune';


--
-- TOC entry 5679 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.recording_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.recording_id IS 'Canonical ID of the commercial recording/album';


--
-- TOC entry 5680 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.recording; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.recording IS 'Field recording on mv_tune_recording_detail';


--
-- TOC entry 5681 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.artist_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.artist_id IS 'Canonical ID of the recording artist';


--
-- TOC entry 5682 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.artist_name IS 'Name of the recording artist';


--
-- TOC entry 5683 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.track IS 'Track number on the album or recording';


--
-- TOC entry 5684 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.tune_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.tune_number IS 'Sequence position of this tune on the recorded track';


--
-- TOC entry 5685 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN mv_tune_recording_detail.recording_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_recording_detail.recording_tune_name IS 'The specific title of the tune as printed on the recording sleeve/metadata';


--
-- TOC entry 304 (class 1259 OID 513105)
-- Name: mv_tune_transition_evidence; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.mv_tune_transition_evidence AS
 SELECT r1.tune_id AS source_tune_id,
    r2.tune_id AS target_tune_id,
    r1.id AS recording_id,
    r1.track,
    r1.tune_number AS source_tune_number,
    r2.tune_number AS target_tune_number,
    r1.tune_name AS source_tune_name,
    r2.tune_name AS target_tune_name,
    r1.recording AS recording_title,
    r1.artist_id,
    r1.artist_name
   FROM (thesession.session_recording r1
     JOIN thesession.session_recording r2 ON (((r1.id = r2.id) AND (r1.track = r2.track) AND (r2.tune_number = (r1.tune_number + 1)))))
  WHERE ((r1.tune_id IS NOT NULL) AND (r2.tune_id IS NOT NULL) AND (r1.tune_id <> r2.tune_id))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.mv_tune_transition_evidence OWNER TO folkguitar;

--
-- TOC entry 5686 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.source_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.source_tune_id IS 'ID of the source tune in the transition';


--
-- TOC entry 5687 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.target_tune_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.target_tune_id IS 'ID of the target tune in the transition';


--
-- TOC entry 5688 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.recording_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.recording_id IS 'Canonical ID of the commercial recording/album';


--
-- TOC entry 5689 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.track; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.track IS 'Track number on the album or recording';


--
-- TOC entry 5690 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.source_tune_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.source_tune_number IS 'Position of the source tune on the recorded track';


--
-- TOC entry 5691 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.target_tune_number; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.target_tune_number IS 'Position of the target tune on the recorded track';


--
-- TOC entry 5692 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.source_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.source_tune_name IS 'Name of the source tune';


--
-- TOC entry 5693 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.target_tune_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.target_tune_name IS 'Name of the target tune';


--
-- TOC entry 5694 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.recording_title; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.recording_title IS 'Title of the commercial recording/album';


--
-- TOC entry 5695 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.artist_id; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.artist_id IS 'ID of the recording artist';


--
-- TOC entry 5696 (class 0 OID 0)
-- Dependencies: 304
-- Name: COLUMN mv_tune_transition_evidence.artist_name; Type: COMMENT; Schema: thesession; Owner: folkguitar
--

COMMENT ON COLUMN thesession.mv_tune_transition_evidence.artist_name IS 'Name of the recording artist';


--
-- TOC entry 349 (class 1259 OID 942546)
-- Name: naturalearth_countries; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.naturalearth_countries (
    gid integer NOT NULL,
    featurecla character varying(15),
    scalerank smallint,
    labelrank smallint,
    sovereignt character varying(32),
    sov_a3 character varying(3),
    adm0_dif smallint,
    level smallint,
    type character varying(17),
    tlc character varying(1),
    admin character varying(36),
    adm0_a3 character varying(3),
    geou_dif smallint,
    geounit character varying(36),
    gu_a3 character varying(3),
    su_dif smallint,
    subunit character varying(36),
    su_a3 character varying(3),
    brk_diff smallint,
    name character varying(29),
    name_long character varying(36),
    brk_a3 character varying(3),
    brk_name character varying(32),
    brk_group character varying(17),
    abbrev character varying(16),
    postal character varying(4),
    formal_en character varying(52),
    formal_fr character varying(35),
    name_ciawf character varying(45),
    note_adm0 character varying(16),
    note_brk character varying(63),
    name_sort character varying(36),
    name_alt character varying(19),
    mapcolor7 smallint,
    mapcolor8 smallint,
    mapcolor9 smallint,
    mapcolor13 smallint,
    pop_est double precision,
    pop_rank smallint,
    pop_year smallint,
    gdp_md integer,
    gdp_year smallint,
    economy character varying(26),
    income_grp character varying(23),
    fips_10 character varying(3),
    iso_a2 character varying(5),
    iso_a2_eh character varying(3),
    iso_a3 character varying(3),
    iso_a3_eh character varying(3),
    iso_n3 character varying(3),
    iso_n3_eh character varying(3),
    un_a3 character varying(4),
    wb_a2 character varying(3),
    wb_a3 character varying(3),
    woe_id integer,
    woe_id_eh integer,
    woe_note character varying(167),
    adm0_iso character varying(3),
    adm0_diff character varying(1),
    adm0_tlc character varying(3),
    adm0_a3_us character varying(3),
    adm0_a3_fr character varying(3),
    adm0_a3_ru character varying(3),
    adm0_a3_es character varying(3),
    adm0_a3_cn character varying(3),
    adm0_a3_tw character varying(3),
    adm0_a3_in character varying(3),
    adm0_a3_np character varying(3),
    adm0_a3_pk character varying(3),
    adm0_a3_de character varying(3),
    adm0_a3_gb character varying(3),
    adm0_a3_br character varying(3),
    adm0_a3_il character varying(3),
    adm0_a3_ps character varying(3),
    adm0_a3_sa character varying(3),
    adm0_a3_eg character varying(3),
    adm0_a3_ma character varying(3),
    adm0_a3_pt character varying(3),
    adm0_a3_ar character varying(3),
    adm0_a3_jp character varying(3),
    adm0_a3_ko character varying(3),
    adm0_a3_vn character varying(3),
    adm0_a3_tr character varying(3),
    adm0_a3_id character varying(3),
    adm0_a3_pl character varying(3),
    adm0_a3_gr character varying(3),
    adm0_a3_it character varying(3),
    adm0_a3_nl character varying(3),
    adm0_a3_se character varying(3),
    adm0_a3_bd character varying(3),
    adm0_a3_ua character varying(3),
    adm0_a3_un smallint,
    adm0_a3_wb smallint,
    continent character varying(23),
    region_un character varying(10),
    subregion character varying(25),
    region_wb character varying(26),
    name_len smallint,
    long_len smallint,
    abbrev_len smallint,
    tiny smallint,
    homepart smallint,
    min_zoom double precision,
    min_label double precision,
    max_label double precision,
    label_x double precision,
    label_y double precision,
    ne_id double precision,
    wikidataid character varying(8),
    name_ar character varying(72),
    name_bn character varying(148),
    name_de character varying(46),
    name_en character varying(44),
    name_es character varying(44),
    name_fa character varying(66),
    name_fr character varying(54),
    name_el character varying(86),
    name_he character varying(78),
    name_hi character varying(126),
    name_hu character varying(52),
    name_id character varying(46),
    name_it character varying(48),
    name_ja character varying(63),
    name_ko character varying(47),
    name_nl character varying(49),
    name_pl character varying(47),
    name_pt character varying(43),
    name_ru character varying(86),
    name_sv character varying(57),
    name_tr character varying(42),
    name_uk character varying(91),
    name_ur character varying(67),
    name_vi character varying(56),
    name_zh character varying(33),
    name_zht character varying(33),
    fclass_iso character varying(24),
    tlc_diff character varying(1),
    fclass_tlc character varying(21),
    fclass_us character varying(30),
    fclass_fr character varying(18),
    fclass_ru character varying(14),
    fclass_es character varying(18),
    fclass_cn character varying(24),
    fclass_tw character varying(15),
    fclass_in character varying(14),
    fclass_np character varying(24),
    fclass_pk character varying(15),
    fclass_de character varying(18),
    fclass_gb character varying(18),
    fclass_br character varying(12),
    fclass_il character varying(15),
    fclass_ps character varying(15),
    fclass_sa character varying(15),
    fclass_eg character varying(24),
    fclass_ma character varying(24),
    fclass_pt character varying(18),
    fclass_ar character varying(12),
    fclass_jp character varying(18),
    fclass_ko character varying(18),
    fclass_vn character varying(12),
    fclass_tr character varying(18),
    fclass_id character varying(24),
    fclass_pl character varying(18),
    fclass_gr character varying(18),
    fclass_it character varying(18),
    fclass_nl character varying(18),
    fclass_se character varying(18),
    fclass_bd character varying(24),
    fclass_ua character varying(18),
    geom public.geometry(MultiPolygon,4326)
);


ALTER TABLE thesession.naturalearth_countries OWNER TO folkguitar;

--
-- TOC entry 348 (class 1259 OID 942545)
-- Name: naturalearth_countries_gid_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.naturalearth_countries_gid_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.naturalearth_countries_gid_seq OWNER TO folkguitar;

--
-- TOC entry 5697 (class 0 OID 0)
-- Dependencies: 348
-- Name: naturalearth_countries_gid_seq; Type: SEQUENCE OWNED BY; Schema: thesession; Owner: folkguitar
--

ALTER SEQUENCE thesession.naturalearth_countries_gid_seq OWNED BY thesession.naturalearth_countries.gid;


--
-- TOC entry 324 (class 1259 OID 690238)
-- Name: session_activity_raw; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_activity_raw (
    activity_key text NOT NULL,
    published_at timestamp without time zone NOT NULL,
    title text,
    actor_member_id bigint,
    actor_name text,
    actor_url text,
    verb text,
    object_type text,
    object_id text,
    object_url text,
    object_name text,
    target_type text,
    target_id text,
    target_url text,
    target_name text,
    raw_json jsonb NOT NULL,
    processed boolean DEFAULT false NOT NULL,
    processed_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    stream text DEFAULT 'tunes'::text NOT NULL
);


ALTER TABLE thesession.session_activity_raw OWNER TO folkguitar;

--
-- TOC entry 276 (class 1259 OID 340004)
-- Name: session_event; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_event (
    id integer NOT NULL,
    name text NOT NULL,
    dt_start timestamp without time zone,
    dt_end timestamp without time zone,
    address text,
    town text,
    area text,
    country text,
    latitude numeric(10,8),
    longitude numeric(11,8),
    created_at timestamp without time zone DEFAULT now(),
    geom public.geography(Point,4326),
    venue_name text,
    venue_web text,
    venue_phone text,
    venue_email text
);


ALTER TABLE thesession.session_event OWNER TO folkguitar;

--
-- TOC entry 284 (class 1259 OID 376293)
-- Name: session_event_comment; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_event_comment (
    id integer NOT NULL,
    event_id integer NOT NULL,
    subject text,
    content text,
    member_id integer,
    member_name text,
    member_url text,
    comment_url text,
    comment_date timestamp without time zone,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE thesession.session_event_comment OWNER TO folkguitar;

--
-- TOC entry 287 (class 1259 OID 391557)
-- Name: session_tune_alias; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_tune_alias (
    id bigint NOT NULL,
    tune_id bigint NOT NULL,
    alias text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE thesession.session_tune_alias OWNER TO folkguitar;

--
-- TOC entry 286 (class 1259 OID 391556)
-- Name: session_tune_alias_id_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.session_tune_alias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.session_tune_alias_id_seq OWNER TO folkguitar;

--
-- TOC entry 5698 (class 0 OID 0)
-- Dependencies: 286
-- Name: session_tune_alias_id_seq; Type: SEQUENCE OWNED BY; Schema: thesession; Owner: folkguitar
--

ALTER SEQUENCE thesession.session_tune_alias_id_seq OWNED BY thesession.session_tune_alias.id;


--
-- TOC entry 285 (class 1259 OID 378541)
-- Name: session_venue; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.session_venue (
    venue_id integer NOT NULL,
    venue_name text NOT NULL,
    venue_phone text,
    venue_email text,
    venue_web text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE thesession.session_venue OWNER TO folkguitar;

--
-- TOC entry 288 (class 1259 OID 396466)
-- Name: sessions; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.sessions (
    id integer NOT NULL,
    name text,
    address text,
    town text,
    area text,
    country text,
    latitude numeric(10,8),
    longitude numeric(11,8),
    created_at timestamp without time zone,
    geom public.geography(Point,4326),
    session_date date,
    venue_phone text,
    venue_email text,
    venue_web text,
    comment text
);


ALTER TABLE thesession.sessions OWNER TO folkguitar;

--
-- TOC entry 291 (class 1259 OID 399763)
-- Name: tune_collection; Type: TABLE; Schema: thesession; Owner: folkguitar
--

CREATE TABLE thesession.tune_collection (
    id bigint NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    source text,
    total_tunes integer,
    pages integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    session_collection_id integer
);


ALTER TABLE thesession.tune_collection OWNER TO folkguitar;

--
-- TOC entry 290 (class 1259 OID 399762)
-- Name: tune_collection_id_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.tune_collection_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.tune_collection_id_seq OWNER TO folkguitar;

--
-- TOC entry 5699 (class 0 OID 0)
-- Dependencies: 290
-- Name: tune_collection_id_seq; Type: SEQUENCE OWNED BY; Schema: thesession; Owner: folkguitar
--

ALTER SEQUENCE thesession.tune_collection_id_seq OWNED BY thesession.tune_collection.id;


--
-- TOC entry 292 (class 1259 OID 399776)
-- Name: tune_collection_item_id_seq; Type: SEQUENCE; Schema: thesession; Owner: folkguitar
--

CREATE SEQUENCE thesession.tune_collection_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE thesession.tune_collection_item_id_seq OWNER TO folkguitar;

--
-- TOC entry 5700 (class 0 OID 0)
-- Dependencies: 292
-- Name: tune_collection_item_id_seq; Type: SEQUENCE OWNED BY; Schema: thesession; Owner: folkguitar
--

ALTER SEQUENCE thesession.tune_collection_item_id_seq OWNED BY thesession.tune_collection_item.id;


--
-- TOC entry 336 (class 1259 OID 859198)
-- Name: zz_old_mv_melody_2bar_fragment_ngrams_v2; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 AS
 WITH fragments AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.interval_fingerprint,
            f.rhythm_fingerprint,
            thesession.melody_contour_fingerprint(f.interval_fingerprint) AS fragment_contour_fingerprint,
            string_to_array(f.interval_fingerprint, ','::text) AS interval_parts,
            string_to_array(f.rhythm_fingerprint, ','::text) AS rhythm_parts
           FROM thesession.mv_melody_2bar_fragments_old f
          WHERE ((f.interval_fingerprint IS NOT NULL) AND (btrim(f.interval_fingerprint) <> ''::text))
        ), ngrams AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.fragment_contour_fingerprint,
            4 AS ngram_size,
            gs.pos AS ngram_position,
            array_to_string(f.interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS interval_ngram,
            array_to_string(f.rhythm_parts[gs.pos:(gs.pos + 4)], ','::text) AS rhythm_ngram
           FROM (fragments f
             CROSS JOIN LATERAL generate_series(1, GREATEST(((array_length(f.interval_parts, 1) - 4) + 1), 0)) gs(pos))
        )
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    fragment_contour_fingerprint,
    ngram_size,
    ngram_position,
    interval_ngram,
    rhythm_ngram
   FROM ngrams
  WHERE ((interval_ngram IS NOT NULL) AND (btrim(interval_ngram) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 OWNER TO folkguitar;

--
-- TOC entry 337 (class 1259 OID 862101)
-- Name: zz_old_mv_melody_2bar_fragment_ngrams_v3; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 AS
 WITH fragments AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            fp.interval_fingerprint,
            fp.rhythm_fingerprint,
            thesession.melody_contour_fingerprint(fp.interval_fingerprint) AS fragment_contour_fingerprint,
            string_to_array(fp.interval_fingerprint, ','::text) AS interval_parts,
            string_to_array(fp.rhythm_fingerprint, ','::text) AS rhythm_parts
           FROM (thesession.mv_melody_2bar_fragments_old f
             CROSS JOIN LATERAL thesession.melody_2bar_fuzzy_fingerprint_from_abc((((('| '::text || f.bar_1_text) || ' | '::text) || f.bar_2_text) || ' |'::text)) fp(bar_count, note_count, interval_fingerprint, rhythm_fingerprint))
          WHERE ((fp.interval_fingerprint IS NOT NULL) AND (btrim(fp.interval_fingerprint) <> ''::text))
        ), ngrams AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.fragment_contour_fingerprint,
            4 AS ngram_size,
            gs.pos AS ngram_position,
            array_to_string(f.interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS interval_ngram,
            array_to_string(f.rhythm_parts[gs.pos:(gs.pos + 4)], ','::text) AS rhythm_ngram
           FROM (fragments f
             CROSS JOIN LATERAL generate_series(1, GREATEST(((array_length(f.interval_parts, 1) - 4) + 1), 0)) gs(pos))
        )
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    fragment_contour_fingerprint,
    ngram_size,
    ngram_position,
    interval_ngram,
    rhythm_ngram
   FROM ngrams
  WHERE ((interval_ngram IS NOT NULL) AND (btrim(interval_ngram) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 OWNER TO folkguitar;

--
-- TOC entry 339 (class 1259 OID 863583)
-- Name: zz_old_mv_melody_2bar_fragment_ngrams_v4; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 AS
 WITH fragments AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            fp.interval_fingerprint,
            fp.rhythm_fingerprint,
            thesession.melody_contour_fingerprint(fp.interval_fingerprint) AS fragment_contour_fingerprint,
            thesession.melody_coarse_interval_fingerprint(fp.interval_fingerprint) AS fragment_coarse_fingerprint,
            string_to_array(fp.interval_fingerprint, ','::text) AS interval_parts,
            string_to_array(thesession.melody_coarse_interval_fingerprint(fp.interval_fingerprint), ','::text) AS coarse_interval_parts,
            string_to_array(fp.rhythm_fingerprint, ','::text) AS rhythm_parts
           FROM (thesession.mv_melody_2bar_fragments_old f
             CROSS JOIN LATERAL thesession.melody_2bar_fuzzy_fingerprint_from_abc((((('| '::text || f.bar_1_text) || ' | '::text) || f.bar_2_text) || ' |'::text)) fp(bar_count, note_count, interval_fingerprint, rhythm_fingerprint))
          WHERE ((fp.interval_fingerprint IS NOT NULL) AND (btrim(fp.interval_fingerprint) <> ''::text))
        ), ngrams AS (
         SELECT f.fragment_id,
            f.setting_id,
            f.tune_id,
            f.name,
            f.type,
            f.meter,
            f.mode,
            f.bar_start,
            f.bar_end,
            f.bar_1_text,
            f.bar_2_text,
            f.fragment_contour_fingerprint,
            f.fragment_coarse_fingerprint,
            4 AS ngram_size,
            gs.pos AS ngram_position,
            array_to_string(f.interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS interval_ngram,
            array_to_string(f.coarse_interval_parts[gs.pos:(gs.pos + 3)], ','::text) AS coarse_interval_ngram,
            array_to_string(f.rhythm_parts[gs.pos:(gs.pos + 4)], ','::text) AS rhythm_ngram
           FROM (fragments f
             CROSS JOIN LATERAL generate_series(1, GREATEST(((array_length(f.interval_parts, 1) - 4) + 1), 0)) gs(pos))
        )
 SELECT fragment_id,
    setting_id,
    tune_id,
    name,
    type,
    meter,
    mode,
    bar_start,
    bar_end,
    bar_1_text,
    bar_2_text,
    fragment_contour_fingerprint,
    fragment_coarse_fingerprint,
    ngram_size,
    ngram_position,
    interval_ngram,
    coarse_interval_ngram,
    rhythm_ngram
   FROM ngrams
  WHERE ((interval_ngram IS NOT NULL) AND (btrim(interval_ngram) <> ''::text))
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 OWNER TO folkguitar;

--
-- TOC entry 338 (class 1259 OID 862108)
-- Name: zz_old_mv_melody_2bar_ngram_stats_v3; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_ngram_stats_v3 AS
 SELECT interval_ngram,
    count(*) AS row_count,
    count(DISTINCT tune_id) AS tune_count,
    count(DISTINCT fragment_id) AS fragment_count
   FROM thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3
  GROUP BY interval_ngram
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_ngram_stats_v3 OWNER TO folkguitar;

--
-- TOC entry 340 (class 1259 OID 863590)
-- Name: zz_old_mv_melody_2bar_ngram_stats_v4; Type: MATERIALIZED VIEW; Schema: thesession; Owner: folkguitar
--

CREATE MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_ngram_stats_v4 AS
 SELECT interval_ngram,
    coarse_interval_ngram,
    count(*) AS row_count,
    count(DISTINCT tune_id) AS tune_count,
    count(DISTINCT fragment_id) AS fragment_count
   FROM thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4
  GROUP BY interval_ngram, coarse_interval_ngram
  WITH NO DATA;


ALTER MATERIALIZED VIEW thesession.zz_old_mv_melody_2bar_ngram_stats_v4 OWNER TO folkguitar;

--
-- TOC entry 4651 (class 2604 OID 442117)
-- Name: feature_request id; Type: DEFAULT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.feature_request ALTER COLUMN id SET DEFAULT nextval('thesession.feature_request_id_seq'::regclass);


--
-- TOC entry 4658 (class 2604 OID 942549)
-- Name: naturalearth_countries gid; Type: DEFAULT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.naturalearth_countries ALTER COLUMN gid SET DEFAULT nextval('thesession.naturalearth_countries_gid_seq'::regclass);


--
-- TOC entry 4631 (class 2604 OID 391560)
-- Name: session_tune_alias id; Type: DEFAULT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_tune_alias ALTER COLUMN id SET DEFAULT nextval('thesession.session_tune_alias_id_seq'::regclass);


--
-- TOC entry 4633 (class 2604 OID 399766)
-- Name: tune_collection id; Type: DEFAULT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection ALTER COLUMN id SET DEFAULT nextval('thesession.tune_collection_id_seq'::regclass);


--
-- TOC entry 4636 (class 2604 OID 399780)
-- Name: tune_collection_item id; Type: DEFAULT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection_item ALTER COLUMN id SET DEFAULT nextval('thesession.tune_collection_item_id_seq'::regclass);


--
-- TOC entry 4779 (class 2606 OID 442122)
-- Name: feature_request feature_request_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.feature_request
    ADD CONSTRAINT feature_request_pkey PRIMARY KEY (id);


--
-- TOC entry 4957 (class 2606 OID 944241)
-- Name: member_country member_country_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.member_country
    ADD CONSTRAINT member_country_pkey PRIMARY KEY (member_id);


--
-- TOC entry 4952 (class 2606 OID 942553)
-- Name: naturalearth_countries naturalearth_countries_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.naturalearth_countries
    ADD CONSTRAINT naturalearth_countries_pkey PRIMARY KEY (gid);


--
-- TOC entry 5000 (class 2606 OID 1158834)
-- Name: api_keys pk_api_keys; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.api_keys
    ADD CONSTRAINT pk_api_keys PRIMARY KEY (id);


--
-- TOC entry 4857 (class 2606 OID 690246)
-- Name: session_activity_raw session_activity_raw_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_activity_raw
    ADD CONSTRAINT session_activity_raw_pkey PRIMARY KEY (activity_key);


--
-- TOC entry 4718 (class 2606 OID 376300)
-- Name: session_event_comment session_event_comment_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_event_comment
    ADD CONSTRAINT session_event_comment_pkey PRIMARY KEY (id);


--
-- TOC entry 4714 (class 2606 OID 340011)
-- Name: session_event session_event_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_event
    ADD CONSTRAINT session_event_pkey PRIMARY KEY (id);


--
-- TOC entry 4847 (class 2606 OID 684028)
-- Name: session_member_bookmark_setting session_member_bookmark_setting_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_member_bookmark_setting
    ADD CONSTRAINT session_member_bookmark_setting_pkey PRIMARY KEY (member_id, setting_id);


--
-- TOC entry 4777 (class 2606 OID 436195)
-- Name: session_member session_member_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_member
    ADD CONSTRAINT session_member_pkey PRIMARY KEY (id);


--
-- TOC entry 4811 (class 2606 OID 588961)
-- Name: session_member_tunebook session_member_tunebook_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_member_tunebook
    ADD CONSTRAINT session_member_tunebook_pkey PRIMARY KEY (member_id, tune_id);


--
-- TOC entry 4805 (class 2606 OID 544136)
-- Name: session_recording_album session_recording_album_pk; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_recording_album
    ADD CONSTRAINT session_recording_album_pk PRIMARY KEY (recording_id, provider);


--
-- TOC entry 4759 (class 2606 OID 401360)
-- Name: session_recording session_recording_pk; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_recording
    ADD CONSTRAINT session_recording_pk PRIMARY KEY (id, track, tune_number);


--
-- TOC entry 4706 (class 2606 OID 444929)
-- Name: session_set_items_raw session_set_items_raw_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_set_items_raw
    ADD CONSTRAINT session_set_items_raw_pkey PRIMARY KEY (tuneset, settingorder, setting_id);


--
-- TOC entry 4694 (class 2606 OID 291014)
-- Name: session_sets_raw session_sets_raw_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_sets_raw
    ADD CONSTRAINT session_sets_raw_pkey PRIMARY KEY (tuneset);


--
-- TOC entry 4696 (class 2606 OID 660987)
-- Name: session_sets_raw session_sets_raw_uq_member_tuneset; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_sets_raw
    ADD CONSTRAINT session_sets_raw_uq_member_tuneset UNIQUE (member_id, tuneset);


--
-- TOC entry 4724 (class 2606 OID 391565)
-- Name: session_tune_alias session_tune_alias_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_tune_alias
    ADD CONSTRAINT session_tune_alias_pkey PRIMARY KEY (id);


--
-- TOC entry 4726 (class 2606 OID 391569)
-- Name: session_tune_alias session_tune_alias_unique; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_tune_alias
    ADD CONSTRAINT session_tune_alias_unique UNIQUE (tune_id, alias);


--
-- TOC entry 4685 (class 2606 OID 290952)
-- Name: session_tune_popularity_raw session_tune_popularity_raw_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_tune_popularity_raw
    ADD CONSTRAINT session_tune_popularity_raw_pkey PRIMARY KEY (tune_id);


--
-- TOC entry 4681 (class 2606 OID 290791)
-- Name: session_tunes_raw session_tunes_raw_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_tunes_raw
    ADD CONSTRAINT session_tunes_raw_pkey PRIMARY KEY (setting_id);


--
-- TOC entry 4720 (class 2606 OID 378549)
-- Name: session_venue session_venue_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_venue
    ADD CONSTRAINT session_venue_pkey PRIMARY KEY (venue_id);


--
-- TOC entry 4736 (class 2606 OID 396472)
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- TOC entry 4750 (class 2606 OID 493700)
-- Name: tune_collection_item tune_collection_item_collection_page_position_uk; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection_item
    ADD CONSTRAINT tune_collection_item_collection_page_position_uk UNIQUE (collection_id, page, "position");


--
-- TOC entry 4752 (class 2606 OID 399785)
-- Name: tune_collection_item tune_collection_item_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection_item
    ADD CONSTRAINT tune_collection_item_pkey PRIMARY KEY (id);


--
-- TOC entry 4740 (class 2606 OID 399772)
-- Name: tune_collection tune_collection_pkey; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection
    ADD CONSTRAINT tune_collection_pkey PRIMARY KEY (id);


--
-- TOC entry 4742 (class 2606 OID 492999)
-- Name: tune_collection tune_collection_session_collection_id_uk; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection
    ADD CONSTRAINT tune_collection_session_collection_id_uk UNIQUE (session_collection_id);


--
-- TOC entry 4744 (class 2606 OID 399774)
-- Name: tune_collection tune_collection_slug_key; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection
    ADD CONSTRAINT tune_collection_slug_key UNIQUE (slug);


--
-- TOC entry 5002 (class 2606 OID 1158836)
-- Name: api_keys uq_api_keys_hash; Type: CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.api_keys
    ADD CONSTRAINT uq_api_keys_hash UNIQUE (key_hash);


--
-- TOC entry 4998 (class 1259 OID 1158837)
-- Name: idx_api_keys_hash; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_api_keys_hash ON thesession.api_keys USING btree (key_hash) WHERE ((status)::text = 'active'::text);


--
-- TOC entry 4745 (class 1259 OID 399791)
-- Name: idx_collection_item_collection; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_collection_item_collection ON thesession.tune_collection_item USING btree (collection_id);


--
-- TOC entry 4746 (class 1259 OID 399792)
-- Name: idx_collection_item_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_collection_item_tune ON thesession.tune_collection_item USING btree (tune_id);


--
-- TOC entry 4780 (class 1259 OID 442124)
-- Name: idx_feature_request_created_at; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_feature_request_created_at ON thesession.feature_request USING btree (created_at DESC);


--
-- TOC entry 4781 (class 1259 OID 442123)
-- Name: idx_feature_request_email; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_feature_request_email ON thesession.feature_request USING btree (email);


--
-- TOC entry 4953 (class 1259 OID 944256)
-- Name: idx_member_country_country_code; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_member_country_country_code ON thesession.member_country USING btree (country_code);


--
-- TOC entry 4954 (class 1259 OID 944257)
-- Name: idx_member_country_country_name; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_member_country_country_name ON thesession.member_country USING btree (country_name);


--
-- TOC entry 4955 (class 1259 OID 944258)
-- Name: idx_member_country_source; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_member_country_source ON thesession.member_country USING btree (source);


--
-- TOC entry 4863 (class 1259 OID 784610)
-- Name: idx_mv_artist_name_search_lc; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_name_search_lc ON thesession.mv_artist_name_search USING btree (artist_name_lc);


--
-- TOC entry 4864 (class 1259 OID 784611)
-- Name: idx_mv_artist_name_search_tunes; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_name_search_tunes ON thesession.mv_artist_name_search USING btree (distinct_tunes DESC);


--
-- TOC entry 4866 (class 1259 OID 785045)
-- Name: idx_mv_artist_pathway_related_artists_a; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_pathway_related_artists_a ON thesession.mv_artist_pathway_related_artists USING btree (artist_a);


--
-- TOC entry 4867 (class 1259 OID 785046)
-- Name: idx_mv_artist_pathway_related_artists_b; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_pathway_related_artists_b ON thesession.mv_artist_pathway_related_artists USING btree (artist_b);


--
-- TOC entry 4868 (class 1259 OID 785047)
-- Name: idx_mv_artist_pathway_related_artists_score; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_pathway_related_artists_score ON thesession.mv_artist_pathway_related_artists USING btree (artist_a, relation_score DESC);


--
-- TOC entry 4872 (class 1259 OID 799840)
-- Name: idx_mv_artist_transition_evidence_artist; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_evidence_artist ON thesession.mv_artist_transition_evidence USING btree (artist_name);


--
-- TOC entry 4873 (class 1259 OID 799841)
-- Name: idx_mv_artist_transition_evidence_transition; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_evidence_transition ON thesession.mv_artist_transition_evidence USING btree (source_tune_id, target_tune_id);


--
-- TOC entry 4858 (class 1259 OID 784373)
-- Name: idx_mv_artist_transition_features_artist; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_features_artist ON thesession.mv_artist_transition_features USING btree (artist_name);


--
-- TOC entry 4859 (class 1259 OID 784375)
-- Name: idx_mv_artist_transition_features_source; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_features_source ON thesession.mv_artist_transition_features USING btree (source_tune_id);


--
-- TOC entry 4860 (class 1259 OID 784376)
-- Name: idx_mv_artist_transition_features_target; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_features_target ON thesession.mv_artist_transition_features USING btree (target_tune_id);


--
-- TOC entry 4861 (class 1259 OID 784374)
-- Name: idx_mv_artist_transition_features_weighted; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_artist_transition_features_weighted ON thesession.mv_artist_transition_features USING btree (artist_name, weighted_score DESC);


--
-- TOC entry 4893 (class 1259 OID 807721)
-- Name: idx_mv_melody_2bar_fragment_ngrams_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_fragment ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (fragment_id);


--
-- TOC entry 4894 (class 1259 OID 807707)
-- Name: idx_mv_melody_2bar_fragment_ngrams_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_interval ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (interval_ngram);


--
-- TOC entry 4895 (class 1259 OID 807708)
-- Name: idx_mv_melody_2bar_fragment_ngrams_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_interval_rhythm ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (interval_ngram, rhythm_ngram);


--
-- TOC entry 4896 (class 1259 OID 807718)
-- Name: idx_mv_melody_2bar_fragment_ngrams_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_tune ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (tune_id);


--
-- TOC entry 4897 (class 1259 OID 807722)
-- Name: idx_mv_melody_2bar_fragment_ngrams_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_type_meter ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (type, meter);


--
-- TOC entry 4901 (class 1259 OID 859280)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_fragment ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (fragment_id);


--
-- TOC entry 4902 (class 1259 OID 859276)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_interval ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (interval_ngram);


--
-- TOC entry 4903 (class 1259 OID 859277)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_interval_rhythm ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (interval_ngram, rhythm_ngram);


--
-- TOC entry 4904 (class 1259 OID 859279)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_interval_rhythm_type_mete; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_interval_rhythm_type_mete ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (interval_ngram, rhythm_ngram, type, meter);


--
-- TOC entry 4905 (class 1259 OID 859278)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_interval_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_interval_type_meter ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (interval_ngram, type, meter);


--
-- TOC entry 4906 (class 1259 OID 859284)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v2_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v2_tune ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v2 USING btree (tune_id);


--
-- TOC entry 4907 (class 1259 OID 862117)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v3_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v3_fragment ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 USING btree (fragment_id);


--
-- TOC entry 4908 (class 1259 OID 862114)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v3_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v3_interval ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 USING btree (interval_ngram);


--
-- TOC entry 4909 (class 1259 OID 862115)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v3_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v3_interval_rhythm ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 USING btree (interval_ngram, rhythm_ngram);


--
-- TOC entry 4910 (class 1259 OID 862116)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v3_interval_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v3_interval_type_meter ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v3 USING btree (interval_ngram, type, meter);


--
-- TOC entry 4912 (class 1259 OID 863597)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_coarse; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_coarse ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (coarse_interval_ngram);


--
-- TOC entry 4913 (class 1259 OID 888799)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_coarse_pos; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_coarse_pos ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (coarse_interval_ngram, ngram_position);


--
-- TOC entry 4914 (class 1259 OID 863599)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_coarse_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_coarse_rhythm ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (coarse_interval_ngram, rhythm_ngram);


--
-- TOC entry 4915 (class 1259 OID 863600)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_fragment ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (fragment_id);


--
-- TOC entry 4916 (class 1259 OID 863596)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_interval ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (interval_ngram);


--
-- TOC entry 4917 (class 1259 OID 863598)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_interval_rhythm ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (interval_ngram, rhythm_ngram);


--
-- TOC entry 4918 (class 1259 OID 868310)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v4_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_melody_2bar_fragment_ngrams_v4_unique ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (fragment_id, ngram_position, interval_ngram, coarse_interval_ngram);


--
-- TOC entry 4934 (class 1259 OID 889708)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_coarse; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_coarse ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (coarse_interval_ngram);


--
-- TOC entry 4935 (class 1259 OID 889715)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_coarse_pos; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_coarse_pos ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (coarse_interval_ngram, ngram_position);


--
-- TOC entry 4936 (class 1259 OID 889710)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_coarse_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_coarse_rhythm ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (coarse_interval_ngram, rhythm_ngram);


--
-- TOC entry 4937 (class 1259 OID 889714)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_fragment ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (fragment_id);


--
-- TOC entry 4938 (class 1259 OID 889707)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_interval ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (interval_ngram);


--
-- TOC entry 4939 (class 1259 OID 889709)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_interval_rhythm ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (interval_ngram, rhythm_ngram);


--
-- TOC entry 4940 (class 1259 OID 889706)
-- Name: idx_mv_melody_2bar_fragment_ngrams_v5_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_melody_2bar_fragment_ngrams_v5_unique ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (fragment_id, ngram_position, interval_ngram, coarse_interval_ngram);


--
-- TOC entry 4888 (class 1259 OID 807415)
-- Name: idx_mv_melody_2bar_fragments_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_interval ON thesession.mv_melody_2bar_fragments_old USING btree (interval_fingerprint);


--
-- TOC entry 4889 (class 1259 OID 807416)
-- Name: idx_mv_melody_2bar_fragments_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_interval_rhythm ON thesession.mv_melody_2bar_fragments_old USING btree (interval_fingerprint, rhythm_fingerprint);


--
-- TOC entry 4890 (class 1259 OID 807417)
-- Name: idx_mv_melody_2bar_fragments_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_tune ON thesession.mv_melody_2bar_fragments_old USING btree (tune_id);


--
-- TOC entry 4891 (class 1259 OID 807418)
-- Name: idx_mv_melody_2bar_fragments_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_type_meter ON thesession.mv_melody_2bar_fragments_old USING btree (type, meter);


--
-- TOC entry 4929 (class 1259 OID 889532)
-- Name: idx_mv_melody_2bar_fragments_v5_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_v5_interval ON thesession.mv_melody_2bar_fragments_v5 USING btree (interval_fingerprint);


--
-- TOC entry 4930 (class 1259 OID 889534)
-- Name: idx_mv_melody_2bar_fragments_v5_interval_rhythm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_v5_interval_rhythm ON thesession.mv_melody_2bar_fragments_v5 USING btree (interval_fingerprint, rhythm_fingerprint);


--
-- TOC entry 4931 (class 1259 OID 889537)
-- Name: idx_mv_melody_2bar_fragments_v5_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_v5_tune ON thesession.mv_melody_2bar_fragments_v5 USING btree (tune_id);


--
-- TOC entry 4932 (class 1259 OID 889538)
-- Name: idx_mv_melody_2bar_fragments_v5_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_fragments_v5_type_meter ON thesession.mv_melody_2bar_fragments_v5 USING btree (type, meter);


--
-- TOC entry 4899 (class 1259 OID 807763)
-- Name: idx_mv_melody_2bar_ngram_stats_tune_count; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_tune_count ON thesession.mv_melody_2bar_ngram_stats_old USING btree (tune_count);


--
-- TOC entry 4911 (class 1259 OID 862118)
-- Name: idx_mv_melody_2bar_ngram_stats_v3_tune_count; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_v3_tune_count ON thesession.zz_old_mv_melody_2bar_ngram_stats_v3 USING btree (tune_count);


--
-- TOC entry 4923 (class 1259 OID 863602)
-- Name: idx_mv_melody_2bar_ngram_stats_v4_coarse; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_v4_coarse ON thesession.zz_old_mv_melody_2bar_ngram_stats_v4 USING btree (coarse_interval_ngram);


--
-- TOC entry 4924 (class 1259 OID 863601)
-- Name: idx_mv_melody_2bar_ngram_stats_v4_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_v4_interval ON thesession.zz_old_mv_melody_2bar_ngram_stats_v4 USING btree (interval_ngram);


--
-- TOC entry 4925 (class 1259 OID 868222)
-- Name: idx_mv_melody_2bar_ngram_stats_v4_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_melody_2bar_ngram_stats_v4_unique ON thesession.zz_old_mv_melody_2bar_ngram_stats_v4 USING btree (interval_ngram, coarse_interval_ngram);


--
-- TOC entry 4945 (class 1259 OID 889752)
-- Name: idx_mv_melody_2bar_ngram_stats_v5_coarse; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_v5_coarse ON thesession.mv_melody_2bar_ngram_stats_v5 USING btree (coarse_interval_ngram);


--
-- TOC entry 4946 (class 1259 OID 889751)
-- Name: idx_mv_melody_2bar_ngram_stats_v5_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_2bar_ngram_stats_v5_interval ON thesession.mv_melody_2bar_ngram_stats_v5 USING btree (interval_ngram);


--
-- TOC entry 4947 (class 1259 OID 889750)
-- Name: idx_mv_melody_2bar_ngram_stats_v5_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_melody_2bar_ngram_stats_v5_unique ON thesession.mv_melody_2bar_ngram_stats_v5 USING btree (interval_ngram, coarse_interval_ngram);


--
-- TOC entry 4919 (class 1259 OID 867579)
-- Name: idx_mv_melody_frag_v4_coarse_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v4_coarse_type ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (coarse_interval_ngram, type);


--
-- TOC entry 4920 (class 1259 OID 867574)
-- Name: idx_mv_melody_frag_v4_coarse_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v4_coarse_type_meter ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (coarse_interval_ngram, type, meter);


--
-- TOC entry 4921 (class 1259 OID 867578)
-- Name: idx_mv_melody_frag_v4_interval_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v4_interval_type ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (interval_ngram, type);


--
-- TOC entry 4922 (class 1259 OID 867570)
-- Name: idx_mv_melody_frag_v4_interval_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v4_interval_type_meter ON thesession.zz_old_mv_melody_2bar_fragment_ngrams_v4 USING btree (interval_ngram, type, meter);


--
-- TOC entry 4941 (class 1259 OID 889718)
-- Name: idx_mv_melody_frag_v5_coarse_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v5_coarse_type ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (coarse_interval_ngram, type);


--
-- TOC entry 4942 (class 1259 OID 889728)
-- Name: idx_mv_melody_frag_v5_coarse_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v5_coarse_type_meter ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (coarse_interval_ngram, type, meter);


--
-- TOC entry 4943 (class 1259 OID 889716)
-- Name: idx_mv_melody_frag_v5_interval_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v5_interval_type ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (interval_ngram, type);


--
-- TOC entry 4944 (class 1259 OID 889717)
-- Name: idx_mv_melody_frag_v5_interval_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_frag_v5_interval_type_meter ON thesession.mv_melody_2bar_fragment_ngrams_v5 USING btree (interval_ngram, type, meter);


--
-- TOC entry 4884 (class 1259 OID 807376)
-- Name: idx_mv_melody_setting_bars_setting_bar; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_setting_bars_setting_bar ON thesession.mv_melody_setting_bars USING btree (setting_id, bar_number);


--
-- TOC entry 4885 (class 1259 OID 880756)
-- Name: idx_mv_melody_setting_bars_setting_bar_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_melody_setting_bars_setting_bar_uidx ON thesession.mv_melody_setting_bars USING btree (setting_id, bar_number);


--
-- TOC entry 4886 (class 1259 OID 807377)
-- Name: idx_mv_melody_setting_bars_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_setting_bars_tune ON thesession.mv_melody_setting_bars USING btree (tune_id);


--
-- TOC entry 4887 (class 1259 OID 807378)
-- Name: idx_mv_melody_setting_bars_type_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_melody_setting_bars_type_meter ON thesession.mv_melody_setting_bars USING btree (type, meter);


--
-- TOC entry 4812 (class 1259 OID 591901)
-- Name: idx_mv_member_search_member_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_member_search_member_id ON thesession.mv_member_search USING btree (member_id);


--
-- TOC entry 4813 (class 1259 OID 591902)
-- Name: idx_mv_member_search_username_lc; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_member_search_username_lc ON thesession.mv_member_search USING btree (username_lc);


--
-- TOC entry 4814 (class 1259 OID 591903)
-- Name: idx_mv_member_search_username_trgm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_member_search_username_trgm ON thesession.mv_member_search USING gin (username_lc public.gin_trgm_ops);


--
-- TOC entry 4879 (class 1259 OID 800347)
-- Name: idx_mv_recording_set_search_artist; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_recording_set_search_artist ON thesession.mv_recording_set_search USING btree (artist_name);


--
-- TOC entry 4880 (class 1259 OID 800348)
-- Name: idx_mv_recording_set_search_distinct_tune_ids; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_recording_set_search_distinct_tune_ids ON thesession.mv_recording_set_search USING gin (distinct_tune_ids);


--
-- TOC entry 4881 (class 1259 OID 800349)
-- Name: idx_mv_recording_set_search_ordered_signature; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_recording_set_search_ordered_signature ON thesession.mv_recording_set_search USING btree (ordered_signature);


--
-- TOC entry 4882 (class 1259 OID 800350)
-- Name: idx_mv_recording_set_search_unordered_signature; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_recording_set_search_unordered_signature ON thesession.mv_recording_set_search USING btree (unordered_signature);


--
-- TOC entry 4870 (class 1259 OID 796953)
-- Name: idx_mv_setting_bookmarkers_owner; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_setting_bookmarkers_owner ON thesession.mv_setting_bookmarkers USING btree (setting_owner_member_id, bookmarked_at DESC, setting_id, bookmarker_member_id);


--
-- TOC entry 4875 (class 1259 OID 799921)
-- Name: idx_mv_transition_artist_overlap_artist_a; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_transition_artist_overlap_artist_a ON thesession.mv_transition_artist_overlap USING btree (artist_a);


--
-- TOC entry 4876 (class 1259 OID 799922)
-- Name: idx_mv_transition_artist_overlap_artist_b; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_transition_artist_overlap_artist_b ON thesession.mv_transition_artist_overlap USING btree (artist_b);


--
-- TOC entry 4877 (class 1259 OID 799923)
-- Name: idx_mv_transition_artist_overlap_transition; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_transition_artist_overlap_transition ON thesession.mv_transition_artist_overlap USING btree (source_tune_id, target_tune_id);


--
-- TOC entry 4991 (class 1259 OID 1117028)
-- Name: idx_mv_tune_analytics_slug; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_slug ON thesession.mv_tune_analytics USING btree (slug);


--
-- TOC entry 4992 (class 1259 OID 1117022)
-- Name: idx_mv_tune_analytics_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_tune_analytics_tune_id ON thesession.mv_tune_analytics USING btree (tune_id);


--
-- TOC entry 4993 (class 1259 OID 1117023)
-- Name: idx_mv_tune_analytics_type_hidden_gem; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_type_hidden_gem ON thesession.mv_tune_analytics USING btree (type, hidden_gem_score DESC);


--
-- TOC entry 4994 (class 1259 OID 1117027)
-- Name: idx_mv_tune_analytics_type_influence; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_type_influence ON thesession.mv_tune_analytics USING btree (type, influential_score DESC);


--
-- TOC entry 4995 (class 1259 OID 1117025)
-- Name: idx_mv_tune_analytics_type_recording; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_type_recording ON thesession.mv_tune_analytics USING btree (type, recording_count DESC);


--
-- TOC entry 4996 (class 1259 OID 1117026)
-- Name: idx_mv_tune_analytics_type_session; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_type_session ON thesession.mv_tune_analytics USING btree (type, session_signal DESC);


--
-- TOC entry 4997 (class 1259 OID 1117024)
-- Name: idx_mv_tune_analytics_type_tier_score; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_analytics_type_tier_score ON thesession.mv_tune_analytics USING btree (type, hidden_gem_tier, hidden_gem_score DESC);


--
-- TOC entry 4986 (class 1259 OID 1116997)
-- Name: idx_mv_tune_hidden_gem_features_evidence; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_hidden_gem_features_evidence ON thesession.mv_tune_hidden_gem_features USING btree (evidence_level, hidden_gem_score DESC);


--
-- TOC entry 4987 (class 1259 OID 1116995)
-- Name: idx_mv_tune_hidden_gem_features_tier_score; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_hidden_gem_features_tier_score ON thesession.mv_tune_hidden_gem_features USING btree (hidden_gem_tier, hidden_gem_score DESC);


--
-- TOC entry 4988 (class 1259 OID 1116993)
-- Name: idx_mv_tune_hidden_gem_features_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_tune_hidden_gem_features_tune_id ON thesession.mv_tune_hidden_gem_features USING btree (tune_id);


--
-- TOC entry 4989 (class 1259 OID 1116994)
-- Name: idx_mv_tune_hidden_gem_features_type_score; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_hidden_gem_features_type_score ON thesession.mv_tune_hidden_gem_features USING btree (type, hidden_gem_score DESC);


--
-- TOC entry 4990 (class 1259 OID 1116996)
-- Name: idx_mv_tune_hidden_gem_features_type_tier_score; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_hidden_gem_features_type_tier_score ON thesession.mv_tune_hidden_gem_features USING btree (type, hidden_gem_tier, hidden_gem_score DESC);


--
-- TOC entry 4815 (class 1259 OID 606481)
-- Name: idx_mv_tune_meta_has_recordings; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_has_recordings ON thesession.mv_tune_meta USING btree (has_recording_albums) WHERE (has_recording_albums = true);


--
-- TOC entry 4816 (class 1259 OID 606480)
-- Name: idx_mv_tune_meta_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_mode ON thesession.mv_tune_meta USING btree (mode);


--
-- TOC entry 4817 (class 1259 OID 606477)
-- Name: idx_mv_tune_meta_star_rating; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_star_rating ON thesession.mv_tune_meta USING btree (star_rating DESC);


--
-- TOC entry 4818 (class 1259 OID 606476)
-- Name: idx_mv_tune_meta_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_tune_meta_tune_id ON thesession.mv_tune_meta USING btree (tune_id);


--
-- TOC entry 4819 (class 1259 OID 606478)
-- Name: idx_mv_tune_meta_tunebooks; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_tunebooks ON thesession.mv_tune_meta USING btree (tunebooks DESC);


--
-- TOC entry 4820 (class 1259 OID 606479)
-- Name: idx_mv_tune_meta_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_type ON thesession.mv_tune_meta USING btree (type);


--
-- TOC entry 4821 (class 1259 OID 606484)
-- Name: idx_mv_tune_meta_type_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_meta_type_mode ON thesession.mv_tune_meta USING btree (type, mode);


--
-- TOC entry 4926 (class 1259 OID 881687)
-- Name: idx_mv_tune_name_search_search_lc; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_name_search_search_lc ON thesession.mv_tune_name_search USING btree (lower(search_name));


--
-- TOC entry 4927 (class 1259 OID 881688)
-- Name: idx_mv_tune_name_search_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_name_search_tune_id ON thesession.mv_tune_name_search USING btree (tune_id);


--
-- TOC entry 4789 (class 1259 OID 513112)
-- Name: idx_mv_tune_transition_evidence_pair; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_transition_evidence_pair ON thesession.mv_tune_transition_evidence USING btree (source_tune_id, target_tune_id);


--
-- TOC entry 4790 (class 1259 OID 513113)
-- Name: idx_mv_tune_transition_evidence_pair_artist; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_transition_evidence_pair_artist ON thesession.mv_tune_transition_evidence USING btree (source_tune_id, target_tune_id, artist_name);


--
-- TOC entry 4791 (class 1259 OID 513114)
-- Name: idx_mv_tune_transition_evidence_pair_recording; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_transition_evidence_pair_recording ON thesession.mv_tune_transition_evidence USING btree (source_tune_id, target_tune_id, recording_id);


--
-- TOC entry 4792 (class 1259 OID 513115)
-- Name: idx_mv_tune_transition_evidence_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX idx_mv_tune_transition_evidence_uq ON thesession.mv_tune_transition_evidence USING btree (source_tune_id, target_tune_id, recording_id, track, source_tune_number, target_tune_number);


--
-- TOC entry 4760 (class 1259 OID 440801)
-- Name: idx_mv_tune_transitions_source_rank; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_transitions_source_rank ON thesession.mv_tune_transitions USING btree (source_tune, transition_rank);


--
-- TOC entry 4761 (class 1259 OID 440802)
-- Name: idx_mv_tune_transitions_source_target; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_mv_tune_transitions_source_target ON thesession.mv_tune_transitions USING btree (source_tune, target_tune);


--
-- TOC entry 4848 (class 1259 OID 690252)
-- Name: idx_session_activity_raw_actor_member; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_actor_member ON thesession.session_activity_raw USING btree (actor_member_id);


--
-- TOC entry 4849 (class 1259 OID 690250)
-- Name: idx_session_activity_raw_object_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_object_type ON thesession.session_activity_raw USING btree (object_type);


--
-- TOC entry 4850 (class 1259 OID 690248)
-- Name: idx_session_activity_raw_processed; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_processed ON thesession.session_activity_raw USING btree (processed, published_at);


--
-- TOC entry 4851 (class 1259 OID 690247)
-- Name: idx_session_activity_raw_published; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_published ON thesession.session_activity_raw USING btree (published_at DESC);


--
-- TOC entry 4852 (class 1259 OID 690251)
-- Name: idx_session_activity_raw_target_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_target_type ON thesession.session_activity_raw USING btree (target_type);


--
-- TOC entry 4853 (class 1259 OID 690434)
-- Name: idx_session_activity_raw_tunebook_posts; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_tunebook_posts ON thesession.session_activity_raw USING btree (published_at DESC) WHERE ((stream = 'tunes'::text) AND (processed = false) AND (verb = 'post'::text) AND (object_type = 'tune'::text) AND (target_type = 'tunebook'::text));


--
-- TOC entry 4854 (class 1259 OID 690433)
-- Name: idx_session_activity_raw_unprocessed_tunes; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_unprocessed_tunes ON thesession.session_activity_raw USING btree (published_at DESC) WHERE ((stream = 'tunes'::text) AND (processed = false));


--
-- TOC entry 4855 (class 1259 OID 690249)
-- Name: idx_session_activity_raw_verb; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_activity_raw_verb ON thesession.session_activity_raw USING btree (verb);


--
-- TOC entry 4770 (class 1259 OID 684154)
-- Name: idx_session_member_bookmarks_scraped; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_bookmarks_scraped ON thesession.session_member USING btree (bookmarks_scraped);


--
-- TOC entry 4771 (class 1259 OID 436198)
-- Name: idx_session_member_location; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_location ON thesession.session_member USING btree (latitude, longitude);


--
-- TOC entry 4772 (class 1259 OID 436196)
-- Name: idx_session_member_name; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_name ON thesession.session_member USING btree (name);


--
-- TOC entry 4773 (class 1259 OID 483212)
-- Name: idx_session_member_name_lower_like; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_name_lower_like ON thesession.session_member USING btree (lower(name) text_pattern_ops);


--
-- TOC entry 4774 (class 1259 OID 483220)
-- Name: idx_session_member_name_trgm; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_name_trgm ON thesession.session_member USING gin (lower(name) public.gin_trgm_ops);


--
-- TOC entry 4775 (class 1259 OID 436197)
-- Name: idx_session_member_sets; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_sets ON thesession.session_member USING btree (sets_count);


--
-- TOC entry 4806 (class 1259 OID 589127)
-- Name: idx_session_member_tunebook_fetched_at; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_tunebook_fetched_at ON thesession.session_member_tunebook USING btree (fetched_at);


--
-- TOC entry 4807 (class 1259 OID 621390)
-- Name: idx_session_member_tunebook_member_added_sort; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_tunebook_member_added_sort ON thesession.session_member_tunebook USING btree (member_id, COALESCE(added_at, tune_date) DESC, tune_id);


--
-- TOC entry 4808 (class 1259 OID 589126)
-- Name: idx_session_member_tunebook_member_page; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_tunebook_member_page ON thesession.session_member_tunebook USING btree (member_id, source_page);


--
-- TOC entry 4809 (class 1259 OID 589124)
-- Name: idx_session_member_tunebook_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_member_tunebook_tune_id ON thesession.session_member_tunebook USING btree (tune_id);


--
-- TOC entry 4665 (class 1259 OID 290793)
-- Name: idx_session_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_meter ON thesession.session_tunes_raw USING btree (meter);


--
-- TOC entry 4666 (class 1259 OID 290794)
-- Name: idx_session_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_mode ON thesession.session_tunes_raw USING btree (mode);


--
-- TOC entry 4753 (class 1259 OID 401363)
-- Name: idx_session_recording_artist; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_recording_artist ON thesession.session_recording USING btree (artist_id);


--
-- TOC entry 4754 (class 1259 OID 401362)
-- Name: idx_session_recording_recording; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_recording_recording ON thesession.session_recording USING btree (id);


--
-- TOC entry 4755 (class 1259 OID 403549)
-- Name: idx_session_recording_transition_not_null; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_recording_transition_not_null ON thesession.session_recording USING btree (id, track, tune_number, tune_id) WHERE (tune_id IS NOT NULL);


--
-- TOC entry 4756 (class 1259 OID 401361)
-- Name: idx_session_recording_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_recording_tune ON thesession.session_recording USING btree (tune_id);


--
-- TOC entry 4757 (class 1259 OID 401579)
-- Name: idx_session_recording_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_recording_tune_id ON thesession.session_recording USING btree (tune_id);


--
-- TOC entry 4697 (class 1259 OID 292946)
-- Name: idx_session_set_items_raw_order1; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_order1 ON thesession.session_set_items_raw USING btree (settingorder, name);


--
-- TOC entry 4698 (class 1259 OID 292947)
-- Name: idx_session_set_items_raw_order1_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_order1_tune ON thesession.session_set_items_raw USING btree (settingorder, tune_id);


--
-- TOC entry 4699 (class 1259 OID 292944)
-- Name: idx_session_set_items_raw_setting_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_setting_id ON thesession.session_set_items_raw USING btree (setting_id);


--
-- TOC entry 4700 (class 1259 OID 292943)
-- Name: idx_session_set_items_raw_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_tune_id ON thesession.session_set_items_raw USING btree (tune_id);


--
-- TOC entry 4701 (class 1259 OID 292945)
-- Name: idx_session_set_items_raw_tune_sets; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_tune_sets ON thesession.session_set_items_raw USING btree (tune_id, tuneset);


--
-- TOC entry 4702 (class 1259 OID 628155)
-- Name: idx_session_set_items_raw_tuneset; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_tuneset ON thesession.session_set_items_raw USING btree (tuneset);


--
-- TOC entry 4703 (class 1259 OID 292948)
-- Name: idx_session_set_items_raw_tuneset_order; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_raw_tuneset_order ON thesession.session_set_items_raw USING btree (tuneset, settingorder);


--
-- TOC entry 4704 (class 1259 OID 339900)
-- Name: idx_session_set_items_slug; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_set_items_slug ON thesession.session_set_items_raw USING btree (slug);


--
-- TOC entry 4686 (class 1259 OID 292940)
-- Name: idx_session_sets_raw_date; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_sets_raw_date ON thesession.session_sets_raw USING btree (date);


--
-- TOC entry 4687 (class 1259 OID 628156)
-- Name: idx_session_sets_raw_date_member; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_sets_raw_date_member ON thesession.session_sets_raw USING btree (date, member_id);


--
-- TOC entry 4688 (class 1259 OID 292941)
-- Name: idx_session_sets_raw_member_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_sets_raw_member_id ON thesession.session_sets_raw USING btree (member_id);


--
-- TOC entry 4689 (class 1259 OID 292942)
-- Name: idx_session_sets_raw_username; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_sets_raw_username ON thesession.session_sets_raw USING btree (username);


--
-- TOC entry 4667 (class 1259 OID 290795)
-- Name: idx_session_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tune ON thesession.session_tunes_raw USING btree (tune_id);


--
-- TOC entry 4682 (class 1259 OID 339899)
-- Name: idx_session_tune_popularity_slug; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tune_popularity_slug ON thesession.session_tune_popularity_raw USING btree (slug);


--
-- TOC entry 4683 (class 1259 OID 292939)
-- Name: idx_session_tune_popularity_tunebooks; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tune_popularity_tunebooks ON thesession.session_tune_popularity_raw USING btree (tunebooks DESC);


--
-- TOC entry 4668 (class 1259 OID 292937)
-- Name: idx_session_tunes_raw_date; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_date ON thesession.session_tunes_raw USING btree (date);


--
-- TOC entry 4669 (class 1259 OID 292936)
-- Name: idx_session_tunes_raw_meter; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_meter ON thesession.session_tunes_raw USING btree (meter);


--
-- TOC entry 4670 (class 1259 OID 292935)
-- Name: idx_session_tunes_raw_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_mode ON thesession.session_tunes_raw USING btree (mode);


--
-- TOC entry 4671 (class 1259 OID 690814)
-- Name: idx_session_tunes_raw_setting_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_setting_id ON thesession.session_tunes_raw USING btree (setting_id);


--
-- TOC entry 4672 (class 1259 OID 339909)
-- Name: idx_session_tunes_raw_slug; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_slug ON thesession.session_tunes_raw USING btree (slug);


--
-- TOC entry 4673 (class 1259 OID 292933)
-- Name: idx_session_tunes_raw_tune_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_tune_id ON thesession.session_tunes_raw USING btree (tune_id);


--
-- TOC entry 4674 (class 1259 OID 412597)
-- Name: idx_session_tunes_raw_tune_setting; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_tune_setting ON thesession.session_tunes_raw USING btree (tune_id, setting_id);


--
-- TOC entry 4675 (class 1259 OID 292934)
-- Name: idx_session_tunes_raw_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_type ON thesession.session_tunes_raw USING btree (type);


--
-- TOC entry 4676 (class 1259 OID 292938)
-- Name: idx_session_tunes_raw_type_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_type_mode ON thesession.session_tunes_raw USING btree (type, mode);


--
-- TOC entry 4677 (class 1259 OID 678855)
-- Name: idx_session_tunes_raw_username; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_username ON thesession.session_tunes_raw USING btree (username);


--
-- TOC entry 4678 (class 1259 OID 678858)
-- Name: idx_session_tunes_raw_username_lower; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_tunes_raw_username_lower ON thesession.session_tunes_raw USING btree (lower(username));


--
-- TOC entry 4679 (class 1259 OID 290792)
-- Name: idx_session_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_session_type ON thesession.session_tunes_raw USING btree (type);


--
-- TOC entry 4841 (class 1259 OID 690815)
-- Name: idx_smbs_setting_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_smbs_setting_id ON thesession.session_member_bookmark_setting USING btree (setting_id);


--
-- TOC entry 4842 (class 1259 OID 684032)
-- Name: idx_sms_bookmarked_at; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_sms_bookmarked_at ON thesession.session_member_bookmark_setting USING btree (bookmarked_at DESC);


--
-- TOC entry 4843 (class 1259 OID 684029)
-- Name: idx_sms_member; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_sms_member ON thesession.session_member_bookmark_setting USING btree (member_id);


--
-- TOC entry 4844 (class 1259 OID 684030)
-- Name: idx_sms_setting; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_sms_setting ON thesession.session_member_bookmark_setting USING btree (setting_id);


--
-- TOC entry 4845 (class 1259 OID 684031)
-- Name: idx_sms_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_sms_tune ON thesession.session_member_bookmark_setting USING btree (tune_id);


--
-- TOC entry 4747 (class 1259 OID 493020)
-- Name: idx_tune_collection_item_collection_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_tune_collection_item_collection_id ON thesession.tune_collection_item USING btree (collection_id);


--
-- TOC entry 4748 (class 1259 OID 400021)
-- Name: idx_tune_collection_item_collection_position; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_tune_collection_item_collection_position ON thesession.tune_collection_item USING btree (collection_id, "position");


--
-- TOC entry 4738 (class 1259 OID 399775)
-- Name: idx_tune_collection_slug; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX idx_tune_collection_slug ON thesession.tune_collection USING btree (slug);


--
-- TOC entry 4822 (class 1259 OID 605371)
-- Name: ix_mv_mode_set_transitions_source_family; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_mode_set_transitions_source_family ON thesession.mv_mode_set_transitions USING btree (source_mode_family);


--
-- TOC entry 4823 (class 1259 OID 605372)
-- Name: ix_mv_mode_set_transitions_source_family_label; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_mode_set_transitions_source_family_label ON thesession.mv_mode_set_transitions USING btree (source_mode_family, source_mode_label);


--
-- TOC entry 4824 (class 1259 OID 605373)
-- Name: ix_mv_mode_set_transitions_source_label; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_mode_set_transitions_source_label ON thesession.mv_mode_set_transitions USING btree (source_mode_label);


--
-- TOC entry 4825 (class 1259 OID 605374)
-- Name: ix_mv_mode_set_transitions_source_pct; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_mode_set_transitions_source_pct ON thesession.mv_mode_set_transitions USING btree (source_mode_label, transition_pct DESC);


--
-- TOC entry 4826 (class 1259 OID 605375)
-- Name: ix_mv_mode_set_transitions_source_rank; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_mode_set_transitions_source_rank ON thesession.mv_mode_set_transitions USING btree (source_mode_label, transition_rank);


--
-- TOC entry 4828 (class 1259 OID 606418)
-- Name: ix_mv_set_search_date; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_date ON thesession.mv_set_search USING btree (date);


--
-- TOC entry 4829 (class 1259 OID 606419)
-- Name: ix_mv_set_search_first_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_first_mode ON thesession.mv_set_search USING btree (first_mode);


--
-- TOC entry 4830 (class 1259 OID 606420)
-- Name: ix_mv_set_search_first_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_first_type ON thesession.mv_set_search USING btree (first_type);


--
-- TOC entry 4831 (class 1259 OID 606421)
-- Name: ix_mv_set_search_is_repeated; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_is_repeated ON thesession.mv_set_search USING btree (is_repeated);


--
-- TOC entry 4832 (class 1259 OID 606422)
-- Name: ix_mv_set_search_last_mode; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_last_mode ON thesession.mv_set_search USING btree (last_mode);


--
-- TOC entry 4833 (class 1259 OID 606423)
-- Name: ix_mv_set_search_last_type; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_last_type ON thesession.mv_set_search USING btree (last_type);


--
-- TOC entry 4834 (class 1259 OID 621334)
-- Name: ix_mv_set_search_member_date; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_member_date ON thesession.mv_set_search USING btree (member_id, date DESC, tuneset DESC);


--
-- TOC entry 4835 (class 1259 OID 621335)
-- Name: ix_mv_set_search_member_date_multitune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_member_date_multitune ON thesession.mv_set_search USING btree (member_id, date DESC, tuneset DESC) WHERE (jsonb_array_length(COALESCE(tune_ids_json, '[]'::jsonb)) > 1);


--
-- TOC entry 4836 (class 1259 OID 606424)
-- Name: ix_mv_set_search_member_id; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_member_id ON thesession.mv_set_search USING btree (member_id);


--
-- TOC entry 4837 (class 1259 OID 621336)
-- Name: ix_mv_set_search_member_signature; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_member_signature ON thesession.mv_set_search USING btree (member_id, signature);


--
-- TOC entry 4838 (class 1259 OID 606425)
-- Name: ix_mv_set_search_tune_count; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_tune_count ON thesession.mv_set_search USING btree (tune_count);


--
-- TOC entry 4839 (class 1259 OID 606426)
-- Name: ix_mv_set_search_username; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX ix_mv_set_search_username ON thesession.mv_set_search USING btree (username);


--
-- TOC entry 4793 (class 1259 OID 532937)
-- Name: mv_collection_overlap_c1_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_collection_overlap_c1_idx ON thesession.mv_collection_overlap USING btree (collection_id_1, shared_tune_count DESC);


--
-- TOC entry 4794 (class 1259 OID 532938)
-- Name: mv_collection_overlap_c2_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_collection_overlap_c2_idx ON thesession.mv_collection_overlap USING btree (collection_id_2, shared_tune_count DESC);


--
-- TOC entry 4795 (class 1259 OID 532936)
-- Name: mv_collection_overlap_pair_uk; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_collection_overlap_pair_uk ON thesession.mv_collection_overlap USING btree (collection_id_1, collection_id_2);


--
-- TOC entry 4972 (class 1259 OID 944414)
-- Name: mv_country_similarity_adjusted_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_similarity_adjusted_idx ON thesession.mv_country_similarity USING btree (adjusted_similarity DESC);


--
-- TOC entry 4973 (class 1259 OID 944415)
-- Name: mv_country_similarity_cosine_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_similarity_cosine_idx ON thesession.mv_country_similarity USING btree (cosine_similarity DESC);


--
-- TOC entry 4974 (class 1259 OID 944412)
-- Name: mv_country_similarity_country_a_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_similarity_country_a_idx ON thesession.mv_country_similarity USING btree (country_a);


--
-- TOC entry 4975 (class 1259 OID 944413)
-- Name: mv_country_similarity_country_b_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_similarity_country_b_idx ON thesession.mv_country_similarity USING btree (country_b);


--
-- TOC entry 4976 (class 1259 OID 944411)
-- Name: mv_country_similarity_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_country_similarity_uidx ON thesession.mv_country_similarity USING btree (country_a, country_b);


--
-- TOC entry 4958 (class 1259 OID 944342)
-- Name: mv_country_tune_popularity_country_count_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_count_idx ON thesession.mv_country_tune_popularity USING btree (country_code, country_tunebook_count DESC);


--
-- TOC entry 4959 (class 1259 OID 944341)
-- Name: mv_country_tune_popularity_country_lift_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_lift_idx ON thesession.mv_country_tune_popularity USING btree (country_code, lift_score DESC);


--
-- TOC entry 4960 (class 1259 OID 944343)
-- Name: mv_country_tune_popularity_country_member_count_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_member_count_idx ON thesession.mv_country_tune_popularity USING btree (country_code, country_member_count DESC);


--
-- TOC entry 4961 (class 1259 OID 944349)
-- Name: mv_country_tune_popularity_country_meter_score_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_meter_score_idx ON thesession.mv_country_tune_popularity USING btree (country_code, meter, weighted_country_score DESC);


--
-- TOC entry 4962 (class 1259 OID 944350)
-- Name: mv_country_tune_popularity_country_mode_score_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_mode_score_idx ON thesession.mv_country_tune_popularity USING btree (country_code, mode, weighted_country_score DESC);


--
-- TOC entry 4963 (class 1259 OID 944352)
-- Name: mv_country_tune_popularity_country_name_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_name_idx ON thesession.mv_country_tune_popularity USING btree (country_name);


--
-- TOC entry 4964 (class 1259 OID 944340)
-- Name: mv_country_tune_popularity_country_score_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_score_idx ON thesession.mv_country_tune_popularity USING btree (country_code, weighted_country_score DESC);


--
-- TOC entry 4965 (class 1259 OID 944348)
-- Name: mv_country_tune_popularity_country_type_score_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_country_type_score_idx ON thesession.mv_country_tune_popularity USING btree (country_code, type, weighted_country_score DESC);


--
-- TOC entry 4966 (class 1259 OID 944346)
-- Name: mv_country_tune_popularity_meter_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_meter_idx ON thesession.mv_country_tune_popularity USING btree (country_code, meter);


--
-- TOC entry 4967 (class 1259 OID 944347)
-- Name: mv_country_tune_popularity_mode_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_mode_idx ON thesession.mv_country_tune_popularity USING btree (country_code, mode);


--
-- TOC entry 4968 (class 1259 OID 944351)
-- Name: mv_country_tune_popularity_name_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_name_idx ON thesession.mv_country_tune_popularity USING gin (to_tsvector('simple'::regconfig, tune_name));


--
-- TOC entry 4969 (class 1259 OID 944344)
-- Name: mv_country_tune_popularity_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_tune_idx ON thesession.mv_country_tune_popularity USING btree (tune_id);


--
-- TOC entry 4970 (class 1259 OID 944345)
-- Name: mv_country_tune_popularity_type_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_popularity_type_idx ON thesession.mv_country_tune_popularity USING btree (country_code, type);


--
-- TOC entry 4971 (class 1259 OID 944339)
-- Name: mv_country_tune_popularity_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_country_tune_popularity_uidx ON thesession.mv_country_tune_popularity USING btree (country_code, tune_id);


--
-- TOC entry 4982 (class 1259 OID 951640)
-- Name: mv_country_tune_signal_popularity_country_count_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_signal_popularity_country_count_idx ON thesession.mv_country_tune_signal_popularity USING btree (country_name, country_signal_count DESC);


--
-- TOC entry 4983 (class 1259 OID 951639)
-- Name: mv_country_tune_signal_popularity_country_score_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_signal_popularity_country_score_idx ON thesession.mv_country_tune_signal_popularity USING btree (country_name, weighted_country_score DESC);


--
-- TOC entry 4984 (class 1259 OID 951641)
-- Name: mv_country_tune_signal_popularity_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_country_tune_signal_popularity_tune_idx ON thesession.mv_country_tune_signal_popularity USING btree (tune_id);


--
-- TOC entry 4985 (class 1259 OID 951638)
-- Name: mv_country_tune_signal_popularity_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_country_tune_signal_popularity_uidx ON thesession.mv_country_tune_signal_popularity USING btree (country_code, tune_id);


--
-- TOC entry 4783 (class 1259 OID 482426)
-- Name: mv_member_set_activity_member_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_set_activity_member_idx ON thesession.mv_member_set_activity USING btree (member_id, period_type);


--
-- TOC entry 4784 (class 1259 OID 482437)
-- Name: mv_member_set_activity_member_period_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_set_activity_member_period_idx ON thesession.mv_member_set_activity USING btree (member_id, period_type);


--
-- TOC entry 4785 (class 1259 OID 482425)
-- Name: mv_member_set_activity_period_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_set_activity_period_idx ON thesession.mv_member_set_activity USING btree (period_type, period_start);


--
-- TOC entry 4786 (class 1259 OID 482424)
-- Name: mv_member_set_activity_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_member_set_activity_uq ON thesession.mv_member_set_activity USING btree (member_id, period_type, period_start);


--
-- TOC entry 4787 (class 1259 OID 482435)
-- Name: mv_member_set_summary_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_member_set_summary_uq ON thesession.mv_member_set_summary USING btree (member_id);


--
-- TOC entry 4788 (class 1259 OID 482436)
-- Name: mv_member_set_summary_username_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_set_summary_username_idx ON thesession.mv_member_set_summary USING btree (lower(username));


--
-- TOC entry 4977 (class 1259 OID 951617)
-- Name: mv_member_tune_signal_member_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_tune_signal_member_idx ON thesession.mv_member_tune_signal USING btree (member_id);


--
-- TOC entry 4978 (class 1259 OID 951620)
-- Name: mv_member_tune_signal_member_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_tune_signal_member_tune_idx ON thesession.mv_member_tune_signal USING btree (member_id, tune_id);


--
-- TOC entry 4979 (class 1259 OID 951618)
-- Name: mv_member_tune_signal_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_tune_signal_tune_idx ON thesession.mv_member_tune_signal USING btree (tune_id);


--
-- TOC entry 4980 (class 1259 OID 951621)
-- Name: mv_member_tune_signal_tune_member_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_tune_signal_tune_member_idx ON thesession.mv_member_tune_signal USING btree (tune_id, member_id);


--
-- TOC entry 4981 (class 1259 OID 951619)
-- Name: mv_member_tune_signal_type_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_member_tune_signal_type_idx ON thesession.mv_member_tune_signal USING btree (signal_type);


--
-- TOC entry 4948 (class 1259 OID 919588)
-- Name: mv_static_recording_pages_recording_id_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_static_recording_pages_recording_id_uidx ON thesession.mv_static_recording_pages USING btree (recording_id);


--
-- TOC entry 4949 (class 1259 OID 919589)
-- Name: mv_static_recording_pages_slug_uidx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_static_recording_pages_slug_uidx ON thesession.mv_static_recording_pages USING btree (slug);


--
-- TOC entry 4766 (class 1259 OID 401928)
-- Name: mv_tune_names_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_tune_names_uq ON thesession.mv_tune_names USING btree (tune_id);


--
-- TOC entry 4796 (class 1259 OID 540009)
-- Name: mv_tune_recording_artists_artist_key_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_artists_artist_key_idx ON thesession.mv_tune_recording_artists USING btree (artist_key);


--
-- TOC entry 4797 (class 1259 OID 540008)
-- Name: mv_tune_recording_artists_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_artists_tune_idx ON thesession.mv_tune_recording_artists USING btree (tune_id);


--
-- TOC entry 4798 (class 1259 OID 540082)
-- Name: mv_tune_recording_artists_tune_recording_count_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_artists_tune_recording_count_idx ON thesession.mv_tune_recording_artists USING btree (tune_id, recording_count DESC);


--
-- TOC entry 4799 (class 1259 OID 540007)
-- Name: mv_tune_recording_artists_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_tune_recording_artists_uq ON thesession.mv_tune_recording_artists USING btree (tune_id, artist_key);


--
-- TOC entry 4800 (class 1259 OID 540086)
-- Name: mv_tune_recording_detail_recording_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_detail_recording_idx ON thesession.mv_tune_recording_detail USING btree (recording_id);


--
-- TOC entry 4801 (class 1259 OID 540085)
-- Name: mv_tune_recording_detail_tune_artist_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_detail_tune_artist_idx ON thesession.mv_tune_recording_detail USING btree (tune_id, artist_name);


--
-- TOC entry 4802 (class 1259 OID 540084)
-- Name: mv_tune_recording_detail_tune_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_recording_detail_tune_idx ON thesession.mv_tune_recording_detail USING btree (tune_id);


--
-- TOC entry 4803 (class 1259 OID 540083)
-- Name: mv_tune_recording_detail_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_tune_recording_detail_uq ON thesession.mv_tune_recording_detail USING btree (tune_id, recording_id, track, tune_number);


--
-- TOC entry 4767 (class 1259 OID 403721)
-- Name: mv_tune_set_transitions_source_rank_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_set_transitions_source_rank_idx ON thesession.mv_tune_set_transitions USING btree (source_tune, transition_rank);


--
-- TOC entry 4768 (class 1259 OID 403722)
-- Name: mv_tune_set_transitions_target_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_set_transitions_target_idx ON thesession.mv_tune_set_transitions USING btree (target_tune);


--
-- TOC entry 4769 (class 1259 OID 403720)
-- Name: mv_tune_set_transitions_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_tune_set_transitions_uq ON thesession.mv_tune_set_transitions USING btree (source_tune, target_tune);


--
-- TOC entry 4762 (class 1259 OID 401915)
-- Name: mv_tune_transitions_source_count_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_transitions_source_count_idx ON thesession.mv_tune_transitions USING btree (source_tune, transition_count DESC);


--
-- TOC entry 4763 (class 1259 OID 401914)
-- Name: mv_tune_transitions_source_rank_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_transitions_source_rank_idx ON thesession.mv_tune_transitions USING btree (source_tune, transition_rank);


--
-- TOC entry 4764 (class 1259 OID 401916)
-- Name: mv_tune_transitions_target_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX mv_tune_transitions_target_idx ON thesession.mv_tune_transitions USING btree (target_tune);


--
-- TOC entry 4765 (class 1259 OID 401913)
-- Name: mv_tune_transitions_uq; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX mv_tune_transitions_uq ON thesession.mv_tune_transitions USING btree (source_tune, target_tune);


--
-- TOC entry 4950 (class 1259 OID 944230)
-- Name: naturalearth_countries_geom_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX naturalearth_countries_geom_idx ON thesession.naturalearth_countries USING gist (geom);


--
-- TOC entry 4707 (class 1259 OID 340014)
-- Name: session_event_area_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_area_idx ON thesession.session_event USING btree (area);


--
-- TOC entry 4708 (class 1259 OID 340013)
-- Name: session_event_country_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_country_idx ON thesession.session_event USING btree (country);


--
-- TOC entry 4709 (class 1259 OID 340017)
-- Name: session_event_dt_start_future_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_dt_start_future_idx ON thesession.session_event USING btree (dt_start) WHERE (dt_start IS NOT NULL);


--
-- TOC entry 4710 (class 1259 OID 340012)
-- Name: session_event_dt_start_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_dt_start_idx ON thesession.session_event USING btree (dt_start);


--
-- TOC entry 4711 (class 1259 OID 341974)
-- Name: session_event_geom_gist_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_geom_gist_idx ON thesession.session_event USING gist (geom);


--
-- TOC entry 4712 (class 1259 OID 340018)
-- Name: session_event_name_trgm_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_name_trgm_idx ON thesession.session_event USING gin (name public.gin_trgm_ops);


--
-- TOC entry 4715 (class 1259 OID 340015)
-- Name: session_event_town_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_town_idx ON thesession.session_event USING btree (town);


--
-- TOC entry 4716 (class 1259 OID 340020)
-- Name: session_event_town_trgm_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_event_town_trgm_idx ON thesession.session_event USING gin (town public.gin_trgm_ops);


--
-- TOC entry 4690 (class 1259 OID 482439)
-- Name: session_sets_raw_lower_username_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_sets_raw_lower_username_idx ON thesession.session_sets_raw USING btree (lower(username));


--
-- TOC entry 4691 (class 1259 OID 482438)
-- Name: session_sets_raw_member_date_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_sets_raw_member_date_idx ON thesession.session_sets_raw USING btree (member_id, date);


--
-- TOC entry 4692 (class 1259 OID 482440)
-- Name: session_sets_raw_member_username_date_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_sets_raw_member_username_date_idx ON thesession.session_sets_raw USING btree (member_id, username, date);


--
-- TOC entry 4722 (class 1259 OID 391567)
-- Name: session_tune_alias_alias_lower_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_tune_alias_alias_lower_idx ON thesession.session_tune_alias USING btree (lower(alias));


--
-- TOC entry 4727 (class 1259 OID 391570)
-- Name: session_tune_alias_unique_ci; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX session_tune_alias_unique_ci ON thesession.session_tune_alias USING btree (tune_id, lower(alias));


--
-- TOC entry 4728 (class 1259 OID 391566)
-- Name: session_tune_alias_unique_per_tune; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX session_tune_alias_unique_per_tune ON thesession.session_tune_alias USING btree (tune_id, lower(alias));


--
-- TOC entry 4721 (class 1259 OID 378550)
-- Name: session_venue_web_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX session_venue_web_idx ON thesession.session_venue USING btree (venue_web);


--
-- TOC entry 4729 (class 1259 OID 396478)
-- Name: sessions_address_trgm_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_address_trgm_idx ON thesession.sessions USING gin (address public.gin_trgm_ops);


--
-- TOC entry 4730 (class 1259 OID 396476)
-- Name: sessions_country_area_town_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_country_area_town_idx ON thesession.sessions USING btree (country, area, town);


--
-- TOC entry 4731 (class 1259 OID 396473)
-- Name: sessions_country_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_country_idx ON thesession.sessions USING btree (country);


--
-- TOC entry 4732 (class 1259 OID 396479)
-- Name: sessions_geom_gist_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_geom_gist_idx ON thesession.sessions USING gist (geom);


--
-- TOC entry 4733 (class 1259 OID 396475)
-- Name: sessions_name_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_name_idx ON thesession.sessions USING btree (name);


--
-- TOC entry 4734 (class 1259 OID 396477)
-- Name: sessions_name_trgm_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_name_trgm_idx ON thesession.sessions USING gin (name public.gin_trgm_ops);


--
-- TOC entry 4737 (class 1259 OID 396474)
-- Name: sessions_town_idx; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE INDEX sessions_town_idx ON thesession.sessions USING btree (town);


--
-- TOC entry 4865 (class 1259 OID 799772)
-- Name: ux_mv_artist_name_search_artist_name; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_artist_name_search_artist_name ON thesession.mv_artist_name_search USING btree (artist_name);


--
-- TOC entry 4869 (class 1259 OID 799947)
-- Name: ux_mv_artist_pathway_related_artists_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_artist_pathway_related_artists_unique ON thesession.mv_artist_pathway_related_artists USING btree (artist_a, artist_b, source_tune_id, source_tune_name, target_tune_id, target_tune_name, edge_reason);


--
-- TOC entry 4874 (class 1259 OID 799839)
-- Name: ux_mv_artist_transition_evidence_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_artist_transition_evidence_unique ON thesession.mv_artist_transition_evidence USING btree (artist_name, recording, track, source_tune_number, target_tune_number);


--
-- TOC entry 4862 (class 1259 OID 799877)
-- Name: ux_mv_artist_transition_features_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_artist_transition_features_unique ON thesession.mv_artist_transition_features USING btree (artist_name, source_tune_id, source_tune_name, target_tune_id, target_tune_name);


--
-- TOC entry 4898 (class 1259 OID 951120)
-- Name: ux_mv_melody_2bar_fragment_ngrams_fragment_pos; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_melody_2bar_fragment_ngrams_fragment_pos ON thesession.mv_melody_2bar_fragment_ngrams_old USING btree (fragment_id, ngram_position);


--
-- TOC entry 4892 (class 1259 OID 807414)
-- Name: ux_mv_melody_2bar_fragments_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_melody_2bar_fragments_fragment ON thesession.mv_melody_2bar_fragments_old USING btree (fragment_id);


--
-- TOC entry 4933 (class 1259 OID 889531)
-- Name: ux_mv_melody_2bar_fragments_v5_fragment; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_melody_2bar_fragments_v5_fragment ON thesession.mv_melody_2bar_fragments_v5 USING btree (fragment_id);


--
-- TOC entry 4900 (class 1259 OID 807762)
-- Name: ux_mv_melody_2bar_ngram_stats_interval; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_melody_2bar_ngram_stats_interval ON thesession.mv_melody_2bar_ngram_stats_old USING btree (interval_ngram);


--
-- TOC entry 4827 (class 1259 OID 605376)
-- Name: ux_mv_mode_set_transitions_source_target; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_mode_set_transitions_source_target ON thesession.mv_mode_set_transitions USING btree (source_mode_label, target_mode_label);


--
-- TOC entry 4883 (class 1259 OID 800351)
-- Name: ux_mv_recording_set_search_recording_track; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_recording_set_search_recording_track ON thesession.mv_recording_set_search USING btree (recording_id, track);


--
-- TOC entry 4840 (class 1259 OID 606427)
-- Name: ux_mv_set_search_tuneset; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_set_search_tuneset ON thesession.mv_set_search USING btree (tuneset);


--
-- TOC entry 4782 (class 1259 OID 574822)
-- Name: ux_mv_set_signatures_signature; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_set_signatures_signature ON thesession.mv_set_signatures USING btree (signature);


--
-- TOC entry 4871 (class 1259 OID 796952)
-- Name: ux_mv_setting_bookmarkers_bookmarker_setting; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_setting_bookmarkers_bookmarker_setting ON thesession.mv_setting_bookmarkers USING btree (bookmarker_member_id, setting_id);


--
-- TOC entry 4878 (class 1259 OID 799920)
-- Name: ux_mv_transition_artist_overlap_unique; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_transition_artist_overlap_unique ON thesession.mv_transition_artist_overlap USING btree (artist_a, artist_b, source_tune_id, target_tune_id);


--
-- TOC entry 4928 (class 1259 OID 947922)
-- Name: ux_mv_tune_name_search_unique_row; Type: INDEX; Schema: thesession; Owner: folkguitar
--

CREATE UNIQUE INDEX ux_mv_tune_name_search_unique_row ON thesession.mv_tune_name_search USING btree (tune_id, primary_name, search_name, is_primary);


--
-- TOC entry 5008 (class 2620 OID 339891)
-- Name: session_tune_popularity_raw trg_generate_session_slug; Type: TRIGGER; Schema: thesession; Owner: folkguitar
--

CREATE TRIGGER trg_generate_session_slug BEFORE INSERT OR UPDATE ON thesession.session_tune_popularity_raw FOR EACH ROW EXECUTE FUNCTION public.generate_session_slug();


--
-- TOC entry 5011 (class 2620 OID 436200)
-- Name: session_member trg_session_member_updated; Type: TRIGGER; Schema: thesession; Owner: folkguitar
--

CREATE TRIGGER trg_session_member_updated BEFORE UPDATE ON thesession.session_member FOR EACH ROW EXECUTE FUNCTION thesession.update_timestamp();


--
-- TOC entry 5007 (class 2620 OID 339908)
-- Name: session_tunes_raw trg_slug_session_tunes_raw; Type: TRIGGER; Schema: thesession; Owner: folkguitar
--

CREATE TRIGGER trg_slug_session_tunes_raw BEFORE INSERT OR UPDATE OF name ON thesession.session_tunes_raw FOR EACH ROW EXECUTE FUNCTION thesession.trg_set_slug_session_tunes_raw();


--
-- TOC entry 5010 (class 2620 OID 339898)
-- Name: session_set_items_raw trg_slug_set_items; Type: TRIGGER; Schema: thesession; Owner: folkguitar
--

CREATE TRIGGER trg_slug_set_items BEFORE INSERT OR UPDATE OF name ON thesession.session_set_items_raw FOR EACH ROW EXECUTE FUNCTION thesession.trg_set_slug_set_items();


--
-- TOC entry 5009 (class 2620 OID 339896)
-- Name: session_tune_popularity_raw trg_slug_tune_popularity; Type: TRIGGER; Schema: thesession; Owner: folkguitar
--

CREATE TRIGGER trg_slug_tune_popularity BEFORE INSERT OR UPDATE OF name ON thesession.session_tune_popularity_raw FOR EACH ROW EXECUTE FUNCTION thesession.trg_set_slug_tune_popularity();


--
-- TOC entry 5005 (class 2606 OID 399786)
-- Name: tune_collection_item fk_collection; Type: FK CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.tune_collection_item
    ADD CONSTRAINT fk_collection FOREIGN KEY (collection_id) REFERENCES thesession.tune_collection(id) ON DELETE CASCADE;


--
-- TOC entry 5006 (class 2606 OID 588962)
-- Name: session_member_tunebook fk_member; Type: FK CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_member_tunebook
    ADD CONSTRAINT fk_member FOREIGN KEY (member_id) REFERENCES thesession.session_member(id);


--
-- TOC entry 5004 (class 2606 OID 376301)
-- Name: session_event_comment session_event_comment_event_id_fkey; Type: FK CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_event_comment
    ADD CONSTRAINT session_event_comment_event_id_fkey FOREIGN KEY (event_id) REFERENCES thesession.session_event(id) ON DELETE CASCADE;


--
-- TOC entry 5003 (class 2606 OID 291023)
-- Name: session_set_items_raw session_set_items_raw_tuneset_fkey; Type: FK CONSTRAINT; Schema: thesession; Owner: folkguitar
--

ALTER TABLE ONLY thesession.session_set_items_raw
    ADD CONSTRAINT session_set_items_raw_tuneset_fkey FOREIGN KEY (tuneset) REFERENCES thesession.session_sets_raw(tuneset) ON DELETE CASCADE;


-- Completed on 2026-07-18 21:19:53

--
-- PostgreSQL database dump complete
--

\unrestrict W9hriDSQZZnDrCyEADjVKCIitKgZSAdTK6oxPoYCI53SC2mlH4r6Xak1nKBv1vm

