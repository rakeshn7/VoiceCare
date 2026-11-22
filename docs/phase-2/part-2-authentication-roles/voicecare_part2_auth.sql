-- =============================================================================
-- VoiceCare Phase 2 — Part 2: Authentication and Roles (Final Revision)
-- Target  : PostgreSQL 15+ / Supabase
-- Scope   : Security Helper Functions, Triggers, Public Views, RLS, Grants
-- Status  : NOT YET EXECUTED — review document only
--
-- PREREQUISITE:
-- voicecare_part1_database.sql MUST be executed before running this script.
-- This script attaches authorization logic, triggers, views, RLS policies,
-- and SQL grants onto the Part 1 database foundation.
--
-- Intended Owner: postgres (database superuser / migration executor)
-- Execution order matters. Do not reorder sections.
-- =============================================================================


-- =============================================================================
-- PREFLIGHT ASSERTIONS
-- =============================================================================

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Migration prerequisite failed: voicecare_part2_auth.sql must be executed as the postgres superuser (current_user is "%")',
            current_user;
    END IF;
END $$;


-- =============================================================================
-- SECTION 1: SECURITY HELPER FUNCTIONS
--
-- Hardening:
--   - Intended Owner : postgres (explicitly enforced via ALTER ... OWNER TO)
--   - search_path    : pg_catalog only. All application tables, enums,
--                      and schema objects are fully schema-qualified.
--   - STABLE         : Allows query planner to memoize results per query.
--   - SECURITY DEFINER: Executes with owner privileges, breaking recursive RLS
--                      loops on public.profiles.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1  auth_user_role()
--      Returns the application role of the current authenticated session.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auth_user_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT p.role
    FROM   public.profiles p
    WHERE  p.id = auth.uid();
$$;

ALTER FUNCTION public.auth_user_role() OWNER TO postgres;
COMMENT ON FUNCTION public.auth_user_role() IS 'Returns the public.user_role of the calling authenticated user';


-- ---------------------------------------------------------------------------
-- 1.2  is_admin()
--      Returns true if the authenticated user has role = admin.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT COALESCE(
        (SELECT p.role = 'admin'::public.user_role FROM public.profiles p WHERE p.id = auth.uid()),
        false
    );
$$;

ALTER FUNCTION public.is_admin() OWNER TO postgres;
COMMENT ON FUNCTION public.is_admin() IS 'Returns true if caller has the admin role';


-- ---------------------------------------------------------------------------
-- 1.3  is_doctor()
--      Returns true if the authenticated user has role = doctor.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_doctor()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT COALESCE(
        (SELECT p.role = 'doctor'::public.user_role FROM public.profiles p WHERE p.id = auth.uid()),
        false
    );
$$;

ALTER FUNCTION public.is_doctor() OWNER TO postgres;
COMMENT ON FUNCTION public.is_doctor() IS 'Returns true if caller has the doctor role';


-- ---------------------------------------------------------------------------
-- 1.4  is_patient()
--      Returns true if the authenticated user has role = patient.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_patient()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT COALESCE(
        (SELECT p.role = 'patient'::public.user_role FROM public.profiles p WHERE p.id = auth.uid()),
        false
    );
$$;

ALTER FUNCTION public.is_patient() OWNER TO postgres;
COMMENT ON FUNCTION public.is_patient() IS 'Returns true if caller has the patient role';


