-- =============================================================================
-- VoiceCare Phase 2 — Part 5: Admin Review Dashboard & Doctor Verification Workflow
-- =============================================================================
-- File: voicecare_phase2_part5_admin_review.sql
-- Description: Transactional administrative review RPCs, application listing,
--              details retrieval, statistics, role promotion guards, and
--              least-privilege access controls.
-- Security Standard: Fail-closed, SECURITY DEFINER with fixed search_path = pg_catalog,
--                    owned by postgres, dual-layer authorization checks,
--                    concurrency row-locks (FOR UPDATE).
-- Status: APPROVED REVIEW SPECIFICATION — NOT YET EXECUTED IN SUPABASE
-- =============================================================================

-- =============================================================================
-- SECTION 1: MIGRATION PREFLIGHT ASSERTIONS
--
-- Evaluates prerequisite schema objects from Parts 1–4 before applying DDL.
-- Fails immediately with descriptive exception if prerequisites are missing.
-- =============================================================================

DO $$
BEGIN
    -- Assertion 1: Public schema existence and standard caller verification
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = 'public') THEN
        RAISE EXCEPTION 'Preflight Failure: public schema does not exist';
    END IF;

    -- Assertion 2: Required tables from Parts 1–4
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_tables
        WHERE schemaname = 'public' AND tablename = 'doctor_verifications'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.doctor_verifications table missing from Part 1';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_tables
        WHERE schemaname = 'public' AND tablename = 'doctors'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.doctors table missing from Part 1';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_tables
        WHERE schemaname = 'public' AND tablename = 'profiles'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.profiles table missing from Part 1';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_tables
        WHERE schemaname = 'public' AND tablename = 'doctor_documents'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.doctor_documents table missing from Part 1';
    END IF;

    -- Assertion 3: Required custom enum types
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typname = 'verification_status'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.verification_status enum missing from Part 1';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typname = 'user_role'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.user_role enum missing from Part 1';
    END IF;

    -- Assertion 4: Verification status enum values check
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_enum e
        JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typname = 'verification_status' AND e.enumlabel = 'approved'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.verification_status missing "approved" label';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_enum e
        JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typname = 'verification_status' AND e.enumlabel = 'rejected'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.verification_status missing "rejected" label';
    END IF;

    -- Assertion 5: Part 2 security helper functions
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'is_admin'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: public.is_admin() helper function missing from Part 2';
    END IF;

    -- Assertion 6: Part 2 role protection trigger
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger trg
        JOIN pg_catalog.pg_class c ON c.oid = trg.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND c.relname = 'profiles' AND trg.tgname = 'trg_protect_profile_role'
    ) THEN
        RAISE EXCEPTION 'Preflight Failure: trg_protect_profile_role trigger missing from Part 2';
    END IF;

    RAISE NOTICE 'VoiceCare Part 5 preflight assertions successfully verified.';
END;
$$;


