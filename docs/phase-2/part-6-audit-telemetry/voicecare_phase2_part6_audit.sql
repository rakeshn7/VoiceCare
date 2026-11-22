-- =============================================================================
-- VoiceCare Phase 2 — Part 6: Audit Logging, Telemetry and Compliance
-- =============================================================================
-- Specification: Append-only audit logs, operational telemetry, immutability
--                triggers, data minimization, least-privilege RLS, and admin RPCs.
-- Status: APPROVED REVIEW SPECIFICATION — NOT YET EXECUTED IN SUPABASE.
-- Target: PostgreSQL 15+ / Supabase Backend
--
-- Tables Defined:
--   1. public.audit_logs (Immutable append-only audit trail)
--   2. public.operational_telemetry (Sanitized diagnostic & operational metrics)
--
-- Security & Compliance Properties:
--   - Strict Immutability: Triggers block UPDATE and DELETE on audit records.
--   - Privacy-by-Design & Data Minimization: Zero patient symptoms, medical
--     notes, passwords, auth tokens, or private URLs in audit payloads.
--   - Role-Based Access: Admin-only access to audit logs and telemetry via RLS.
--   - Automated Capture: Triggers on verifications, appointments, documents,
--     and profile roles guarantee comprehensive coverage without bypass.
--   - Hardened Functions: SECURITY DEFINER, search_path = pg_catalog,
--     OWNER TO postgres on all audit/telemetry routines.
-- =============================================================================

-- =============================================================================
-- SECTION 1: PREFLIGHT VALIDATION ASSERTIONS
-- =============================================================================
DO $$
DECLARE
    v_missing_items TEXT[] := ARRAY[]::TEXT[];
    v_tbl TEXT;
    v_fn TEXT;
BEGIN
    -- 1.1 Verify Core Prerequisite Tables from Parts 1–5
    FOR v_tbl IN SELECT unnest(ARRAY[
        'profiles',
        'doctors',
        'doctor_verifications',
        'doctor_documents',
        'appointments'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_tables
            WHERE schemaname = 'public' AND tablename = v_tbl
        ) THEN
            v_missing_items := array_append(v_missing_items, 'Table: public.' || v_tbl);
        END IF;
    END LOOP;

    -- 1.2 Verify Column Invariants
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'doctors' AND column_name = 'is_approved'
    ) THEN
        v_missing_items := array_append(v_missing_items, 'Column: public.doctors.is_approved');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'doctor_verifications' AND column_name = 'status'
    ) THEN
        v_missing_items := array_append(v_missing_items, 'Column: public.doctor_verifications.status');
    END IF;

    -- 1.3 Verify Prerequisite Functions from Part 2
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' AND p.proname = 'is_admin'
    ) THEN
        v_missing_items := array_append(v_missing_items, 'Function: public.is_admin()');
    END IF;

    IF array_length(v_missing_items, 1) > 0 THEN
        RAISE EXCEPTION 'Preflight Failure: Part 6 dependencies missing: %',
            array_to_string(v_missing_items, ', ');
    END IF;

    RAISE NOTICE 'Part 6 Preflight check passed: all predecessor tables, columns, and functions confirmed.';
END $$;


-- =============================================================================
-- SECTION 2: AUDIT LOGS & OPERATIONAL TELEMETRY TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 2.1 public.audit_logs
--     Authoritative, immutable append-only record of security-critical and
--     clinical lifecycle events across the VoiceCare platform.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
    id                  UUID            NOT NULL DEFAULT gen_random_uuid(),
    event_type          TEXT            NOT NULL,
    actor_id            UUID            REFERENCES public.profiles(id) ON DELETE SET NULL,
    actor_role          TEXT            NOT NULL DEFAULT 'patient',
    resource_type       TEXT            NOT NULL,
    resource_id         UUID            NOT NULL,
    action              TEXT            NOT NULL,
    outcome             TEXT            NOT NULL DEFAULT 'success',
    event_metadata      JSONB           NOT NULL DEFAULT '{}'::jsonb,
    client_ip           INET            DEFAULT NULL,
    client_user_agent   TEXT            DEFAULT NULL,
    correlation_id      TEXT            DEFAULT NULL,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT audit_logs_pkey PRIMARY KEY (id),
    CONSTRAINT chk_audit_event_type CHECK (length(trim(event_type)) > 0 AND length(event_type) <= 100),
    CONSTRAINT chk_audit_resource_type CHECK (length(trim(resource_type)) > 0 AND length(resource_type) <= 100),
    CONSTRAINT chk_audit_action CHECK (length(trim(action)) > 0 AND length(action) <= 50),
    CONSTRAINT chk_audit_outcome CHECK (outcome IN ('success', 'failure', 'denied')),
    CONSTRAINT chk_audit_actor_role CHECK (actor_role IN ('patient', 'doctor', 'admin', 'system'))
);

