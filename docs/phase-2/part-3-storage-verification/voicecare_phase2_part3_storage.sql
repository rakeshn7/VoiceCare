-- =============================================================================
-- VoiceCare Phase 2 — Part 3: Supabase Storage and Doctor Verification Documents
-- Final Hardened Security Revision
-- Target  : PostgreSQL 15+ / Supabase Storage
-- Scope   : Private Bucket Provisioning, Storage RLS Policies, Path & Metadata
--           Validation, Doctor Multi-Factor Ownership, and Asynchronous Deletion Queue
-- Status  : NOT YET EXECUTED — design and review document only
--
-- PREREQUISITES:
-- 1. voicecare_part1_database.sql must be executed (defines public.doctors,
--    public.doctor_documents, and related tables).
-- 2. voicecare_part2_auth.sql must be executed (defines public.user_role,
--    public.profiles, public.is_admin(), public.is_doctor()).
--
-- Intended Owner: postgres (database superuser / migration executor)
-- Execution order matters. Do not reorder sections.
-- =============================================================================


-- =============================================================================
-- PREFLIGHT ASSERTIONS
-- =============================================================================

DO $$
DECLARE
    r RECORD;
    v_conflicts TEXT := '';
BEGIN
    -- 1. Assert database superuser / migration executor
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Migration prerequisite failed: voicecare_phase2_part3_storage.sql must be executed as the postgres superuser (current_user is "%")',
            current_user;
    END IF;

    -- 2. Assert Supabase Storage schema existence
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'storage'
    ) THEN
        RAISE EXCEPTION 'Migration prerequisite failed: "storage" schema does not exist. Ensure Supabase Storage is enabled.';
    END IF;

    -- 3. Assert Storage tables existence
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'storage' AND c.relname = 'buckets'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'storage' AND c.relname = 'objects'
    ) THEN
        RAISE EXCEPTION 'Migration prerequisite failed: storage.buckets or storage.objects table is missing.';
    END IF;

    -- 4. Assert Part 1 foundation tables
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'doctors'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'doctor_documents'
    ) THEN
        RAISE EXCEPTION 'Migration prerequisite failed: public.doctors or public.doctor_documents missing. Execute Part 1 first.';
    END IF;

    -- 5. Assert Part 2 security helper functions
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'is_admin'
    ) OR NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'is_doctor'
    ) THEN
        RAISE EXCEPTION 'Migration prerequisite failed: public.is_admin() or public.is_doctor() missing. Execute Part 2 first.';
    END IF;

    -- -----------------------------------------------------------------------
    -- 6. Conservative Fail-closed Preflight Assertion:
    --    Detect ANY foreign permissive policy on storage.objects applying to
    --    authenticated users, anon, or PUBLIC for SELECT, INSERT, UPDATE, DELETE, or ALL.
    --
    --    SECURITY RATIONALE:
    --    In PostgreSQL, PERMISSIVE policies combine using logical OR.
    --    If any foreign permissive policy exists on storage.objects, it could
    --    potentially grant unintended access to the private "doctor-docs" bucket.
    --    Heuristic SQL expression parsing cannot guarantee safety across all
    --    possible expressions.
    --
    --    FAIL-CLOSED BEHAVIOR:
    --    - Excludes ONLY explicitly identified VoiceCare-managed policies.
    --    - If ANY foreign applicable permissive policy exists on storage.objects,
    --      the migration HALTS IMMEDIATELY with RAISE EXCEPTION.
    --    - Reports the policy's name, command, roles, USING expression, and
    --      WITH CHECK expression.
    --    - NEVER automatically drops, modifies, or converts unrelated policies.
    --    - Requires manual administrator review and resolution before retrying.
    -- -----------------------------------------------------------------------
    FOR r IN
        SELECT
            policyname,
            cmd,
            roles::text AS roles_str,
            COALESCE(qual, '') AS qual_str,
            COALESCE(with_check, '') AS check_str
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND permissive = 'PERMISSIVE'
          -- Applies to authenticated, anon, or public (empty array {} represents PUBLIC)
          AND (
              'authenticated' = ANY(roles)
              OR 'anon' = ANY(roles)
              OR 'public' = ANY(roles)
              OR roles = '{}'::name[]
          )
          -- Exclude ONLY explicitly identified VoiceCare-managed policies
          -- (current 4 active policies plus 4 legacy naming variants cleaned up in Section 3)
          AND policyname NOT IN (
              'doctor_docs: select own or admin',
              'doctor_docs: insert own or admin',
              'doctor_docs: update own or admin',
              'doctor_docs: delete own or admin',
              'doctor-docs: doctor upload own',
              'doctor-docs: doctor read own',
              'doctor-docs: doctor delete own',
              'doctor-docs: admin read all'
          )
    LOOP
        v_conflicts := v_conflicts || format(
            E'\n  - Policy: "%s"\n    Command: %s, Roles: %s\n    USING: %s\n    WITH CHECK: %s\n',
            r.policyname,
            r.cmd,
            r.roles_str,
            CASE WHEN r.qual_str = '' THEN '(none)' ELSE r.qual_str END,
            CASE WHEN r.check_str = '' THEN '(none)' ELSE r.check_str END
        );
    END LOOP;

    IF v_conflicts <> '' THEN
        RAISE EXCEPTION
            'Security Preflight Aborted: Foreign permissive policy detected on storage.objects!%