-- =============================================================================
-- SECTION 2: ADMINISTRATIVE REVIEW DECISION RPC
--
-- public.admin_review_doctor_application
--
-- Atomic, transactional approval or rejection of a prospective doctor application.
--
-- Hardening:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Explicit verification of caller administrator role (is_admin())
--   - Row-level locking (FOR UPDATE) on doctor and verification records
--   - State transition validation (strictly prevents double approval/rejection)
--   - Safe promotion of profiles.role via trusted trigger execution
--   - Mandates rejection reason when declining
--   - Enforces minimum credential presence before approving
--   - Emits standardized machine-readable error codes
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_review_doctor_application(
    p_doctor_id         UUID,
    p_decision          TEXT,
    p_rejection_reason  TEXT DEFAULT NULL,
    p_admin_notes       TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id          UUID;
    v_decision_clean    TEXT;
    v_doctor            RECORD;
    v_verification      RECORD;
    v_doc_count         BIGINT;
    v_reason_clean      TEXT;
    v_notes_clean       TEXT;
    v_result            JSONB;
BEGIN
    -- 1. Caller Authentication
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to execute administrative review (code: AUTH_REQUIRED)';
    END IF;

    -- 2. Caller Authorization (Administrator role check)
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: caller does not possess administrator privileges (code: ADMIN_REQUIRED)';
    END IF;

    -- 3. Prohibit Self-Review (Administrator cannot review their own application)
    IF v_admin_id = p_doctor_id THEN
        RAISE EXCEPTION 'Administrators cannot review or adjudicate their own doctor application (code: ADMIN_SELF_REVIEW_PROHIBITED)';
    END IF;

    -- 4. Parameter Validation: Decision
    IF p_decision IS NULL THEN
        RAISE EXCEPTION 'Review decision is mandatory (code: DECISION_REQUIRED)';
    END IF;

    v_decision_clean := lower(trim(p_decision));
    IF v_decision_clean NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'Invalid review decision. Permitted values are "approved" or "rejected" (code: INVALID_DECISION)';
    END IF;

    -- Clean optional admin notes
    v_notes_clean := NULLIF(trim(COALESCE(p_admin_notes, '')), '');
    IF v_notes_clean IS NOT NULL AND length(v_notes_clean) > 2000 THEN
        RAISE EXCEPTION 'Admin notes cannot exceed 2000 characters (code: ADMIN_NOTES_TOO_LONG)';
    END IF;

    -- 5. Concurrency Control: Acquire Row Locks
    -- Lock target doctor record
    SELECT * INTO v_doctor
    FROM public.doctors
    WHERE id = p_doctor_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor application record not found for ID % (code: DOCTOR_NOT_FOUND)', p_doctor_id;
    END IF;

    -- Lock target verification record
    SELECT * INTO v_verification
    FROM public.doctor_verifications
    WHERE doctor_id = p_doctor_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor verification record not found for doctor ID % (code: VERIFICATION_RECORD_NOT_FOUND)', p_doctor_id;
    END IF;

    -- 6. State Transition Integrity Checks
    IF v_verification.status = 'approved'::public.verification_status THEN
        IF v_decision_clean = 'approved' THEN
            RAISE EXCEPTION 'Application has already been approved (code: ALREADY_APPROVED)';
        ELSE
            RAISE EXCEPTION 'Cannot reject an already approved doctor through the onboarding review workflow (code: CANNOT_REJECT_APPROVED_DOCTOR)';
        END IF;
    END IF;

    IF v_verification.status = 'rejected'::public.verification_status THEN
        IF v_decision_clean = 'rejected' THEN
            RAISE EXCEPTION 'Application has already been rejected (code: ALREADY_REJECTED)';
        ELSE
            RAISE EXCEPTION 'Cannot approve a rejected application without a formal resubmission (code: CANNOT_APPROVE_REJECTED_APPLICATION)';
        END IF;
    END IF;

    IF v_verification.status = 'suspended'::public.verification_status THEN
        RAISE EXCEPTION 'Account is currently suspended; onboarding review is not permitted (code: ACCOUNT_SUSPENDED)';
    END IF;

    IF v_verification.status <> 'pending'::public.verification_status THEN
        RAISE EXCEPTION 'Application is not in pending status (code: INVALID_APPLICATION_STATUS)';
    END IF;

    -- 7. Execute Decision Workflow
    IF v_decision_clean = 'approved' THEN
        -- 7.1 Data Completeness Invariants on Approval
        IF v_verification.registration_number IS NULL OR length(trim(v_verification.registration_number)) = 0 THEN
            RAISE EXCEPTION 'Cannot approve doctor without a valid medical council registration number (code: MISSING_REGISTRATION_NUMBER)';
        END IF;

        IF v_verification.issuing_authority IS NULL OR length(trim(v_verification.issuing_authority)) = 0 THEN
            RAISE EXCEPTION 'Cannot approve doctor without an issuing medical council authority (code: MISSING_ISSUING_AUTHORITY)';
        END IF;

        IF v_doctor.clinic_name IS NULL OR length(trim(v_doctor.clinic_name)) = 0 THEN
            RAISE EXCEPTION 'Cannot approve doctor without valid clinic or practice details (code: MISSING_CLINIC_DETAILS)';
        END IF;

        -- 7.2 Verification Document Presence Invariant
        SELECT count(*) INTO v_doc_count
        FROM public.doctor_documents
        WHERE doctor_id = p_doctor_id;

        IF v_doc_count = 0 THEN
            RAISE EXCEPTION 'Cannot approve doctor application without at least one submitted verification document (code: MISSING_VERIFICATION_DOCUMENTS)';
        END IF;

        -- 7.3 Update Verification Record
        UPDATE public.doctor_verifications
        SET status       = 'approved'::public.verification_status,
            reviewed_by  = v_admin_id,
            reviewed_at  = now(),
            admin_notes  = COALESCE(v_notes_clean, admin_notes),
            updated_at   = now()
        WHERE doctor_id = p_doctor_id;

        -- 7.4 Update Doctor Record (Enables public directory visibility)
        UPDATE public.doctors
        SET is_approved = true,
            updated_at  = now()
        WHERE id = p_doctor_id;

        -- 7.5 Promote Profile Role (patient -> doctor)
        -- Handled safely: protect_profile_role trigger executes, verifies caller is_admin(),
        -- confirms v_admin_id <> p_doctor_id, and permits the role transition.
        UPDATE public.profiles
        SET role       = 'doctor'::public.user_role,
            updated_at = now()
        WHERE id = p_doctor_id;

        -- 7.6 Construct Response
        v_result := jsonb_build_object(
            'success',          true,
            'doctor_id',        p_doctor_id,
            'decision',         'approved',
            'previous_status',  'pending',
            'new_status',       'approved',
            'is_approved',      true,
            'role',             'doctor',
            'document_count',   v_doc_count,
            'reviewed_by',      v_admin_id,
            'reviewed_at',      now()
        );

    ELSIF v_decision_clean = 'rejected' THEN
        -- 7.7 Rejection Reason Validation
        IF p_rejection_reason IS NULL OR length(trim(p_rejection_reason)) = 0 THEN
            RAISE EXCEPTION 'Mandatory rejection reason required when declining doctor application (code: REJECTION_REASON_REQUIRED)';
        END IF;

        v_reason_clean := trim(p_rejection_reason);
        IF length(v_reason_clean) < 5 THEN
            RAISE EXCEPTION 'Rejection reason must be at least 5 characters in length (code: REJECTION_REASON_TOO_SHORT)';
        END IF;

        IF length(v_reason_clean) > 1000 THEN
            RAISE EXCEPTION 'Rejection reason cannot exceed 1000 characters (code: REJECTION_REASON_TOO_LONG)';
        END IF;

        -- 7.8 Update Verification Record
        UPDATE public.doctor_verifications
        SET status       = 'rejected'::public.verification_status,
            reviewed_by  = v_admin_id,
            reviewed_at  = now(),
            admin_notes  = v_reason_clean || CASE
                WHEN v_notes_clean IS NOT NULL THEN E'\n[Admin Internal Notes]: ' || v_notes_clean
                ELSE ''
            END,
            updated_at   = now()
        WHERE doctor_id = p_doctor_id;

        -- 7.9 Maintain Doctor Approval as False (Excluded from public bookings)
        UPDATE public.doctors
        SET is_approved = false,
            updated_at  = now()
        WHERE id = p_doctor_id;

        -- 7.10 Retain Profile Role as 'patient' (No promotion occurs)
        -- Note: Documents in public.doctor_documents are deliberately retained for audit.

        -- 7.11 Construct Response
        v_result := jsonb_build_object(
            'success',          true,
            'doctor_id',        p_doctor_id,
            'decision',         'rejected',
            'previous_status',  'pending',
            'new_status',       'rejected',
            'is_approved',      false,
            'role',             'patient',
            'rejection_reason', v_reason_clean,
            'reviewed_by',      v_admin_id,
            'reviewed_at',      now()
        );
    END IF;

    RETURN v_result;
END;
$$;

ALTER FUNCTION public.admin_review_doctor_application(UUID, TEXT, TEXT, TEXT) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_review_doctor_application(UUID, TEXT, TEXT, TEXT)
    IS 'Administrator-only atomic transaction to approve or reject a doctor application with role promotion and state guards';


-- =============================================================================
-- SECTION 3: ADMINISTRATIVE APPLICATION LISTING RPC
--
-- public.admin_list_doctor_applications
--
-- Paginated, filtered, and searchable listing of doctor applications for the
-- admin review dashboard. Excludes private patient demographic fields.
--
-- Hardening:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Gated to is_admin() callers only
--   - Bounded pagination (page >= 1, page_size 1..100)
--   - Safe parameterized ILIKE search on doctor name or registration number
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_doctor_applications(
    p_status     TEXT    DEFAULT NULL,
    p_search     TEXT    DEFAULT NULL,
    p_page       INTEGER DEFAULT 1,
    p_page_size  INTEGER DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id          UUID;
    v_status_clean      public.verification_status;
    v_search_clean      TEXT;
    v_page              INTEGER;
    v_page_size         INTEGER;
    v_offset            INTEGER;
    v_total_count       BIGINT := 0;
    v_applications      JSONB := '[]'::JSONB;
BEGIN
    -- 1. Authorization
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to access admin application queue (code: AUTH_REQUIRED)';
    END IF;

    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: caller does not possess administrator privileges (code: ADMIN_REQUIRED)';
    END IF;

    -- 2. Parameter Sanitization
    IF p_status IS NOT NULL AND length(trim(p_status)) > 0 THEN
        BEGIN
            v_status_clean := lower(trim(p_status))::public.verification_status;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'Invalid status filter "%" (code: INVALID_STATUS_FILTER)', p_status;
        END;
    END IF;

    v_search_clean := NULLIF(trim(COALESCE(p_search, '')), '');
    IF v_search_clean IS NOT NULL AND length(v_search_clean) > 100 THEN
        RAISE EXCEPTION 'Search query cannot exceed 100 characters (code: SEARCH_TOO_LONG)';
    END IF;

    v_page := GREATEST(COALESCE(p_page, 1), 1);
    v_page_size := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);
    v_offset := (v_page - 1) * v_page_size;

    -- 3. Total Count Calculation
    SELECT count(*)
    INTO v_total_count
    FROM public.doctor_verifications dv
    JOIN public.doctors d ON d.id = dv.doctor_id
    JOIN public.profiles p ON p.id = dv.doctor_id
    WHERE (v_status_clean IS NULL OR dv.status = v_status_clean)
      AND (
          v_search_clean IS NULL
          OR p.full_name ILIKE ('%' || v_search_clean || '%')
          OR dv.registration_number ILIKE ('%' || v_search_clean || '%')
          OR d.clinic_name ILIKE ('%' || v_search_clean || '%')
      );

    -- 4. Paginated Applications Query
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'doctor_id',           app.doctor_id,
                'full_name',           app.full_name,
                'phone',               app.phone,
                'specialty',           app.specialty,
                'qualification',       app.qualification,
                'experience_years',    app.experience_years,
                'consultation_fee',    app.consultation_fee,
                'clinic_name',         app.clinic_name,
                'clinic_address',      app.clinic_address,
                'status',              app.status,
                'registration_number', app.registration_number,
                'issuing_authority',   app.issuing_authority,
                'document_count',      app.document_count,
                'is_approved',         app.is_approved,
                'is_active',           app.is_active,
                'submitted_at',        app.created_at,
                'reviewed_at',         app.reviewed_at,
                'admin_notes',         app.admin_notes
            )
            ORDER BY
                CASE WHEN app.status = 'pending' THEN 0 ELSE 1 END,
                app.created_at DESC
        ),
        '[]'::JSONB
    )
    INTO v_applications
    FROM (
        SELECT
            dv.doctor_id,
            p.full_name,
            p.phone,
            d.specialty,
            d.qualification,
            d.experience_years,
            d.consultation_fee,
            d.clinic_name,
            d.clinic_address,
            dv.status,
            dv.registration_number,
            dv.issuing_authority,
            dv.created_at,
            dv.reviewed_at,
            dv.admin_notes,
            d.is_approved,
            d.is_active,
            (
                SELECT count(*)
                FROM public.doctor_documents dd
                WHERE dd.doctor_id = dv.doctor_id
            ) AS document_count
        FROM public.doctor_verifications dv
        JOIN public.doctors d ON d.id = dv.doctor_id
        JOIN public.profiles p ON p.id = dv.doctor_id
        WHERE (v_status_clean IS NULL OR dv.status = v_status_clean)
          AND (
              v_search_clean IS NULL
              OR p.full_name ILIKE ('%' || v_search_clean || '%')
              OR dv.registration_number ILIKE ('%' || v_search_clean || '%')
              OR d.clinic_name ILIKE ('%' || v_search_clean || '%')
          )
        ORDER BY
            CASE WHEN dv.status = 'pending' THEN 0 ELSE 1 END,
            dv.created_at DESC
        LIMIT v_page_size
        OFFSET v_offset
    ) app;

    RETURN jsonb_build_object(
        'applications', v_applications,
        'total_count',  v_total_count,
        'page',         v_page,
        'page_size',    v_page_size,
        'total_pages',  CEIL(v_total_count::numeric / v_page_size)
    );