-- =============================================================================
-- SECTION 2: ADMIN BOOTSTRAP UTILITY
--
-- Purpose : Promote a specific user UUID to 'admin' in the database.
-- Security:
--   - Intended Owner: postgres.
--   - search_path   : pg_catalog only.
--   - Unconditionally revoked from PUBLIC, anon, and authenticated.
--   - Explicit guards: Rejects any call where auth.uid() is NOT NULL (API calls)
--     or session_user <> 'postgres' (must be direct superuser in SQL Editor).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.bootstrap_admin_role(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    -- Guard: Only direct database administrators (e.g. Supabase Dashboard SQL Editor)
    -- can call this. PostgREST sessions have auth.uid() set or session_user = 'authenticator'.
    IF auth.uid() IS NOT NULL OR session_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Unauthorized: bootstrap_admin_role() can only be called directly by the postgres superuser';
    END IF;

    UPDATE public.profiles
       SET role       = 'admin'::public.user_role,
           updated_at = now()
     WHERE id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profile for UUID % not found. User must register first.', p_user_id;
    END IF;
END;
$$;

ALTER FUNCTION public.bootstrap_admin_role(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.bootstrap_admin_role(UUID) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.bootstrap_admin_role(UUID) IS 'Superuser-only bootstrap function to provision initial admin accounts';


-- =============================================================================
-- SECTION 3: TRIGGER FUNCTIONS & TRIGGERS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  handle_new_user()
--      Fires AFTER INSERT on auth.users.
--      CRITICAL SECURITY RULE:
--        Never trust client-supplied raw_user_meta_data for role assignment.
--        All public registrations strictly receive role = 'patient'.
--        Doctor application and Admin provisioning require trusted workflows.
--      Uses standard SQL syntax for nullif/trim/coalesce (no schema prefix).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_full_name TEXT;
    v_raw_phone TEXT;
    v_phone     TEXT;
BEGIN
    -- Extract full name; fall back to generic placeholder if absent
    v_full_name := nullif(trim(coalesce(NEW.raw_user_meta_data->>'full_name', '')), '');
    IF v_full_name IS NULL THEN
        v_full_name := 'User ' || substring(NEW.id::text, 1, 8);
    END IF;

    -- Validate phone number format (Indian 10-digit mobile starting 6-9)
    v_raw_phone := nullif(trim(coalesce(NEW.raw_user_meta_data->>'phone', '')), '');
    IF v_raw_phone IS NOT NULL AND v_raw_phone ~ '^[6-9][0-9]{9}$' THEN
        v_phone := v_raw_phone;
    ELSE
        v_phone := NULL;
    END IF;

    -- Unconditionally assign 'patient' role. Client-supplied role in metadata is ignored.
    INSERT INTO public.profiles (id, role, full_name, phone)
    VALUES (NEW.id, 'patient'::public.user_role, v_full_name, v_phone)
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ---------------------------------------------------------------------------
-- 3.2  protect_profile_role()
--      Fires BEFORE UPDATE on public.profiles.
--      Blocks users from changing their own role.
--      Maintains server-controlled updated_at timestamp.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_profile_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        -- If called by an API session (auth.uid() is not null)
        IF auth.uid() IS NOT NULL THEN
            -- Non-admins cannot alter roles under any circumstances
            IF NOT public.is_admin() THEN
                RAISE EXCEPTION 'Unauthorized: user role cannot be modified (code: ROLE_LOCK)';
            END IF;

            -- Admins cannot modify their own role (prevents self-demotion or lockout)
            IF auth.uid() = OLD.id THEN
                RAISE EXCEPTION 'Unauthorized: administrators cannot alter their own role (code: SELF_ROLE_LOCK)';
            END IF;
        END IF;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

ALTER FUNCTION public.protect_profile_role() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_protect_profile_role ON public.profiles;
CREATE TRIGGER trg_protect_profile_role
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.protect_profile_role();


-- ---------------------------------------------------------------------------
-- 3.3  protect_doctor_fields()
--      Fires BEFORE UPDATE on public.doctors.
--      Prevents authenticated clients from directly updating is_approved,
--      rating, or review_count. Maintains server-controlled updated_at.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_doctor_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF (
        NEW.is_approved  IS DISTINCT FROM OLD.is_approved
        OR NEW.rating       IS DISTINCT FROM OLD.rating
        OR NEW.review_count IS DISTINCT FROM OLD.review_count
    ) THEN
        IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
            RAISE EXCEPTION
                'Unauthorized: protected doctor fields cannot be modified directly (code: DOCTOR_FIELD_LOCK)';
        END IF;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

ALTER FUNCTION public.protect_doctor_fields() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_protect_doctor_fields ON public.doctors;
CREATE TRIGGER trg_protect_doctor_fields
    BEFORE UPDATE ON public.doctors
    FOR EACH ROW EXECUTE FUNCTION public.protect_doctor_fields();


-- ---------------------------------------------------------------------------
-- 3.4  sync_doctor_approval()
--      Fires AFTER UPDATE OF status on public.doctor_verifications.
--      Synchronizes doctors.is_approved when status transitions to 'approved'.
--      Authoritative source of truth: doctor_verifications.status.
--      Part 5 administrator workflow is the sole application-level update path.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_doctor_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        -- Only confirmed administrators or database superuser can change status
        IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
            RAISE EXCEPTION 'Unauthorized: only administrators can change verification status (code: VERIFICATION_STATUS_LOCK)';
        END IF;

        UPDATE public.doctors
           SET is_approved = (NEW.status = 'approved'::public.verification_status),
               updated_at  = now()
         WHERE id = NEW.doctor_id;
    END IF;

    RETURN NEW;
END;
$$;

ALTER FUNCTION public.sync_doctor_approval() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_sync_doctor_approval ON public.doctor_verifications;
CREATE TRIGGER trg_sync_doctor_approval
    AFTER UPDATE OF status ON public.doctor_verifications
    FOR EACH ROW EXECUTE FUNCTION public.sync_doctor_approval();


-- ---------------------------------------------------------------------------
-- 3.5  set_updated_at()
--      Maintains server-controlled updated_at timestamps on table updates.
--      Attached to patients and doctor_verifications so clients never control timestamps.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

ALTER FUNCTION public.set_updated_at() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_patients_set_updated_at ON public.patients;
CREATE TRIGGER trg_patients_set_updated_at
    BEFORE UPDATE ON public.patients
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_verifications_set_updated_at ON public.doctor_verifications;
CREATE TRIGGER trg_verifications_set_updated_at
    BEFORE UPDATE ON public.doctor_verifications
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- SECTION 4: PUBLIC DIRECTORY VIEWS
--
-- Security properties:
--   - security_invoker = false: executes with view owner permissions so anonymous
--     users can read filtered directory data without direct base table grants.
--   - security_barrier = true: prevents optimizer from pushing caller filters
--     ahead of the view's WHERE clause, mitigating timing attacks.
--   - CURRENT_DATE uses standard SQL keyword syntax.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4.1  public_doctor_directory
--      Exposes safe, non-sensitive doctor details for approved and active doctors.
--      phone, email, and registration numbers are strictly omitted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.public_doctor_directory
WITH (security_invoker = false, security_barrier = true)
AS
SELECT
    d.id               AS doctor_id,
    p.full_name        AS doctor_name,
    p.avatar_url,
    d.specialty,
    d.qualification,
    d.experience_years,
    d.consultation_fee,
    d.languages,
    d.bio,
    d.clinic_name,
    d.clinic_address,
    d.rating,
    d.review_count
FROM   public.doctors  d
JOIN   public.profiles p ON p.id = d.id
WHERE  d.is_approved = true
AND    d.is_active   = true;

ALTER VIEW public.public_doctor_directory OWNER TO postgres;
COMMENT ON VIEW public.public_doctor_directory IS 'Safe public directory of approved and active doctors';


-- ---------------------------------------------------------------------------
-- 4.2  public_doctor_schedules
--      Exposes weekly shift availability windows for approved and active doctors.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.public_doctor_schedules
WITH (security_invoker = false, security_barrier = true)
AS
SELECT
    ds.doctor_id,
    ds.day_of_week,
    ds.start_time,
    ds.end_time,
    ds.slot_duration_minutes
FROM   public.doctor_schedules ds
JOIN   public.doctors          d  ON d.id = ds.doctor_id
WHERE  ds.is_active  = true
AND    d.is_approved = true
AND    d.is_active   = true;

ALTER VIEW public.public_doctor_schedules OWNER TO postgres;
COMMENT ON VIEW public.public_doctor_schedules IS 'Public availability shift windows for approved doctors';


-- ---------------------------------------------------------------------------
-- 4.3  public_doctor_leaves
--      Exposes unavailable calendar dates for approved and active doctors.
--      CRITICAL SECURITY RULE: The private 'reason' column is STRICTLY EXCLUDED.
--      Uses bare CURRENT_DATE keyword.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.public_doctor_leaves
WITH (security_invoker = false, security_barrier = true)
AS
SELECT
    dl.doctor_id,
    dl.leave_date
FROM   public.doctor_leaves dl
JOIN   public.doctors        d  ON d.id = dl.doctor_id
WHERE  dl.leave_date >= CURRENT_DATE
AND    d.is_approved  = true
AND    d.is_active    = true;

ALTER VIEW public.public_doctor_leaves OWNER TO postgres;
COMMENT ON VIEW public.public_doctor_leaves IS 'Unavailable calendar dates for approved doctors without private reasons';


-- =============================================================================
-- SECTION 5: ROW LEVEL SECURITY (RLS) POLICIES
-- =============================================================================

-- Enable Row Level Security on all 9 base tables
ALTER TABLE public.profiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patients             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctors              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_documents     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_schedules     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.doctor_leaves        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.in_app_reminders     ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Surgical policy cleanup: Drop ONLY the policies managed on the 9 tables.
-- Unrelated application policies are preserved.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "profiles: select own or admin"             ON public.profiles;
DROP POLICY IF EXISTS "profiles: update own"                      ON public.profiles;

DROP POLICY IF EXISTS "patients: select own or admin"             ON public.patients;
DROP POLICY IF EXISTS "patients: insert own"                      ON public.patients;
DROP POLICY IF EXISTS "patients: update own or admin"             ON public.patients;

DROP POLICY IF EXISTS "doctors: select approved active or own or admin" ON public.doctors;
DROP POLICY IF EXISTS "doctors: select approved or own or admin"  ON public.doctors;
DROP POLICY IF EXISTS "doctors: insert own"                       ON public.doctors;
DROP POLICY IF EXISTS "doctors: admin insert"                     ON public.doctors;
DROP POLICY IF EXISTS "doctors: update own or admin"              ON public.doctors;

DROP POLICY IF EXISTS "verifications: select own or admin"        ON public.doctor_verifications;
DROP POLICY IF EXISTS "verifications: insert own or admin"        ON public.doctor_verifications;
DROP POLICY IF EXISTS "verifications: admin insert"               ON public.doctor_verifications;
DROP POLICY IF EXISTS "verifications: update admin only"          ON public.doctor_verifications;

DROP POLICY IF EXISTS "documents: select own or admin"            ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: insert own"                     ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: insert own doctor"              ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: insert doctor or admin"         ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: delete own or admin"            ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: delete own doctor or admin"      ON public.doctor_documents;
DROP POLICY IF EXISTS "documents: delete doctor or admin"         ON public.doctor_documents;

DROP POLICY IF EXISTS "schedules: select active approved or own or admin" ON public.doctor_schedules;
DROP POLICY IF EXISTS "schedules: select active or own or admin"  ON public.doctor_schedules;
DROP POLICY IF EXISTS "schedules: manage own or admin"            ON public.doctor_schedules;
DROP POLICY IF EXISTS "schedules: manage own doctor or admin"     ON public.doctor_schedules;

DROP POLICY IF EXISTS "leaves: select own or admin"               ON public.doctor_leaves;
DROP POLICY IF EXISTS "leaves: manage own or admin"               ON public.doctor_leaves;
DROP POLICY IF EXISTS "leaves: manage own doctor or admin"        ON public.doctor_leaves;

DROP POLICY IF EXISTS "appointments: select participant or admin" ON public.appointments;

DROP POLICY IF EXISTS "reminders: select own or admin"            ON public.in_app_reminders;


-- ---------------------------------------------------------------------------
-- 5.1  public.profiles policies
-- ---------------------------------------------------------------------------
CREATE POLICY "profiles: select own or admin"
    ON public.profiles FOR SELECT TO authenticated
    USING (id = auth.uid() OR public.is_admin());

CREATE POLICY "profiles: update own"
    ON public.profiles FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());


-- ---------------------------------------------------------------------------
-- 5.2  public.patients policies
--      Doctors have NO direct access to unrelated patient demographic records.
--      Patients can only read/update their own profile if role = patient.
-- ---------------------------------------------------------------------------
CREATE POLICY "patients: select own or admin"
    ON public.patients FOR SELECT TO authenticated
    USING ((id = auth.uid() AND public.is_patient()) OR public.is_admin());

CREATE POLICY "patients: insert own"
    ON public.patients FOR INSERT TO authenticated
    WITH CHECK (id = auth.uid() AND public.is_patient());

CREATE POLICY "patients: update own or admin"
    ON public.patients FOR UPDATE TO authenticated
    USING ((id = auth.uid() AND public.is_patient()) OR public.is_admin())
    WITH CHECK ((id = auth.uid() AND public.is_patient()) OR public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.3  public.doctors policies
--      Ordinary authenticated users see doctors ONLY if approved and active.
--      Doctors can inspect their own profile; admins can inspect all.
--      Direct client INSERT is revoked (handled via Part 4 RPC).
-- ---------------------------------------------------------------------------
CREATE POLICY "doctors: select approved active or own or admin"
    ON public.doctors FOR SELECT TO authenticated
    USING (
        (is_approved = true AND is_active = true)
        OR (id = auth.uid() AND public.is_doctor())
        OR public.is_admin()
    );

CREATE POLICY "doctors: admin insert"
    ON public.doctors FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY "doctors: update own or admin"
    ON public.doctors FOR UPDATE TO authenticated
    USING ((id = auth.uid() AND public.is_doctor()) OR public.is_admin())
    WITH CHECK ((id = auth.uid() AND public.is_doctor()) OR public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.4  public.doctor_verifications policies
--      Authoritative verification workflow table.
--      Direct client INSERT is revoked (managed via Part 4 RPC).
--      Direct client UPDATE is revoked from clients.
--      Part 5 must update status via a trusted server-side SECURITY DEFINER RPC.
-- ---------------------------------------------------------------------------
CREATE POLICY "verifications: select own or admin"
    ON public.doctor_verifications FOR SELECT TO authenticated
    USING ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin());

CREATE POLICY "verifications: admin insert"
    ON public.doctor_verifications FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY "verifications: update admin only"
    ON public.doctor_verifications FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.5  public.doctor_documents policies
--      Credential metadata: Doctors can manage their own document metadata.
--      Administrators can inspect, insert, and delete document metadata for any doctor.
--      Patients are strictly blocked from all document operations.
-- ---------------------------------------------------------------------------
CREATE POLICY "documents: select own or admin"
    ON public.doctor_documents FOR SELECT TO authenticated
    USING ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin());

CREATE POLICY "documents: insert doctor or admin"
    ON public.doctor_documents FOR INSERT TO authenticated
    WITH CHECK (
        (doctor_id = auth.uid() AND public.is_doctor())
        OR public.is_admin()
    );

CREATE POLICY "documents: delete doctor or admin"
    ON public.doctor_documents FOR DELETE TO authenticated
    USING (
        (doctor_id = auth.uid() AND public.is_doctor())
        OR public.is_admin()
    );


-- ---------------------------------------------------------------------------
-- 5.6  public.doctor_schedules policies
--      Ordinary authenticated users see active schedules ONLY for doctors who
--      are both approved and active.
--      Doctors see all their own shifts (active or inactive, approved or unapproved).
--      Administrators see all schedules.
--      Patients cannot create or manage schedules.
-- ---------------------------------------------------------------------------
CREATE POLICY "schedules: select active approved or own or admin"
    ON public.doctor_schedules FOR SELECT TO authenticated
    USING (
        (doctor_id = auth.uid() AND public.is_doctor())
        OR public.is_admin()
        OR (
            is_active = true
            AND EXISTS (
                SELECT 1
                FROM public.doctors d
                WHERE d.id = doctor_schedules.doctor_id
                  AND d.is_approved = true
                  AND d.is_active = true
            )
        )
    );

CREATE POLICY "schedules: manage own doctor or admin"
    ON public.doctor_schedules FOR ALL TO authenticated
    USING ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin())
    WITH CHECK ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.7  public.doctor_leaves policies