In PostgreSQL, PERMISSIVE policies combine using logical OR.
Any foreign permissive policy on storage.objects applying to authenticated users or PUBLIC could grant unintended access to the private "doctor-docs" bucket.

Foreign Permissive Policies Detected:%

MANUAL ADMINISTRATOR REVIEW REQUIRED:
1. An administrator must manually review each foreign policy listed above.
2. VoiceCare never automatically drops, modifies, or converts unrelated policies.
3. If a policy was intended for another bucket (e.g. "avatars"), scope it explicitly or convert it to a RESTRICTIVE policy (CREATE POLICY ... AS RESTRICTIVE) so it combines using logical AND.
4. Once all foreign permissive policies on storage.objects have been manually reviewed and safely resolved, re-run this migration.',
            E'\n', v_conflicts;
    END IF;
END $$;


-- =============================================================================
-- SECTION 1: STORAGE BUCKET CONFIGURATION
--
-- Security rules:
--   - id / name : 'doctor-docs'
--   - public    : false (STRICTLY PRIVATE - direct public CDN URLs disabled)
--   - file_size_limit   : 10485760 bytes (10 MB per file)
--   - allowed_mime_types: PDF and standard raster/lossless images
--   - Repeatable upsert resets parameters to secure state on every run.
-- =============================================================================

INSERT INTO storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
VALUES (
    'doctor-docs',
    'doctor-docs',
    false, -- Strictly private
    10485760, -- 10 MB in bytes
    ARRAY[
        'application/pdf',
        'image/png',
        'image/jpeg',
        'image/webp'
    ]::text[]
)
ON CONFLICT (id) DO UPDATE SET
    public             = false,
    file_size_limit    = 10485760,
    allowed_mime_types = ARRAY[
        'application/pdf',
        'image/png',
        'image/jpeg',
        'image/webp'
    ]::text[];

COMMENT ON TABLE storage.buckets IS 'Supabase Storage buckets registry';


-- =============================================================================
-- SECTION 2: STORAGE VALIDATION & OWNERSHIP HELPER FUNCTIONS
--
-- All functions:
--   - Owned by postgres
--   - search_path = pg_catalog
--   - Fully schema-qualified public / storage table references
--   - STABLE and SECURITY DEFINER
--   - Fail closed on any malformed input or unexpected exception
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1  validate_doctor_document_path(object_name text)
--      Strict path structure enforcement:
--        1. Path non-null, no backslashes, no repeated slashes, no traversal sequences.
--        2. EXACTLY ONE slash: strictly {doctor_uuid}/{filename.ext}.
--        3. No empty segments, no leading or trailing whitespace.
--        4. Doctor folder component must match standard 36-char UUID regex.
--        5. Filename component must be 5-255 characters, safe character set,
--           cannot start or end with a dot, and extension must be in allowed whitelist.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_doctor_document_path(p_name text)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_doctor_uuid text;
    v_filename    text;
    v_ext         text;