END;
$$;

ALTER FUNCTION public.admin_list_doctor_applications(TEXT, TEXT, INTEGER, INTEGER) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_list_doctor_applications(TEXT, TEXT, INTEGER, INTEGER)
    IS 'Administrator-only paginated listing of doctor applications with search and status filtering';


-- =============================================================================
-- SECTION 4: ADMINISTRATIVE APPLICATION DETAILS RPC
--
-- public.admin_get_doctor_application_details
--
-- Retrieves comprehensive application details, credentials, and verification
-- documents for an administrator conducting a review.
--
-- Hardening:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Gated to is_admin() callers only
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_get_doctor_application_details(
    p_doctor_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id          UUID;
    v_doctor            RECORD;
    v_verification      RECORD;
    v_profile           RECORD;
    v_documents         JSONB;
    v_reviewer_name     TEXT := NULL;
BEGIN
    -- 1. Authorization
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to inspect application details (code: AUTH_REQUIRED)';
    END IF;

    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: caller does not possess administrator privileges (code: ADMIN_REQUIRED)';
    END IF;

    -- 2. Fetch Doctor Record
    SELECT * INTO v_doctor
    FROM public.doctors
    WHERE id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor record not found for ID % (code: DOCTOR_NOT_FOUND)', p_doctor_id;
    END IF;

    -- 3. Fetch Verification Record
    SELECT * INTO v_verification
    FROM public.doctor_verifications
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Verification record not found for doctor ID % (code: VERIFICATION_RECORD_NOT_FOUND)', p_doctor_id;
    END IF;

    -- 4. Fetch User Profile
    SELECT * INTO v_profile
    FROM public.profiles
    WHERE id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User profile not found for doctor ID % (code: PROFILE_NOT_FOUND)', p_doctor_id;
    END IF;

    -- 5. Reviewer Name Resolution (if already reviewed)
    IF v_verification.reviewed_by IS NOT NULL THEN
        SELECT full_name INTO v_reviewer_name
        FROM public.profiles
        WHERE id = v_verification.reviewed_by;
    END IF;

    -- 6. Fetch Submitted Documents
    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'id',            dd.id,
                'document_type', dd.document_type,
                'document_name', dd.document_name,
                'storage_path',  dd.storage_path,
                'created_at',    dd.created_at
            )
            ORDER BY dd.created_at ASC
        ),
        '[]'::JSONB
    )
    INTO v_documents
    FROM public.doctor_documents dd
    WHERE dd.doctor_id = p_doctor_id;

    -- 7. Construct Full Details Payload
    RETURN jsonb_build_object(
        'doctor_id',           p_doctor_id,
        'profile', jsonb_build_object(
            'full_name',  v_profile.full_name,
            'phone',      v_profile.phone,
            'role',       v_profile.role,
            'created_at', v_profile.created_at
        ),
        'doctor', jsonb_build_object(
            'specialty',        v_doctor.specialty,
            'qualification',    v_doctor.qualification,
            'experience_years', v_doctor.experience_years,
            'consultation_fee', v_doctor.consultation_fee,
            'languages',        v_doctor.languages,
            'bio',              v_doctor.bio,
            'clinic_name',      v_doctor.clinic_name,
            'clinic_address',   v_doctor.clinic_address,
            'is_approved',      v_doctor.is_approved,
            'is_active',        v_doctor.is_active,
            'rating',           v_doctor.rating,
            'review_count',     v_doctor.review_count
        ),
        'verification', jsonb_build_object(
            'status',              v_verification.status,
            'registration_number', v_verification.registration_number,
            'issuing_authority',   v_verification.issuing_authority,
            'reviewed_by',         v_verification.reviewed_by,
            'reviewer_name',       v_reviewer_name,
            'reviewed_at',         v_verification.reviewed_at,
            'admin_notes',         v_verification.admin_notes,
            'created_at',          v_verification.created_at,
            'updated_at',          v_verification.updated_at
        ),
        'documents', v_documents
    );