--      Doctor calendar leaves: Patients cannot create/manage leave records.
--      Base table visible only to doctor and admin (reasons protected).
-- ---------------------------------------------------------------------------
CREATE POLICY "leaves: select own or admin"
    ON public.doctor_leaves FOR SELECT TO authenticated
    USING ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin());

CREATE POLICY "leaves: manage own doctor or admin"
    ON public.doctor_leaves FOR ALL TO authenticated
    USING ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin())
    WITH CHECK ((doctor_id = auth.uid() AND public.is_doctor()) OR public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.8  public.appointments policies
--      Direct client INSERT/UPDATE/DELETE revoked; mutations via Part 4 RPCs.
-- ---------------------------------------------------------------------------
CREATE POLICY "appointments: select participant or admin"
    ON public.appointments FOR SELECT TO authenticated
    USING (patient_id = auth.uid() OR doctor_id = auth.uid() OR public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.9  public.in_app_reminders policies
--      Direct client INSERT/UPDATE/DELETE revoked; dismissals via Part 4 RPC.
-- ---------------------------------------------------------------------------
CREATE POLICY "reminders: select own or admin"
    ON public.in_app_reminders FOR SELECT TO authenticated
    USING (patient_id = auth.uid() OR public.is_admin());


-- =============================================================================
-- SECTION 6: EXPLICIT SQL PRIVILEGES (LEAST PRIVILEGE)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 6.1  Deterministic privilege reset: Table-level AND Column-level REVOKEs
--      PostgreSQL does NOT remove column-level privileges when revoking table-level
--      privileges. We explicitly revoke ALL table privileges AND ALL column privileges
--      across all tables to guarantee no stale permissions survive.
-- ---------------------------------------------------------------------------

-- Table-level revokes
REVOKE ALL ON public.profiles             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.patients             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.doctors              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.doctor_verifications FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.doctor_documents     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.doctor_schedules     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.doctor_leaves        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.appointments         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.in_app_reminders     FROM PUBLIC, anon, authenticated;

REVOKE ALL ON public.public_doctor_directory FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.public_doctor_schedules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.public_doctor_leaves    FROM PUBLIC, anon, authenticated;

-- Column-level revokes to wipe any residual column grants from prior migrations
REVOKE ALL (id, role, full_name, phone, avatar_url, created_at, updated_at)
    ON public.profiles FROM PUBLIC, anon, authenticated;

REVOKE ALL (
    id, age_value, age_unit, date_of_birth, gender,
    blood_group, emergency_phone, medical_notes, created_at, updated_at
) ON public.patients FROM PUBLIC, anon, authenticated;

REVOKE ALL (
    id, specialty, qualification, experience_years, consultation_fee,
    languages, bio, clinic_name, clinic_address, is_approved, is_active,
    rating, review_count, created_at, updated_at
) ON public.doctors FROM PUBLIC, anon, authenticated;

REVOKE ALL (
    id, doctor_id, status, registration_number, issuing_authority,
    reviewed_by, reviewed_at, admin_notes, created_at, updated_at
) ON public.doctor_verifications FROM PUBLIC, anon, authenticated;

REVOKE ALL (id, doctor_id, document_type, document_name, storage_path, uploaded_at)
    ON public.doctor_documents FROM PUBLIC, anon, authenticated;

REVOKE ALL (id, doctor_id, day_of_week, start_time, end_time, slot_duration_minutes, is_active, created_at)
    ON public.doctor_schedules FROM PUBLIC, anon, authenticated;

REVOKE ALL (id, doctor_id, leave_date, reason, created_at)
    ON public.doctor_leaves FROM PUBLIC, anon, authenticated;

REVOKE ALL (
    id, patient_id, doctor_id, appointment_date, appointment_time,
    end_time, slot_duration_minutes, status, patient_name, patient_age_value,
    patient_age_unit, patient_phone, chief_complaint, consultation_notes,
    cancellation_reason, cancelled_by, cancelled_at, created_at, updated_at
) ON public.appointments FROM PUBLIC, anon, authenticated;

REVOKE ALL (id, appointment_id, patient_id, scheduled_for, is_sent, is_dismissed, created_at)
    ON public.in_app_reminders FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6.2  GRANT SELECT on public directory views to anon and authenticated
-- ---------------------------------------------------------------------------
GRANT SELECT ON public.public_doctor_directory TO anon, authenticated;
GRANT SELECT ON public.public_doctor_schedules TO anon, authenticated;
GRANT SELECT ON public.public_doctor_leaves    TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6.3  GRANT EXECUTE on Security Helper Functions to authenticated
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.auth_user_role() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auth_user_role() TO authenticated;

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;

REVOKE ALL ON FUNCTION public.is_doctor() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_doctor() TO authenticated;

REVOKE ALL ON FUNCTION public.is_patient() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_patient() TO authenticated;

-- ---------------------------------------------------------------------------
-- 6.4  Explicit column and table grants for authenticated on base tables
--      updated_at is strictly excluded from all client UPDATE grants.
--      doctor_verifications has NO client UPDATE grant (status changes via Part 5 RPC).
-- ---------------------------------------------------------------------------

-- profiles: SELECT granted; UPDATE limited to safe profile columns (role & updated_at locked)
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (full_name, phone, avatar_url) ON public.profiles TO authenticated;

-- patients: SELECT, INSERT granted; UPDATE limited to clinical demographic fields (updated_at locked)
GRANT SELECT, INSERT ON public.patients TO authenticated;
GRANT UPDATE (
    age_value, age_unit, date_of_birth, gender,
    blood_group, emergency_phone, medical_notes
) ON public.patients TO authenticated;

-- doctors: SELECT granted; direct INSERT revoked (handled via Part 4 RPC);
-- UPDATE limited to practice profile fields (is_approved, rating, review_count, updated_at locked)
GRANT SELECT ON public.doctors TO authenticated;
GRANT UPDATE (
    qualification, experience_years, consultation_fee,
    languages, bio, clinic_name, clinic_address, is_active
) ON public.doctors TO authenticated;

-- doctor_verifications: SELECT granted; direct client INSERT and UPDATE revoked.
-- Part 5 must update status via a trusted server-side SECURITY DEFINER RPC.
GRANT SELECT ON public.doctor_verifications TO authenticated;

-- doctor_documents: SELECT, INSERT, DELETE granted; UPDATE revoked (immutable records)
GRANT SELECT, INSERT, DELETE ON public.doctor_documents TO authenticated;

-- doctor_schedules: full management granted; RLS restricts to own doctor or admin
GRANT SELECT, INSERT, UPDATE, DELETE ON public.doctor_schedules TO authenticated;

-- doctor_leaves: full management granted; RLS restricts to own doctor or admin
GRANT SELECT, INSERT, UPDATE, DELETE ON public.doctor_leaves TO authenticated;

-- appointments: SELECT only; mutations strictly reserved for Part 4 RPCs
GRANT SELECT ON public.appointments TO authenticated;

-- in_app_reminders: SELECT only; dismissal strictly reserved for Part 4 RPC
GRANT SELECT ON public.in_app_reminders TO authenticated;

-- =============================================================================
-- END OF PART 2: AUTHENTICATION AND ROLES (FINAL REVISION)
-- Status: REVIEW ONLY — not yet executed on a live database
-- =============================================================================