BEGIN
    -- 1. Path must not be null
    IF p_name IS NULL THEN
        RETURN false;
    END IF;

    -- 2. Reject backslashes, repeated slashes, and directory traversal sequences
    IF p_name LIKE '%\%' OR p_name LIKE '%//%' OR p_name LIKE '%..%' THEN
        RETURN false;
    END IF;

    -- 3. Exactly one slash: strictly {doctor_uuid}/{filename.ext}
    --    Prevents subfolders, trailing slashes, or missing directory prefixes.
    IF (length(p_name) - length(replace(p_name, '/', ''))) <> 1 THEN
        RETURN false;
    END IF;

    v_doctor_uuid := split_part(p_name, '/', 1);
    v_filename    := split_part(p_name, '/', 2);

    -- 4. Reject empty segments or segments with leading/trailing whitespace
    IF length(v_doctor_uuid) = 0 OR length(v_filename) = 0 OR
       v_doctor_uuid <> trim(v_doctor_uuid) OR v_filename <> trim(v_filename) THEN
        RETURN false;
    END IF;

    -- 5. Doctor folder must strictly match standard 36-character UUID format (hex with hyphens)
    IF v_doctor_uuid !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        RETURN false;
    END IF;

    -- 6. Filename structure validation:
    --    - Length between 5 and 255 (e.g. minimum "a.pdf" is 5 chars)
    --    - Must start with alphanumeric, underscore, or hyphen (cannot start with a dot/hidden file)
    --    - Allowed characters: alphanumeric, underscore, hyphen, and period
    --    - Must end with alphanumeric (cannot end with a period or dot)
    IF length(v_filename) < 5 OR length(v_filename) > 255 THEN
        RETURN false;
    END IF;

    IF v_filename !~ '^[a-zA-Z0-9_\-][a-zA-Z0-9_\-\.]{0,253}[a-zA-Z0-9]$' THEN
        RETURN false;
    END IF;

    -- 7. Extract extension (characters following the last period)
    v_ext := lower(substring(v_filename from '\.([a-zA-Z0-9]+)$'));

    -- 8. Allowed extensions whitelist
    IF v_ext IS NULL OR v_ext NOT IN ('pdf', 'png', 'jpg', 'jpeg', 'webp') THEN
        RETURN false;
    END IF;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        RETURN false;
END;
$$;

ALTER FUNCTION public.validate_doctor_document_path(text) OWNER TO postgres;
COMMENT ON FUNCTION public.validate_doctor_document_path(text)
    IS 'Enforces strict doctor_uuid/filename.ext path structure with exactly one slash, UUID format, and allowed extensions';


-- ---------------------------------------------------------------------------
-- 2.2  validate_doctor_document_metadata(metadata jsonb)
--      Strict metadata validation with safe cast protection:
--        1. Fails closed if metadata is null or not a JSON object.
--        2. Requires "size" and "mimetype" keys.
--        3. Validates size as purely numeric digits (^[0-9]{1,8}$) BEFORE casting
--           to bigint, preventing unhandled casting exceptions on malformed input.
--        4. Validates size is strictly positive (> 0) and <= 10 MB (10485760 bytes).
--        5. Validates MIME type against the bucket allowlist.
--        6. Fails closed on any unexpected exception.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_doctor_document_metadata(p_meta jsonb)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_size_str text;
    v_size_num bigint;
    v_mimetype text;