END;
$$;

ALTER FUNCTION public.admin_get_doctor_application_details(UUID) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_get_doctor_application_details(UUID)
    IS 'Administrator-only detailed view of doctor application, credentials, and submitted verification documents';


-- =============================================================================
-- SECTION 5: ADMINISTRATIVE APPLICATION STATISTICS RPC
--
-- public.admin_get_application_stats
--
-- Aggregates application queue counts by verification status for top-level
-- admin dashboard overview cards.
--
-- Hardening:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Gated to is_admin() callers only
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_get_application_stats()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id      UUID;
    v_pending       BIGINT := 0;
    v_approved      BIGINT := 0;
    v_rejected      BIGINT := 0;
    v_suspended     BIGINT := 0;
    v_total         BIGINT := 0;
BEGIN
    -- 1. Authorization
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to access admin statistics (code: AUTH_REQUIRED)';
    END IF;

    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: caller does not possess administrator privileges (code: ADMIN_REQUIRED)';
    END IF;

    -- 2. Aggregate Counts
    SELECT
        COUNT(*) FILTER (WHERE status = 'pending'),
        COUNT(*) FILTER (WHERE status = 'approved'),
        COUNT(*) FILTER (WHERE status = 'rejected'),
        COUNT(*) FILTER (WHERE status = 'suspended'),
        COUNT(*)
    INTO
        v_pending,
        v_approved,
        v_rejected,
        v_suspended,
        v_total
    FROM public.doctor_verifications;

    RETURN jsonb_build_object(
        'pending_count',   v_pending,
        'approved_count',  v_approved,
        'rejected_count',  v_rejected,
        'suspended_count', v_suspended,
        'total_count',     v_total,
        'computed_at',     now()
    );