COMMENT ON TABLE public.audit_logs
    IS 'Authoritative, append-only audit trail recording clinical, onboarding, and administrative events with data minimization.';
COMMENT ON COLUMN public.audit_logs.event_type
    IS 'Standardized identifier of the event (e.g. appointment_booked, doctor_application_approved).';
COMMENT ON COLUMN public.audit_logs.actor_id
    IS 'UUID of the user who initiated the action, or NULL for automated background tasks.';
COMMENT ON COLUMN public.audit_logs.event_metadata
    IS 'Contextual metadata stripped of patient health information, symptoms, notes, and auth tokens.';

-- -----------------------------------------------------------------------------
-- 2.2 public.operational_telemetry
--     Diagnostics, error metrics, and operational performance telemetry.
--     Strictly scrubbed of secrets, tokens, credentials, and patient symptoms.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.operational_telemetry (
    id                  UUID            NOT NULL DEFAULT gen_random_uuid(),
    component           TEXT            NOT NULL,
    event_name          TEXT            NOT NULL,
    severity            TEXT            NOT NULL DEFAULT 'info',
    error_code          TEXT            DEFAULT NULL,
    actor_id            UUID            REFERENCES public.profiles(id) ON DELETE SET NULL,
    telemetry_data      JSONB           NOT NULL DEFAULT '{}'::jsonb,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT operational_telemetry_pkey PRIMARY KEY (id),
    CONSTRAINT chk_telemetry_component CHECK (length(trim(component)) > 0 AND length(component) <= 100),
    CONSTRAINT chk_telemetry_event_name CHECK (length(trim(event_name)) > 0 AND length(event_name) <= 100),
    CONSTRAINT chk_telemetry_severity CHECK (severity IN ('info', 'warning', 'error', 'critical'))
);

COMMENT ON TABLE public.operational_telemetry
    IS 'Sanitized operational diagnostics, failure telemetry, and system execution metrics.';


-- =============================================================================
-- SECTION 3: IMMUTABILITY PROTECTION (TAMPER RESISTANCE)
-- =============================================================================
-- Audit logs and telemetry must be strictly append-only.
-- Any client or admin UPDATE or DELETE statement is blocked at the database engine level.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_audit_log_tampering()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    RAISE EXCEPTION 'Audit records and telemetry entries are strictly append-only and cannot be modified or deleted (code: IMMUTABLE_AUDIT_RECORD)'
        USING ERRCODE = '42501';
    RETURN NULL;
END;
$$;

ALTER FUNCTION public.prevent_audit_log_tampering() OWNER TO postgres;
COMMENT ON FUNCTION public.prevent_audit_log_tampering()
    IS 'Trigger procedure enforcing append-only immutability on audit_logs and operational_telemetry';

DROP TRIGGER IF EXISTS trg_audit_logs_immutability ON public.audit_logs;
CREATE TRIGGER trg_audit_logs_immutability
    BEFORE UPDATE OR DELETE ON public.audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_audit_log_tampering();

DROP TRIGGER IF EXISTS trg_telemetry_immutability ON public.operational_telemetry;
CREATE TRIGGER trg_telemetry_immutability
    BEFORE UPDATE OR DELETE ON public.operational_telemetry
    FOR EACH ROW
    EXECUTE FUNCTION public.prevent_audit_log_tampering();