BEGIN
    -- 1. Metadata must be a non-null JSON object
    IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
        RETURN false;
    END IF;

    -- 2. Must contain size and mimetype keys
    IF NOT (p_meta ? 'size') OR NOT (p_meta ? 'mimetype') THEN
        RETURN false;
    END IF;

    v_size_str := p_meta->>'size';
    v_mimetype := p_meta->>'mimetype';

    -- 3. Fail closed if size string is null or empty
    IF v_size_str IS NULL OR length(v_size_str) = 0 THEN
        RETURN false;
    END IF;

    -- 4. Strictly validate that size contains ONLY digits (positive integer representation)
    --    This prevents runtime exceptions from invalid syntax during bigint casting.
    --    Max 8 digits ensures value fits comfortably within 10MB (10485760 is 8 digits).
    IF v_size_str !~ '^[0-9]{1,8}$' THEN
        RETURN false;
    END IF;

    -- Safe cast guaranteed after regex check
    v_size_num := v_size_str::bigint;

    -- 5. Value must be strictly positive and <= 10 MB (10,485,760 bytes)
    IF v_size_num <= 0 OR v_size_num > 10485760 THEN
        RETURN false;
    END IF;

    -- 6. Validate MIME type against allowed whitelist
    IF v_mimetype IS NULL OR v_mimetype NOT IN (
        'application/pdf',
        'image/png',
        'image/jpeg',
        'image/webp'
    ) THEN
        RETURN false;
    END IF;

    RETURN true;
EXCEPTION
    WHEN OTHERS THEN
        -- Fail closed on any unexpected JSON parsing or casting anomaly
        RETURN false;
END;
$$;

ALTER FUNCTION public.validate_doctor_document_metadata(jsonb) OWNER TO postgres;
COMMENT ON FUNCTION public.validate_doctor_document_metadata(jsonb)
    IS 'Safely validates size (positive, <=10MB, regex pre-checked) and MIME whitelist; fails closed without casting errors';


-- ---------------------------------------------------------------------------
-- 2.3  is_doctor_document_owner(object_name text)
--      Multi-factor ownership verification:
--        1. Calling user is authenticated (auth.uid() IS NOT NULL).
--        2. Calling user has public.profiles.role = 'doctor' (via public.is_doctor()).
--        3. Path conforms to strict path rules (via public.validate_doctor_document_path).
--        4. Doctor UUID segment of path strictly matches auth.uid()::text.
--        5. Calling user exists in the public.doctors relational table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_doctor_document_owner(p_name text)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT
        auth.uid() IS NOT NULL
        AND public.is_doctor()
        AND public.validate_doctor_document_path(p_name)
        AND split_part(p_name, '/', 1) = auth.uid()::text
        AND EXISTS (
            SELECT 1
            FROM   public.doctors d
            WHERE  d.id = auth.uid()
        );
$$;

ALTER FUNCTION public.is_doctor_document_owner(text) OWNER TO postgres;
COMMENT ON FUNCTION public.is_doctor_document_owner(text)
    IS 'Returns true only if caller is a registered doctor whose auth.uid() matches the validated path prefix';


-- =============================================================================
-- SECTION 3: STORAGE ROW LEVEL SECURITY POLICIES
--
-- Security Note on PostgreSQL Permissive Policies:
-- In PostgreSQL, multiple PERMISSIVE policies on the same table combine using logical OR.
-- Therefore, we surgically drop ONLY the policies scoped to 'doctor-docs' to prevent
-- stale or conflicting rules, while preserving unrelated application bucket policies.
-- Every policy explicitly begins with `bucket_id = 'doctor-docs'` to ensure zero leakage.
-- =============================================================================

-- Ensure RLS is enabled on storage.objects
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Surgical cleanup: Drop existing / legacy doctor-docs policies only
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "doctor_docs: select own or admin" ON storage.objects;
DROP POLICY IF EXISTS "doctor_docs: insert own or admin" ON storage.objects;
DROP POLICY IF EXISTS "doctor_docs: update own or admin" ON storage.objects;
DROP POLICY IF EXISTS "doctor_docs: delete own or admin" ON storage.objects;