END;
$$;

ALTER FUNCTION public.admin_get_application_stats() OWNER TO postgres;
COMMENT ON FUNCTION public.admin_get_application_stats()
    IS 'Administrator-only aggregate counts of doctor applications by verification status';


-- =============================================================================
-- SECTION 6: PERMISSION HARDENING & LEAST-PRIVILEGE GRANTS
--
-- Revokes all public / anon permissions on Part 5 functions.
-- Grants execute only to authenticated users, with authorization verified inside.
-- =============================================================================

-- Revoke from PUBLIC and anon
REVOKE ALL ON FUNCTION public.admin_review_doctor_application(UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_list_doctor_applications(TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_get_doctor_application_details(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_get_application_stats() FROM PUBLIC, anon;

-- Grant to authenticated
GRANT EXECUTE ON FUNCTION public.admin_review_doctor_application(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_doctor_applications(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_doctor_application_details(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_application_stats() TO authenticated;


-- =============================================================================
-- SECTION 7: POST-MIGRATION INTEGRITY VERIFICATION
-- =============================================================================

DO $$
DECLARE
    v_fn_count INTEGER;
BEGIN
    SELECT count(*)
    INTO v_fn_count
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'admin_review_doctor_application',
          'admin_list_doctor_applications',
          'admin_get_doctor_application_details',
          'admin_get_application_stats'
      );

    IF v_fn_count <> 4 THEN
        RAISE EXCEPTION 'Post-check Failure: Expected 4 admin review functions, found %', v_fn_count;
    END IF;

    RAISE NOTICE 'VoiceCare Phase 2 Part 5 Admin Review migration successfully verified (4 RPCs provisioned).';
END;
$$;