-- =============================================================================
-- SECTION 4: INDEXES FOR AUDIT SEARCH, COMPLIANCE & TELEMETRY
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
    ON public.audit_logs (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_event_type
    ON public.audit_logs (event_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_id
    ON public.audit_logs (actor_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_logs_resource
    ON public.audit_logs (resource_type, resource_id);

CREATE INDEX IF NOT EXISTS idx_audit_logs_correlation_id
    ON public.audit_logs (correlation_id)
    WHERE correlation_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_telemetry_created_at
    ON public.operational_telemetry (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_telemetry_severity
    ON public.operational_telemetry (severity, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_telemetry_component
    ON public.operational_telemetry (component, created_at DESC);


-- =============================================================================
-- SECTION 5: INTERNAL AUDIT INGESTION & DATA MINIMIZATION HELPER
-- =============================================================================
-- Sanitizes incoming metadata to ensure patient health information (symptoms,
-- complaints, clinical notes) and authentication credentials are never persisted.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_audit_log_internal(
    p_event_type TEXT,
    p_actor_id UUID,
    p_actor_role TEXT,
    p_resource_type TEXT,
    p_resource_id UUID,
    p_action TEXT,
    p_outcome TEXT,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_correlation_id TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_log_id UUID;
    v_sanitized_meta JSONB;
BEGIN
    -- Data Minimization Filter: Strip clinical, medical, and credential fields
    v_sanitized_meta := p_metadata - ARRAY[
        'token', 'jwt', 'password', 'secret', 'key', 'auth', 'bearer',
        'chief_complaint', 'symptoms', 'medical_notes', 'consultation_notes',
        'signed_url', 'view_url'
    ];

    INSERT INTO public.audit_logs (
        event_type,
        actor_id,
        actor_role,
        resource_type,
        resource_id,
        action,
        outcome,
        event_metadata,
        correlation_id,
        created_at
    ) VALUES (
        p_event_type,
        p_actor_id,
        COALESCE(p_actor_role, 'patient'),
        p_resource_type,
        p_resource_id,
        p_action,
        COALESCE(p_outcome, 'success'),
        v_sanitized_meta,
        p_correlation_id,
        clock_timestamp()
    ) RETURNING id INTO v_log_id;

    RETURN v_log_id;
END;
$$;

ALTER FUNCTION public.record_audit_log_internal(TEXT, UUID, TEXT, TEXT, UUID, TEXT, TEXT, JSONB, TEXT) OWNER TO postgres;
COMMENT ON FUNCTION public.record_audit_log_internal(TEXT, UUID, TEXT, TEXT, UUID, TEXT, TEXT, JSONB, TEXT)
    IS 'Internal SECURITY DEFINER routine to sanitize and append immutable audit log records';


-- =============================================================================
-- SECTION 6: AUTOMATED AUDIT EVENT CAPTURE TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 Doctor Verifications Audit Trigger
--     Captures application submission, approval, rejection, and suspension.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_doctor_verification_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_actor_id UUID;
    v_actor_role TEXT;
BEGIN
    v_actor_id := auth.uid();
    IF v_actor_id IS NULL THEN
        v_actor_role := 'system';
    ELSIF public.is_admin() THEN
        v_actor_role := 'admin';
    ELSE
        v_actor_role := 'patient';
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- Record application submission with data minimization.
        -- Medical registration number is omitted from audit metadata to avoid weak unkeyed hashing (MD5).
        -- The authoritative credential remains securely in public.doctor_verifications (accessible via resource_id).
        PERFORM public.record_audit_log_internal(
            'doctor_application_submitted',
            COALESCE(v_actor_id, NEW.doctor_id),
            v_actor_role,
            'doctor_verification',
            NEW.id,
            'INSERT',
            'success',
            jsonb_build_object(
                'doctor_id', NEW.doctor_id,
                'status', NEW.status,
                'issuing_authority', NEW.issuing_authority
            )
        );
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            PERFORM public.record_audit_log_internal(
                CASE
                    WHEN NEW.status = 'approved' THEN 'doctor_application_approved'
                    WHEN NEW.status = 'rejected' THEN 'doctor_application_rejected'
                    WHEN NEW.status = 'suspended' THEN 'doctor_application_suspended'
                    ELSE 'doctor_application_status_updated'
                END,
                COALESCE(v_actor_id, NEW.reviewed_by),
                v_actor_role,
                'doctor_verification',
                NEW.id,
                'UPDATE_STATUS',
                'success',
                jsonb_build_object(
                    'doctor_id', NEW.doctor_id,
                    'old_status', OLD.status,
                    'new_status', NEW.status,
                    'reviewed_by', NEW.reviewed_by,
                    'has_admin_notes', (NEW.admin_notes IS NOT NULL AND length(trim(NEW.admin_notes)) > 0)
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_doctor_verification_lifecycle() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_audit_doctor_verifications ON public.doctor_verifications;
CREATE TRIGGER trg_audit_doctor_verifications
    AFTER INSERT OR UPDATE ON public.doctor_verifications
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_doctor_verification_lifecycle();

-- -----------------------------------------------------------------------------
-- 6.2 Appointments Audit Trigger
--     Captures booking, confirmation, rejection, cancellation, rescheduling,
--     completion, and no-shows with strict exclusion of clinical symptoms.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_appointment_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_actor_id UUID;
    v_actor_role TEXT;
BEGIN
    v_actor_id := auth.uid();
    IF v_actor_id IS NULL THEN
        v_actor_role := 'system';
    ELSIF public.is_admin() THEN
        v_actor_role := 'admin';
    ELSIF public.is_doctor() THEN
        v_actor_role := 'doctor';
    ELSE
        v_actor_role := 'patient';
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- Record appointment creation without storing sensitive symptoms (Data Minimization)
        PERFORM public.record_audit_log_internal(
            'appointment_booked',
            COALESCE(v_actor_id, NEW.patient_id),
            v_actor_role,
            'appointment',
            NEW.id,
            'INSERT',
            'success',
            jsonb_build_object(
                'doctor_id', NEW.doctor_id,
                'patient_id', NEW.patient_id,
                'appointment_date', NEW.appointment_date,
                'appointment_time', NEW.appointment_time,
                'status', NEW.status
            )
        );
    ELSIF TG_OP = 'UPDATE' THEN
        -- Detect rescheduling
        IF NEW.appointment_date IS DISTINCT FROM OLD.appointment_date 
           OR NEW.appointment_time IS DISTINCT FROM OLD.appointment_time THEN
            PERFORM public.record_audit_log_internal(
                'appointment_rescheduled',
                COALESCE(v_actor_id, NEW.patient_id),
                v_actor_role,
                'appointment',
                NEW.id,
                'RESCHEDULE',
                'success',
                jsonb_build_object(
                    'doctor_id', NEW.doctor_id,
                    'patient_id', NEW.patient_id,
                    'old_date', OLD.appointment_date,
                    'new_date', NEW.appointment_date,
                    'old_time', OLD.appointment_time,
                    'new_time', NEW.appointment_time
                )
            );
        END IF;

        -- Detect status transitions
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            PERFORM public.record_audit_log_internal(
                CASE
                    WHEN NEW.status = 'confirmed' THEN 'appointment_confirmed'
                    WHEN NEW.status = 'rejected' THEN 'appointment_rejected'
                    WHEN NEW.status = 'cancelled' THEN 'appointment_cancelled'
                    WHEN NEW.status = 'completed' THEN 'appointment_completed'
                    WHEN NEW.status = 'no_show' THEN 'appointment_no_show'
                    ELSE 'appointment_status_changed'
                END,
                COALESCE(v_actor_id, CASE WHEN NEW.status IN ('confirmed', 'completed', 'no_show') THEN NEW.doctor_id ELSE NEW.patient_id END),
                v_actor_role,
                'appointment',
                NEW.id,
                'UPDATE_STATUS',
                'success',
                jsonb_build_object(
                    'doctor_id', NEW.doctor_id,
                    'patient_id', NEW.patient_id,
                    'old_status', OLD.status,
                    'new_status', NEW.status,
                    'has_cancellation_reason', (NEW.cancellation_reason IS NOT NULL AND length(trim(NEW.cancellation_reason)) > 0)
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_appointment_lifecycle() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_audit_appointments ON public.appointments;
CREATE TRIGGER trg_audit_appointments
    AFTER INSERT OR UPDATE ON public.appointments
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_appointment_lifecycle();

-- -----------------------------------------------------------------------------
-- 6.3 Doctor Documents Audit Trigger
--     Captures credential upload and removal metadata events.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_doctor_document_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_actor_id UUID;
    v_actor_role TEXT;
BEGIN
    v_actor_id := auth.uid();
    IF v_actor_id IS NULL THEN
        v_actor_role := 'system';
    ELSIF public.is_admin() THEN
        v_actor_role := 'admin';
    ELSIF public.is_doctor() THEN
        v_actor_role := 'doctor';
    ELSE
        v_actor_role := 'patient';
    END IF;

    IF TG_OP = 'INSERT' THEN
        PERFORM public.record_audit_log_internal(
            'doctor_document_uploaded',
            COALESCE(v_actor_id, NEW.doctor_id),
            v_actor_role,
            'doctor_document',
            NEW.id,
            'INSERT',
            'success',
            jsonb_build_object(
                'doctor_id', NEW.doctor_id,
                'document_type', NEW.document_type,
                'file_size_bytes', NEW.file_size_bytes,
                'mime_type', NEW.mime_type
            )
        );
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM public.record_audit_log_internal(
            'doctor_document_deleted',
            COALESCE(v_actor_id, OLD.doctor_id),
            v_actor_role,
            'doctor_document',
            OLD.id,
            'DELETE',
            'success',
            jsonb_build_object(
                'doctor_id', OLD.doctor_id,
                'document_type', OLD.document_type
            )
        );
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

ALTER FUNCTION public.audit_doctor_document_lifecycle() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_audit_doctor_documents ON public.doctor_documents;
CREATE TRIGGER trg_audit_doctor_documents
    AFTER INSERT OR DELETE ON public.doctor_documents
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_doctor_document_lifecycle();

-- -----------------------------------------------------------------------------
-- 6.4 Profiles Role Mutation Audit Trigger
--     Captures role changes (e.g. patient -> doctor upon Part 5 admin approval).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.audit_profile_role_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_actor_id UUID;
    v_actor_role TEXT;
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        v_actor_id := auth.uid();
        IF v_actor_id IS NULL THEN
            v_actor_role := 'system';
        ELSIF public.is_admin() THEN
            v_actor_role := 'admin';
        ELSE
            v_actor_role := 'patient';
        END IF;

        PERFORM public.record_audit_log_internal(
            'profile_role_changed',
            COALESCE(v_actor_id, NEW.id),
            v_actor_role,
            'profile',
            NEW.id,
            'UPDATE_ROLE',
            'success',
            jsonb_build_object(
                'target_profile_id', NEW.id,
                'old_role', OLD.role,
                'new_role', NEW.role
            )
        );
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.audit_profile_role_lifecycle() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_audit_profile_role ON public.profiles;
CREATE TRIGGER trg_audit_profile_role
    AFTER UPDATE OF role ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_profile_role_lifecycle();


-- =============================================================================
-- SECTION 7: OPERATIONAL & ADMINISTRATIVE RPC INTERFACES
-- =============================================================================
-- Part 6 provides 5 callable RPC functions in total:
--   1. Operational Telemetry Ingestion RPC (callable by clients/edge functions):
--      - public.record_telemetry_event
--   2. Four Administrative Query & Telemetry RPCs (strictly gated to is_admin):
--      - public.admin_list_audit_logs
--      - public.admin_get_audit_stats
--      - public.admin_list_telemetry_events
--      - public.admin_get_telemetry_summary
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 7.1 public.record_telemetry_event
--     Callable by client applications or Edge Functions to report errors,
--     performance metrics, and system warnings safely.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_telemetry_event(
    p_component TEXT,
    p_event_name TEXT,
    p_severity TEXT DEFAULT 'info',
    p_error_code TEXT DEFAULT NULL,
    p_telemetry_data JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_telemetry_id UUID;
    v_actor_id UUID;
    v_sanitized_data JSONB;
    v_severity_clean TEXT;
BEGIN
    IF p_component IS NULL OR length(trim(p_component)) = 0 THEN
        RAISE EXCEPTION 'Telemetry component is required (code: MISSING_COMPONENT)';
    END IF;

    IF p_event_name IS NULL OR length(trim(p_event_name)) = 0 THEN
        RAISE EXCEPTION 'Telemetry event name is required (code: MISSING_EVENT_NAME)';
    END IF;

    v_severity_clean := lower(trim(COALESCE(p_severity, 'info')));
    IF v_severity_clean NOT IN ('info', 'warning', 'error', 'critical') THEN
        v_severity_clean := 'info';
    END IF;

    v_actor_id := auth.uid();

    -- Scrub credentials, tokens, and patient complaints from telemetry data
    v_sanitized_data := p_telemetry_data - ARRAY[
        'token', 'jwt', 'password', 'secret', 'key', 'auth', 'bearer',
        'chief_complaint', 'symptoms', 'medical_notes', 'signed_url', 'view_url'
    ];

    INSERT INTO public.operational_telemetry (
        component,
        event_name,
        severity,
        error_code,
        actor_id,
        telemetry_data,
        created_at
    ) VALUES (
        trim(p_component),
        trim(p_event_name),
        v_severity_clean,
        trim(p_error_code),
        v_actor_id,
        v_sanitized_data,
        clock_timestamp()
    ) RETURNING id INTO v_telemetry_id;

    RETURN v_telemetry_id;
END;
$$;

ALTER FUNCTION public.record_telemetry_event(TEXT, TEXT, TEXT, TEXT, JSONB) OWNER TO postgres;
COMMENT ON FUNCTION public.record_telemetry_event(TEXT, TEXT, TEXT, TEXT, JSONB)
    IS 'Logs sanitized operational telemetry, component errors, and system warnings';

-- -----------------------------------------------------------------------------
-- 7.2 public.admin_list_audit_logs
--     Administrator-only paginated listing of system audit trail.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_audit_logs(
    p_event_type TEXT DEFAULT NULL,
    p_actor_id UUID DEFAULT NULL,
    p_resource_id UUID DEFAULT NULL,
    p_resource_type TEXT DEFAULT NULL,
    p_from_date TIMESTAMPTZ DEFAULT NULL,
    p_to_date TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id UUID;
    v_limit INT;
    v_offset INT;
    v_total_count BIGINT;
    v_records JSONB;
BEGIN
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL OR NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: administrator privileges required to access audit logs (code: ADMIN_REQUIRED)'
            USING ERRCODE = '42501';
    END IF;

    v_limit := CASE WHEN p_limit IS NULL OR p_limit < 1 THEN 50 WHEN p_limit > 100 THEN 100 ELSE p_limit END;
    v_offset := CASE WHEN p_offset IS NULL OR p_offset < 0 THEN 0 ELSE p_offset END;

    -- Count total matching audit records
    SELECT count(*) INTO v_total_count
    FROM public.audit_logs al
    WHERE (p_event_type IS NULL OR al.event_type = p_event_type)
      AND (p_actor_id IS NULL OR al.actor_id = p_actor_id)
      AND (p_resource_id IS NULL OR al.resource_id = p_resource_id)
      AND (p_resource_type IS NULL OR al.resource_type = p_resource_type)
      AND (p_from_date IS NULL OR al.created_at >= p_from_date)
      AND (p_to_date IS NULL OR al.created_at <= p_to_date);

    -- Fetch paginated results
    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO v_records
    FROM (
        SELECT
            al.id,
            al.event_type,
            al.actor_id,
            p.full_name AS actor_name,
            al.actor_role,
            al.resource_type,
            al.resource_id,
            al.action,
            al.outcome,
            al.event_metadata,
            al.correlation_id,
            al.created_at
        FROM public.audit_logs al
        LEFT JOIN public.profiles p ON p.id = al.actor_id
        WHERE (p_event_type IS NULL OR al.event_type = p_event_type)
          AND (p_actor_id IS NULL OR al.actor_id = p_actor_id)
          AND (p_resource_id IS NULL OR al.resource_id = p_resource_id)
          AND (p_resource_type IS NULL OR al.resource_type = p_resource_type)
          AND (p_from_date IS NULL OR al.created_at >= p_from_date)
          AND (p_to_date IS NULL OR al.created_at <= p_to_date)
        ORDER BY al.created_at DESC
        LIMIT v_limit
        OFFSET v_offset
    ) item;

    RETURN jsonb_build_object(
        'total_count', v_total_count,
        'limit', v_limit,
        'offset', v_offset,
        'audit_logs', v_records
    );
END;
$$;

ALTER FUNCTION public.admin_list_audit_logs(TEXT, UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_list_audit_logs(TEXT, UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT)
    IS 'Administrator-only query function for paginated audit log inspection and compliance verification';

-- -----------------------------------------------------------------------------
-- 7.3 public.admin_get_audit_stats
--     Provides aggregated event metrics for administrative dashboard compliance widgets.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_audit_stats(
    p_timeframe_days INT DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id UUID;
    v_days INT;
    v_cutoff TIMESTAMPTZ;
    v_total_events BIGINT;
    v_event_counts JSONB;
BEGIN
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL OR NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: administrator privileges required (code: ADMIN_REQUIRED)'
            USING ERRCODE = '42501';
    END IF;

    v_days := CASE WHEN p_timeframe_days IS NULL OR p_timeframe_days < 1 THEN 30 ELSE p_timeframe_days END;
    v_cutoff := clock_timestamp() - (v_days || ' days')::interval;

    SELECT count(*) INTO v_total_events
    FROM public.audit_logs
    WHERE created_at >= v_cutoff;

    SELECT COALESCE(jsonb_object_agg(event_type, event_count), '{}'::jsonb) INTO v_event_counts
    FROM (
        SELECT event_type, count(*) AS event_count
        FROM public.audit_logs
        WHERE created_at >= v_cutoff
        GROUP BY event_type
        ORDER BY event_count DESC
    ) ec;

    RETURN jsonb_build_object(
        'timeframe_days', v_days,
        'since', v_cutoff,
        'total_events', v_total_events,
        'event_distribution', v_event_counts
    );
END;
$$;

ALTER FUNCTION public.admin_get_audit_stats(INT) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_get_audit_stats(INT)
    IS 'Administrator-only summary function aggregating audit event volumes over a specified day window';

-- -----------------------------------------------------------------------------
-- 7.4 public.admin_list_telemetry_events
--     Administrator-only paginated listing of system telemetry and errors.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_telemetry_events(
    p_severity TEXT DEFAULT NULL,
    p_component TEXT DEFAULT NULL,
    p_from_date TIMESTAMPTZ DEFAULT NULL,
    p_limit INT DEFAULT 50,
    p_offset INT DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id UUID;
    v_limit INT;
    v_offset INT;
    v_total_count BIGINT;
    v_records JSONB;
BEGIN
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL OR NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: administrator privileges required (code: ADMIN_REQUIRED)'
            USING ERRCODE = '42501';
    END IF;

    v_limit := CASE WHEN p_limit IS NULL OR p_limit < 1 THEN 50 WHEN p_limit > 100 THEN 100 ELSE p_limit END;
    v_offset := CASE WHEN p_offset IS NULL OR p_offset < 0 THEN 0 ELSE p_offset END;

    SELECT count(*) INTO v_total_count
    FROM public.operational_telemetry ot
    WHERE (p_severity IS NULL OR ot.severity = lower(trim(p_severity)))
      AND (p_component IS NULL OR ot.component = trim(p_component))
      AND (p_from_date IS NULL OR ot.created_at >= p_from_date);

    SELECT COALESCE(jsonb_agg(item), '[]'::jsonb) INTO v_records
    FROM (
        SELECT
            ot.id,
            ot.component,
            ot.event_name,
            ot.severity,
            ot.error_code,
            ot.actor_id,
            ot.telemetry_data,
            ot.created_at
        FROM public.operational_telemetry ot
        WHERE (p_severity IS NULL OR ot.severity = lower(trim(p_severity)))
          AND (p_component IS NULL OR ot.component = trim(p_component))
          AND (p_from_date IS NULL OR ot.created_at >= p_from_date)
        ORDER BY ot.created_at DESC
        LIMIT v_limit
        OFFSET v_offset
    ) item;

    RETURN jsonb_build_object(
        'total_count', v_total_count,
        'limit', v_limit,
        'offset', v_offset,
        'telemetry_events', v_records
    );
END;
$$;

ALTER FUNCTION public.admin_list_telemetry_events(TEXT, TEXT, TIMESTAMPTZ, INT, INT) OWNER TO postgres;
COMMENT ON FUNCTION public.admin_list_telemetry_events(TEXT, TEXT, TIMESTAMPTZ, INT, INT)
    IS 'Administrator-only query function for operational diagnostic and error telemetry';

-- -----------------------------------------------------------------------------
-- 7.5 public.admin_get_telemetry_summary
--     Provides operational health overview (error counts, critical alarms).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_get_telemetry_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_admin_id UUID;
    v_errors_24h BIGINT;
    v_critical_24h BIGINT;
    v_warnings_24h BIGINT;
    v_component_errors JSONB;
BEGIN
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL OR NOT public.is_admin() THEN
        RAISE EXCEPTION 'Access denied: administrator privileges required (code: ADMIN_REQUIRED)'
            USING ERRCODE = '42501';
    END IF;

    SELECT
        COUNT(*) FILTER (WHERE severity IN ('error', 'critical')),
        COUNT(*) FILTER (WHERE severity = 'critical'),
        COUNT(*) FILTER (WHERE severity = 'warning')
    INTO v_errors_24h, v_critical_24h, v_warnings_24h
    FROM public.operational_telemetry
    WHERE created_at >= clock_timestamp() - INTERVAL '24 hours';

    SELECT COALESCE(jsonb_object_agg(component, err_count), '{}'::jsonb) INTO v_component_errors
    FROM (
        SELECT component, count(*) AS err_count
        FROM public.operational_telemetry
        WHERE created_at >= clock_timestamp() - INTERVAL '24 hours'
          AND severity IN ('error', 'critical')
        GROUP BY component
        ORDER BY err_count DESC
    ) ce;

    RETURN jsonb_build_object(
        'errors_last_24h', v_errors_24h,
        'critical_last_24h', v_critical_24h,
        'warnings_last_24h', v_warnings_24h,
        'component_errors_last_24h', v_component_errors,
        'evaluated_at', clock_timestamp()
    );
END;
$$;

ALTER FUNCTION public.admin_get_telemetry_summary() OWNER TO postgres;
COMMENT ON FUNCTION public.admin_get_telemetry_summary()
    IS 'Administrator-only diagnostic health summary for operational monitoring';


-- =============================================================================
-- SECTION 8: ROW LEVEL SECURITY & LEAST-PRIVILEGE GRANTS
-- =============================================================================

-- 8.1 Enable RLS on Audit and Telemetry Tables
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operational_telemetry ENABLE ROW LEVEL SECURITY;

-- 8.2 Revoke Default Privileges
REVOKE ALL ON TABLE public.audit_logs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.operational_telemetry FROM PUBLIC, anon, authenticated;

-- 8.3 Grant Controlled SELECT to Authenticated Users (Gated by RLS Policies)
GRANT SELECT ON TABLE public.audit_logs TO authenticated;
GRANT SELECT ON TABLE public.operational_telemetry TO authenticated;

-- 8.4 RLS Policies for public.audit_logs
DROP POLICY IF EXISTS "audit_logs: admin read only" ON public.audit_logs;
CREATE POLICY "audit_logs: admin read only"
    ON public.audit_logs
    FOR SELECT
    TO authenticated
    USING (public.is_admin() = true);

-- Note: No client INSERT, UPDATE, or DELETE policies exist.
-- Append mutations occur strictly through internal SECURITY DEFINER functions.

-- 8.5 RLS Policies for public.operational_telemetry
DROP POLICY IF EXISTS "telemetry: admin read only" ON public.operational_telemetry;
CREATE POLICY "telemetry: admin read only"
    ON public.operational_telemetry
    FOR SELECT
    TO authenticated
    USING (public.is_admin() = true);

-- 8.6 RPC Execution Grants
REVOKE ALL ON FUNCTION public.record_audit_log_internal(TEXT, UUID, TEXT, TEXT, UUID, TEXT, TEXT, JSONB, TEXT) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.record_telemetry_event(TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_telemetry_event(TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_audit_logs(TEXT, UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_audit_logs(TEXT, UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, INT) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_get_audit_stats(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_audit_stats(INT) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_list_telemetry_events(TEXT, TEXT, TIMESTAMPTZ, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_telemetry_events(TEXT, TEXT, TIMESTAMPTZ, INT, INT) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_get_telemetry_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_telemetry_summary() TO authenticated;


-- =============================================================================
-- SECTION 9: POST-MIGRATION VERIFICATION ASSERTIONS
-- =============================================================================
DO $$
DECLARE
    v_missing TEXT[] := ARRAY[]::TEXT[];
    v_tbl TEXT;
    v_fn TEXT;
BEGIN
    -- Verify created tables
    FOR v_tbl IN SELECT unnest(ARRAY['audit_logs', 'operational_telemetry'])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_tables
            WHERE schemaname = 'public' AND tablename = v_tbl
        ) THEN
            v_missing := array_append(v_missing, 'Table: public.' || v_tbl);
        END IF;
    END LOOP;

    -- Verify triggers
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgname = 'trg_audit_logs_immutability'
    ) THEN
        v_missing := array_append(v_missing, 'Trigger: trg_audit_logs_immutability');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_trigger
        WHERE tgname = 'trg_telemetry_immutability'
    ) THEN
        v_missing := array_append(v_missing, 'Trigger: trg_telemetry_immutability');
    END IF;

    -- Verify RPCs
    FOR v_fn IN SELECT unnest(ARRAY[
        'record_telemetry_event',
        'admin_list_audit_logs',
        'admin_get_audit_stats',
        'admin_list_telemetry_events',
        'admin_get_telemetry_summary'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'public' AND p.proname = v_fn
        ) THEN
            v_missing := array_append(v_missing, 'RPC: public.' || v_fn);
        END IF;
    END LOOP;

    IF array_length(v_missing, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration assertion failure: Missing Part 6 objects: %',
            array_to_string(v_missing, ', ');
    END IF;

    RAISE NOTICE 'VoiceCare Phase 2 Part 6 migration specification verified successfully.';
END $$;