-- Also clean up legacy migration naming variations if present
DROP POLICY IF EXISTS "doctor-docs: doctor upload own"   ON storage.objects;
DROP POLICY IF EXISTS "doctor-docs: doctor read own"     ON storage.objects;
DROP POLICY IF EXISTS "doctor-docs: doctor delete own"   ON storage.objects;
DROP POLICY IF EXISTS "doctor-docs: admin read all"     ON storage.objects;


-- ---------------------------------------------------------------------------
-- 3.1  SELECT Policy
--      - Doctors: can view and download ONLY their own verified documents.
--      - Admins : can view and download ANY doctor document for verification.
--      - Patients & Anon: strictly blocked (evaluates to false).
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_docs: select own or admin"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'doctor-docs'
        AND (
            public.is_doctor_document_owner(name)
            OR public.is_admin()
        )
    );


-- ---------------------------------------------------------------------------
-- 3.2  INSERT Policy
--      - Doctors: can upload ONLY into their own folder ({auth.uid()}/...)
--                 subject to path, extension, MIME, and size validation.
--      - Admins : can upload credentials on behalf of any doctor (offline ingestion)
--                 subject to path, extension, MIME, and size validation.
--      - Patients: strictly blocked (is_doctor_document_owner is false, is_admin is false).
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_docs: insert own or admin"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'doctor-docs'
        AND public.validate_doctor_document_path(name)
        AND public.validate_doctor_document_metadata(metadata)
        AND (
            public.is_doctor_document_owner(name)
            OR public.is_admin()
        )
    );


-- ---------------------------------------------------------------------------
-- 3.3  UPDATE Policy
--      - Covers upsert operations (e.g. uploading replacement for rejected document).
--      - Doctors: can update ONLY their own files, subject to all validation checks.
--      - Admins : can update any doctor file, subject to all validation checks.
--      - Enforces both USING (target permission) and WITH CHECK (payload validation).
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_docs: update own or admin"
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id = 'doctor-docs'
        AND (
            public.is_doctor_document_owner(name)
            OR public.is_admin()
        )
    )
    WITH CHECK (
        bucket_id = 'doctor-docs'
        AND public.validate_doctor_document_path(name)
        AND public.validate_doctor_document_metadata(metadata)
        AND (
            public.is_doctor_document_owner(name)
            OR public.is_admin()
        )
    );


-- ---------------------------------------------------------------------------
-- 3.4  DELETE Policy
--      - Doctors: can delete their own uploaded documents.
--      - Admins : can delete any document (e.g. invalid file, policy violation).
--      - Patients: strictly blocked.
-- ---------------------------------------------------------------------------
CREATE POLICY "doctor_docs: delete own or admin"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'doctor-docs'
        AND (
            public.is_doctor_document_owner(name)
            OR public.is_admin()
        )
    );


-- =============================================================================
-- SECTION 4: SAFE ASYNCHRONOUS STORAGE DELETION QUEUE ARCHITECTURE
--
-- ARCHITECTURAL SECURITY MANDATE:
-- In Supabase Storage, storage.objects is an internal catalog managed by the
-- Storage service. Physical binary files reside in the underlying S3/GCS bucket.
-- Direct SQL deletion targeting storage.objects DOES NOT delete the underlying physical file
-- and risks corrupting storage service state.
--
-- Therefore, database triggers must never execute catalog removal on storage.objects.
-- Instead, deleting a metadata record from public.doctor_documents inserts a task
-- into public.storage_deletion_queue. A trusted, idempotent server-side worker
-- (Supabase Edge Function or background worker using the official Storage API:
-- supabase.storage.from('doctor-docs').remove([...])) processes the queue with
-- retries, backoff, and 404/missing object handling.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4.1  Queue Table for Asynchronous Physical Cleanup
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.storage_deletion_queue (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id      TEXT        NOT NULL,
    object_path    TEXT        NOT NULL,
    requested_by   UUID        NULL,
    status         TEXT        NOT NULL DEFAULT 'pending',
    attempts       INTEGER     NOT NULL DEFAULT 0,
    last_error     TEXT        NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at   TIMESTAMPTZ NULL,

    CONSTRAINT chk_storage_deletion_queue_status
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    CONSTRAINT chk_storage_deletion_queue_attempts
        CHECK (attempts >= 0),
    CONSTRAINT chk_storage_deletion_queue_path
        CHECK (length(trim(object_path)) > 0)
);

COMMENT ON TABLE  public.storage_deletion_queue
    IS 'Asynchronous queue for physical file deletion via the official Supabase Storage API';
COMMENT ON COLUMN public.storage_deletion_queue.status
    IS 'Job state: pending, processing, completed, or failed';

-- Partial index for high-performance worker polling of pending/failed jobs
CREATE INDEX IF NOT EXISTS idx_storage_deletion_queue_pending
    ON public.storage_deletion_queue (status, created_at)
    WHERE status IN ('pending', 'failed');


-- ---------------------------------------------------------------------------
-- 4.2  Trigger Function: Enqueue deletion task on metadata removal
--      Runs as postgres (SECURITY DEFINER) to reliably insert into the queue.
--      DOES NOT touch storage.objects directly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enqueue_doctor_document_storage_deletion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    -- Safely enqueue the physical file deletion job
    INSERT INTO public.storage_deletion_queue (
        bucket_id,
        object_path,
        requested_by,
        status
    )
    VALUES (
        'doctor-docs',
        OLD.storage_path,
        auth.uid(),
        'pending'
    );

    RETURN OLD;
END;
$$;

ALTER FUNCTION public.enqueue_doctor_document_storage_deletion() OWNER TO postgres;
COMMENT ON FUNCTION public.enqueue_doctor_document_storage_deletion()
    IS 'Enqueues storage path for background cleanup via Storage API when metadata row is deleted';

-- Recreate trigger on public.doctor_documents
DROP TRIGGER IF EXISTS trg_doctor_documents_storage_cleanup ON public.doctor_documents;

CREATE TRIGGER trg_doctor_documents_storage_cleanup
    AFTER DELETE ON public.doctor_documents
    FOR EACH ROW
    EXECUTE FUNCTION public.enqueue_doctor_document_storage_deletion();


-- =============================================================================
-- SECTION 5: PRIVILEGES AND ROLE LOCKDOWN (LEAST PRIVILEGE)
-- =============================================================================

-- Ensure anon has ZERO access to doctor-docs and storage objects
REVOKE ALL ON storage.buckets FROM anon;
REVOKE ALL ON storage.objects FROM anon;

-- Authenticated clients need standard table-level access to storage schemas,
-- but actual operations are strictly gated by the RLS policies above.
GRANT SELECT ON storage.buckets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;

-- Storage Deletion Queue: Locked down completely from anon and normal users
REVOKE ALL ON public.storage_deletion_queue FROM PUBLIC, anon, authenticated;

-- Administrators can inspect the queue for monitoring; modifications reserved for worker
ALTER TABLE public.storage_deletion_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "storage_deletion_queue: admin read only" ON public.storage_deletion_queue;
CREATE POLICY "storage_deletion_queue: admin read only"
    ON public.storage_deletion_queue FOR SELECT TO authenticated
    USING (public.is_admin());

GRANT SELECT ON public.storage_deletion_queue TO authenticated;

-- Security helper functions execution grants
REVOKE ALL ON FUNCTION public.validate_doctor_document_path(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_doctor_document_path(text) TO authenticated;

REVOKE ALL ON FUNCTION public.validate_doctor_document_metadata(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_doctor_document_metadata(jsonb) TO authenticated;

REVOKE ALL ON FUNCTION public.is_doctor_document_owner(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_doctor_document_owner(text) TO authenticated;

-- Trigger function is called only by internal database trigger
REVOKE ALL ON FUNCTION public.enqueue_doctor_document_storage_deletion() FROM PUBLIC, anon, authenticated;


-- =============================================================================
-- END OF PART 3: SUPABASE STORAGE AND DOCTOR VERIFICATION DOCUMENTS
-- Status: REVIEW ONLY — not yet executed on a live database
-- =============================================================================
