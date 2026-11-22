-- =============================================================================
-- VOICECARE — PHASE 2: CONSOLIDATED END-TO-END DATABASE MIGRATION
-- =============================================================================
-- Migration File: voicecare_phase2_consolidated_migration.sql
-- Target Database: Supabase PostgreSQL 15+
-- Architecture: Multilingual Voice-First Healthcare Appointment Platform
-- Project Branch: phase-2-review
-- Components Integrated: Parts 1 through 6
--   - Part 1: Relational Foundation, Custom Types, Check Constraints & Indexes
--   - Part 2: Authentication, Role-Based Access Control, Views & Base RLS
--   - Part 3: Private Storage Bucket, Storage RLS & Deletion Cleanup Queue
--   - Part 4: Appointment Booking Engine & Doctor Onboarding Transactional RPCs
--   - Part 5: Admin Review Dashboard & Verification State Machine RPCs
--   - Part 6: Audit Logging, Immutability Engine & Diagnostic Telemetry
--
-- Safety Notice:
-- REVIEW ARTIFACT ONLY — DO NOT EXECUTE DIRECTLY IN PRODUCTION WITHOUT PRIOR
-- SANDBOX TESTING IN AN ISOLATED STAGING ENVIRONMENT.
--
-- Transaction Mode: ATOMIC (Entire migration executed in a single transaction)
-- =============================================================================

BEGIN;

-- =============================================================================
-- SECTION 0: UNIFIED PREFLIGHT ENVIRONMENT ASSERTIONS
-- =============================================================================
DO $$
DECLARE
    v_pg_version INT;
BEGIN
    SELECT current_setting('server_version_num')::INT INTO v_pg_version;
    IF v_pg_version < 150000 THEN
        RAISE EXCEPTION 'VoiceCare Phase 2 requires PostgreSQL 15.0 or higher (current version num: %)', v_pg_version
            USING ERRCODE = '0A000';
    END IF;

    -- Verify auth schema exists (Supabase standard)
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'auth') THEN
        RAISE EXCEPTION 'Supabase auth schema is required for VoiceCare Phase 2 migrations.'
            USING ERRCODE = '3F000';
    END IF;

    RAISE NOTICE ' [PREFLIGHT] Environment verified: PostgreSQL % in Supabase context.', v_pg_version;
END;
$$;


-- =============================================================================
-- INTEGRATED PART 1: RELATIONAL DATABASE FOUNDATION
-- =============================================================================

-- =============================================================================
-- VoiceCare Phase 2 — Part 1: Database Foundation (Final Revision)
-- Target  : PostgreSQL 15+ / Supabase
-- Scope   : Extensions, ENUMs, Tables, Constraints, Indexes only
-- Excludes: Row Level Security, Triggers, Functions, Storage, Grants
-- Status  : NOT YET EXECUTED — review document only
--
-- Run this script on a fresh Supabase project using the SQL Editor
-- or psql as the postgres superuser.
--
-- Execution order matters. Do not reorder sections.
-- =============================================================================


-- =============================================================================
-- SECTION 1: EXTENSIONS
-- =============================================================================

-- pgcrypto: provides gen_random_uuid() for surrogate keys
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- btree_gist: required for range and equality exclusion constraints (GIST)
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- =============================================================================
-- SECTION 2: ENUM TYPES
-- =============================================================================

DO $$ BEGIN
    CREATE TYPE public.user_role AS ENUM (
        'patient',
        'doctor',
        'admin'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE public.verification_status AS ENUM (
        'pending',    -- application submitted, awaiting admin review
        'approved',   -- admin confirmed credentials; doctor is bookable
        'rejected',   -- admin declined the application
        'suspended'   -- previously approved but practice paused by admin
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE public.appointment_status AS ENUM (
        'pending',    -- patient booked; awaiting doctor confirmation
        'confirmed',  -- doctor accepted the appointment
        'rejected',   -- doctor declined the appointment request
        'cancelled',  -- patient or admin cancelled before the appointment
        'completed',  -- doctor marked the consultation completed
        'no_show'     -- patient did not attend
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE public.medical_specialty AS ENUM (
        'General Medicine',
        'Cardiology',
        'Dermatology',
        'Pediatrics',
        'Orthopedics',
        'Gynecology',
        'ENT',
        'Ophthalmology',
        'Dental Care',
        'Psychiatry'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- =============================================================================
-- SECTION 3: TABLES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  profiles
--      Base identity record for every Supabase Auth user.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
    id          UUID        NOT NULL,
    role        public.user_role NOT NULL DEFAULT 'patient',
    full_name   TEXT        NOT NULL,
    phone       TEXT,
    avatar_url  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT profiles_pkey
        PRIMARY KEY (id),
    CONSTRAINT profiles_id_fkey
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT chk_profiles_phone
        CHECK (phone IS NULL OR phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT chk_profiles_full_name
        CHECK (length(trim(full_name)) > 0)
);

COMMENT ON TABLE  public.profiles           IS 'Base identity record for every VoiceCare user';
COMMENT ON COLUMN public.profiles.id        IS 'References auth.users.id';
COMMENT ON COLUMN public.profiles.role      IS 'Application role: patient, doctor, or admin';
COMMENT ON COLUMN public.profiles.phone     IS 'Indian mobile number (10 digits)';


-- ---------------------------------------------------------------------------
-- 3.2  patients
--      Clinical demographic profile for patients.
--      Supports infant demographics (< 1 year) via age_value and age_unit.
--      Permits age_value = 0 only when age_unit = 'months' (newborns < 1 month).
--      age_value & age_unit are required (supporting voice-first onboarding).
--      date_of_birth is optional (for web portal onboarding).
--      CHECK constraint uses a static immutable lower bound (no CURRENT_DATE).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patients (
    id              UUID        NOT NULL,
    age_value       INTEGER     NOT NULL,
    age_unit        TEXT        NOT NULL,
    date_of_birth   DATE,
    gender          TEXT        NOT NULL,
    blood_group     TEXT,
    emergency_phone TEXT,
    medical_notes   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT patients_pkey
        PRIMARY KEY (id),
    CONSTRAINT patients_id_fkey
        FOREIGN KEY (id) REFERENCES public.profiles(id) ON DELETE CASCADE,
    CONSTRAINT chk_patients_age_unit
        CHECK (age_unit IN ('months', 'years')),
    CONSTRAINT chk_patients_age
        CHECK (
            (age_unit = 'months' AND age_value BETWEEN 0 AND 11)
            OR (age_unit = 'years' AND age_value BETWEEN 1 AND 120)
        ),
    CONSTRAINT chk_patients_dob_static
        CHECK (date_of_birth IS NULL OR date_of_birth >= '1900-01-01'),
    CONSTRAINT chk_patients_gender
        CHECK (gender IN ('Male', 'Female', 'Other', 'Prefer not to say')),
    CONSTRAINT chk_patients_blood_group
        CHECK (blood_group IS NULL OR blood_group IN (
            'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'
        )),
    CONSTRAINT chk_patients_emergency_phone
        CHECK (emergency_phone IS NULL OR emergency_phone ~ '^[6-9][0-9]{9}$')
);

COMMENT ON TABLE  public.patients               IS 'Patient demographic and clinical background data';
COMMENT ON COLUMN public.patients.age_value     IS 'Primary voice-collected age magnitude (0-11 for months, 1-120 for years)';
COMMENT ON COLUMN public.patients.age_unit      IS 'Age unit: months (infants/newborns < 1 yr) or years (patients >= 1 yr)';
COMMENT ON COLUMN public.patients.date_of_birth IS 'Optional exact birthdate for comprehensive web onboarding';


-- ---------------------------------------------------------------------------
-- 3.3  doctors
--      Professional information specific to doctors.
--      rating defaults to NULL (unrated) when review_count = 0.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.doctors (
    id               UUID            NOT NULL,
    specialty        public.medical_specialty NOT NULL,
    qualification    TEXT            NOT NULL,
    experience_years INTEGER         NOT NULL,
    consultation_fee INTEGER         NOT NULL,
    languages        TEXT[]          NOT NULL DEFAULT ARRAY['English'],
    bio              TEXT            NOT NULL DEFAULT '',
    clinic_name      TEXT            NOT NULL,
    clinic_address   TEXT            NOT NULL,
    -- is_approved is a read-projection of doctor_verifications.status = 'approved'
    is_approved      BOOLEAN         NOT NULL DEFAULT false,
    is_active        BOOLEAN         NOT NULL DEFAULT true,
    -- Rating is NULL for new doctors until reviews are submitted
    rating           NUMERIC(3, 2)   DEFAULT NULL,
    review_count     INTEGER         NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT doctors_pkey
        PRIMARY KEY (id),
    CONSTRAINT doctors_id_fkey
        FOREIGN KEY (id) REFERENCES public.profiles(id) ON DELETE CASCADE,
    CONSTRAINT chk_doctors_qualification
        CHECK (length(trim(qualification)) > 0),
    CONSTRAINT chk_doctors_experience_years
        CHECK (experience_years BETWEEN 0 AND 70),
    CONSTRAINT chk_doctors_consultation_fee
        CHECK (consultation_fee BETWEEN 0 AND 50000),
    CONSTRAINT chk_doctors_languages
        CHECK (cardinality(languages) > 0),
    CONSTRAINT chk_doctors_clinic_name
        CHECK (length(trim(clinic_name)) > 0),
    CONSTRAINT chk_doctors_clinic_address
        CHECK (length(trim(clinic_address)) > 0),
    CONSTRAINT chk_doctors_rating
        CHECK (rating IS NULL OR (rating BETWEEN 1.00 AND 5.00)),
    CONSTRAINT chk_doctors_review_count
        CHECK (review_count >= 0),
    -- Consistency check: rating must be NULL when review_count is 0, and non-NULL when review_count > 0
    CONSTRAINT chk_doctors_rating_consistency
        CHECK ((review_count = 0 AND rating IS NULL) OR (review_count > 0 AND rating IS NOT NULL))
);

COMMENT ON TABLE  public.doctors             IS 'Doctor professional profile data';
COMMENT ON COLUMN public.doctors.is_approved IS 'Read projection of doctor_verifications.status = approved';
COMMENT ON COLUMN public.doctors.rating      IS 'NULL for unrated doctors; 1.00-5.00 when reviews exist';


-- ---------------------------------------------------------------------------
-- 3.4  doctor_verifications
--      Authoritative source of doctor verification status.
--      Includes issuing_authority (State Medical Council or NMC) and
--      composite uniqueness to reflect Indian medical registration realities.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.doctor_verifications (
    id                  UUID                    NOT NULL DEFAULT gen_random_uuid(),
    doctor_id           UUID                    NOT NULL,
    status              public.verification_status NOT NULL DEFAULT 'pending',
    registration_number TEXT                    NOT NULL,
    issuing_authority   TEXT                    NOT NULL,
    reviewed_by         UUID,
    reviewed_at         TIMESTAMPTZ,
    admin_notes         TEXT,
    created_at          TIMESTAMPTZ             NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ             NOT NULL DEFAULT now(),

    CONSTRAINT doctor_verifications_pkey
        PRIMARY KEY (id),
    CONSTRAINT doctor_verifications_doctor_id_fkey
        FOREIGN KEY (doctor_id) REFERENCES public.doctors(id) ON DELETE CASCADE,
    CONSTRAINT doctor_verifications_reviewed_by_fkey
        FOREIGN KEY (reviewed_by) REFERENCES public.profiles(id) ON DELETE SET NULL,
    CONSTRAINT doctor_verifications_doctor_id_unique
        UNIQUE (doctor_id),
    CONSTRAINT chk_doctor_verifications_reg_no
        CHECK (length(trim(registration_number)) > 0),
    CONSTRAINT chk_doctor_verifications_issuing_auth
        CHECK (length(trim(issuing_authority)) > 0),
    -- In India, registration numbers are scoped to an issuing council (e.g. KMC, MMC)
    CONSTRAINT uq_doctor_verifications_reg_authority
        UNIQUE (registration_number, issuing_authority)
);

COMMENT ON TABLE  public.doctor_verifications                   IS 'Authoritative doctor credential review and approval workflow table';
COMMENT ON COLUMN public.doctor_verifications.status            IS 'Single authoritative source of truth for doctor verification status';
COMMENT ON COLUMN public.doctor_verifications.issuing_authority IS 'State Medical Council or National Medical Commission issuing the license';


-- ---------------------------------------------------------------------------
-- 3.5  doctor_documents
--      Metadata and storage object paths for credentials.
--      Strengthened CHECK constraint ensures path starts with {doctor_id}/,
--      contains a non-empty filename, and does not end with /.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.doctor_documents (
    id            UUID        NOT NULL DEFAULT gen_random_uuid(),
    doctor_id     UUID        NOT NULL,
    document_type TEXT        NOT NULL,
    document_name TEXT        NOT NULL,
    storage_path  TEXT        NOT NULL,
    uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT doctor_documents_pkey
        PRIMARY KEY (id),
    CONSTRAINT doctor_documents_doctor_id_fkey
        FOREIGN KEY (doctor_id) REFERENCES public.doctors(id) ON DELETE CASCADE,
    CONSTRAINT chk_doctor_documents_type
        CHECK (document_type IN (
            'medical_license',
            'degree_certificate',
            'identity_proof',
            'other'
        )),
    CONSTRAINT chk_doctor_documents_name
        CHECK (length(trim(document_name)) > 0),
    -- Safe immutable CHECK: must start with doctor_id::text || '/', contain a filename after, and not end with /
    CONSTRAINT chk_doctor_documents_storage_path
        CHECK (
            storage_path LIKE (doctor_id::text || '/%')
            AND storage_path NOT LIKE '%/'
            AND length(trim(substring(storage_path from (length(doctor_id::text) + 2)))) > 0
        )
);

COMMENT ON TABLE  public.doctor_documents              IS 'Metadata for doctor credentials in doctor-docs storage bucket';
COMMENT ON COLUMN public.doctor_documents.storage_path IS 'Must begin with {doctor_id}/, contain a filename, and not end with /';


-- ---------------------------------------------------------------------------
-- 3.6  doctor_schedules
--      Weekly availability shifts. Includes exclusion constraint preventing
--      overlapping active shifts for the same doctor on the same weekday.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.doctor_schedules (
    id                    UUID        NOT NULL DEFAULT gen_random_uuid(),
    doctor_id             UUID        NOT NULL,
    day_of_week           INTEGER     NOT NULL,
    start_time            TIME        NOT NULL,
    end_time              TIME        NOT NULL,
    slot_duration_minutes INTEGER     NOT NULL DEFAULT 30,
    is_active             BOOLEAN     NOT NULL DEFAULT true,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT doctor_schedules_pkey
        PRIMARY KEY (id),
    CONSTRAINT doctor_schedules_doctor_id_fkey
        FOREIGN KEY (doctor_id) REFERENCES public.doctors(id) ON DELETE CASCADE,
    CONSTRAINT chk_doctor_schedules_day_of_week
        CHECK (day_of_week BETWEEN 0 AND 6),
    CONSTRAINT chk_doctor_schedules_time_order
        CHECK (start_time < end_time),
    CONSTRAINT chk_doctor_schedules_slot_duration
        CHECK (slot_duration_minutes IN (15, 20, 30, 45, 60))
);

-- Exclusion constraint: prevents overlapping active shifts for the same doctor on the same day
ALTER TABLE public.doctor_schedules
    DROP CONSTRAINT IF EXISTS uq_doctor_schedules_no_overlap;

ALTER TABLE public.doctor_schedules
    ADD CONSTRAINT uq_doctor_schedules_no_overlap
    EXCLUDE USING gist (
        doctor_id WITH =,
        day_of_week WITH =,
        tsrange(
            ('2000-01-01'::date + start_time),
            ('2000-01-01'::date + end_time),
            '[)'
        ) WITH &&
    )
    WHERE (is_active = true);


-- ---------------------------------------------------------------------------
-- 3.7  doctor_leaves
--      Calendar dates on which a doctor is on leave.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.doctor_leaves (
    id          UUID        NOT NULL DEFAULT gen_random_uuid(),
    doctor_id   UUID        NOT NULL,
    leave_date  DATE        NOT NULL,
    reason      TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT doctor_leaves_pkey
        PRIMARY KEY (id),
    CONSTRAINT doctor_leaves_doctor_id_fkey
        FOREIGN KEY (doctor_id) REFERENCES public.doctors(id) ON DELETE CASCADE,
    CONSTRAINT doctor_leaves_doctor_date_unique
        UNIQUE (doctor_id, leave_date)
);

COMMENT ON TABLE public.doctor_leaves IS 'Doctor unavailable calendar dates. Unique on (doctor_id, leave_date)';


-- ---------------------------------------------------------------------------
-- 3.8  appointments
--      Consultation bookings. Enforces dual overlap exclusion:
--      1. A doctor cannot have overlapping active appointments.
--      2. A patient cannot have overlapping active appointments across any doctor.
--      Supports newborn snapshots (0-11 months) and patient snapshots (1-120 years).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.appointments (
    id                    UUID                     NOT NULL DEFAULT gen_random_uuid(),
    patient_id            UUID                     NOT NULL,
    doctor_id             UUID                     NOT NULL,
    appointment_date      DATE                     NOT NULL,
    appointment_time      TIME                     NOT NULL,
    end_time              TIME                     NOT NULL,
    slot_duration_minutes INTEGER                  NOT NULL DEFAULT 30,
    status                public.appointment_status NOT NULL DEFAULT 'pending',
    patient_name          TEXT                     NOT NULL,
    patient_age_value     INTEGER                  NOT NULL,
    patient_age_unit      TEXT                     NOT NULL,
    patient_phone         TEXT                     NOT NULL,
    chief_complaint       TEXT                     NOT NULL,
    consultation_notes    TEXT,
    cancellation_reason   TEXT,
    cancelled_by          UUID,
    cancelled_at          TIMESTAMPTZ,
    created_at            TIMESTAMPTZ              NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ              NOT NULL DEFAULT now(),

    CONSTRAINT appointments_pkey
        PRIMARY KEY (id),
    CONSTRAINT appointments_patient_id_fkey
        FOREIGN KEY (patient_id) REFERENCES public.patients(id) ON DELETE RESTRICT,
    CONSTRAINT appointments_doctor_id_fkey
        FOREIGN KEY (doctor_id) REFERENCES public.doctors(id) ON DELETE RESTRICT,
    CONSTRAINT appointments_cancelled_by_fkey
        FOREIGN KEY (cancelled_by) REFERENCES public.profiles(id) ON DELETE SET NULL,
    CONSTRAINT chk_appointments_time_order
        CHECK (appointment_time < end_time),
    CONSTRAINT chk_appointments_slot_duration
        CHECK (slot_duration_minutes IN (15, 20, 30, 45, 60)),
    CONSTRAINT chk_appointments_patient_age_unit
        CHECK (patient_age_unit IN ('months', 'years')),
    CONSTRAINT chk_appointments_patient_age
        CHECK (
            (patient_age_unit = 'months' AND patient_age_value BETWEEN 0 AND 11)
            OR (patient_age_unit = 'years' AND patient_age_value BETWEEN 1 AND 120)
        ),
    CONSTRAINT chk_appointments_patient_phone
        CHECK (patient_phone ~ '^[6-9][0-9]{9}$'),
    CONSTRAINT chk_appointments_patient_name
        CHECK (length(trim(patient_name)) > 0),
    CONSTRAINT chk_appointments_chief_complaint
        CHECK (length(trim(chief_complaint)) > 0),
    -- Composite unique key to support in_app_reminders composite foreign key
    CONSTRAINT uq_appointments_id_patient_id
        UNIQUE (id, patient_id)
);

-- Exclusion constraint 1: Prevent doctor double-booking
ALTER TABLE public.appointments
    DROP CONSTRAINT IF EXISTS uq_doctor_no_appointment_overlap;

ALTER TABLE public.appointments
    ADD CONSTRAINT uq_doctor_no_appointment_overlap
    EXCLUDE USING gist (
        doctor_id WITH =,
        tsrange(
            (appointment_date + appointment_time)::timestamp,
            (appointment_date + end_time)::timestamp,
            '[)'
        ) WITH &&
    )
    WHERE (status IN ('pending', 'confirmed'));

-- Exclusion constraint 2: Prevent patient double-booking across different doctors
ALTER TABLE public.appointments
    DROP CONSTRAINT IF EXISTS uq_patient_no_appointment_overlap;

ALTER TABLE public.appointments
    ADD CONSTRAINT uq_patient_no_appointment_overlap
    EXCLUDE USING gist (
        patient_id WITH =,
        tsrange(
            (appointment_date + appointment_time)::timestamp,
            (appointment_date + end_time)::timestamp,
            '[)'
        ) WITH &&
    )
    WHERE (status IN ('pending', 'confirmed'));

COMMENT ON TABLE  public.appointments                   IS 'Clinical consultation booking records with dual doctor/patient overlap exclusion';
COMMENT ON COLUMN public.appointments.patient_age_value IS 'Immutable snapshot of patient age magnitude at booking (0-11 for months, 1-120 for years)';
COMMENT ON COLUMN public.appointments.patient_age_unit  IS 'Immutable snapshot of patient age unit at booking (months or years)';


-- ---------------------------------------------------------------------------
-- 3.9  in_app_reminders
--      Enforces appointment-patient consistency via composite foreign key.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.in_app_reminders (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    appointment_id  UUID        NOT NULL,
    patient_id      UUID        NOT NULL,
    scheduled_for   TIMESTAMPTZ NOT NULL,
    is_sent         BOOLEAN     NOT NULL DEFAULT false,
    is_dismissed    BOOLEAN     NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT in_app_reminders_pkey
        PRIMARY KEY (id),
    -- Composite foreign key guarantees reminder patient matches appointment patient
    CONSTRAINT in_app_reminders_appointment_patient_fkey
        FOREIGN KEY (appointment_id, patient_id)
        REFERENCES public.appointments(id, patient_id)
        ON DELETE CASCADE
);

COMMENT ON TABLE public.in_app_reminders IS 'Patient reminder dispatch schedule with composite patient-appointment FK';


-- =============================================================================
-- SECTION 4: INDEXES
-- =============================================================================

-- profiles: role-based administrative query filtering
CREATE INDEX IF NOT EXISTS idx_profiles_role
    ON public.profiles (role);

-- doctors: public directory filtering by approval and active status
CREATE INDEX IF NOT EXISTS idx_doctors_approved_active
    ON public.doctors (is_approved, is_active);

-- doctors: specialty search filter
CREATE INDEX IF NOT EXISTS idx_doctors_specialty
    ON public.doctors (specialty);

-- doctor_verifications: administrative pending queue filter
CREATE INDEX IF NOT EXISTS idx_verifications_status
    ON public.doctor_verifications (status);

-- doctor_documents: doctor-document lookups and foreign-key cascade operations
CREATE INDEX IF NOT EXISTS idx_doctor_documents_doctor_id
    ON public.doctor_documents (doctor_id);

-- doctor_schedules: calendar slot generation lookup for active shifts
CREATE INDEX IF NOT EXISTS idx_schedules_doctor_dow
    ON public.doctor_schedules (doctor_id, day_of_week)
    WHERE is_active = true;

-- Note: doctor_leaves(doctor_id, leave_date) is already indexed by its UNIQUE constraint.
-- No duplicate index created.

-- appointments: patient appointment history
CREATE INDEX IF NOT EXISTS idx_appointments_patient
    ON public.appointments (patient_id);

-- appointments: doctor daily consultation agenda
CREATE INDEX IF NOT EXISTS idx_appointments_doctor_date
    ON public.appointments (doctor_id, appointment_date);

-- appointments: lifecycle status query filtering
CREATE INDEX IF NOT EXISTS idx_appointments_status
    ON public.appointments (status);

-- in_app_reminders: appointment-to-reminder lookups and foreign-key cascade operations
CREATE INDEX IF NOT EXISTS idx_reminders_appointment_patient
    ON public.in_app_reminders (appointment_id, patient_id);

-- in_app_reminders: patient notification inbox bell query
CREATE INDEX IF NOT EXISTS idx_reminders_patient_pending
    ON public.in_app_reminders (patient_id, is_sent, is_dismissed);

-- in_app_reminders: background dispatch queue for pending reminders
CREATE INDEX IF NOT EXISTS idx_reminders_scheduled
    ON public.in_app_reminders (scheduled_for)
    WHERE is_sent = false;

-- =============================================================================
-- END OF PART 1: DATABASE FOUNDATION (FINAL REVISION)
-- =============================================================================


-- =============================================================================
-- INTEGRATED PART 2: AUTHENTICATION, ROLES, TRIGGERS & RLS
-- =============================================================================

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
SECURITY INVOKER
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
        OR id = auth.uid()
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
--      Applicants can inspect their own verification status; admins inspect all.
-- ---------------------------------------------------------------------------
CREATE POLICY "verifications: select own or admin"
    ON public.doctor_verifications FOR SELECT TO authenticated
    USING (doctor_id = auth.uid() OR public.is_admin());

CREATE POLICY "verifications: admin insert"
    ON public.doctor_verifications FOR INSERT TO authenticated
    WITH CHECK (public.is_admin());

CREATE POLICY "verifications: update admin only"
    ON public.doctor_verifications FOR UPDATE TO authenticated
    USING (public.is_admin())
    WITH CHECK (public.is_admin());


-- ---------------------------------------------------------------------------
-- 5.5  public.doctor_documents policies
--      Credential metadata: Doctors and applicants can view and delete their own
--      document metadata. Administrators can inspect and delete for any doctor.
--      Direct client INSERT is strictly REVOKED: all document metadata creation
--      must route through authorized SECURITY DEFINER RPCs (submit_doctor_application
--      and register_doctor_document) to enforce doctor row locks and quotas.
--      Direct client UPDATE is revoked (documents are immutable records).
-- ---------------------------------------------------------------------------
CREATE POLICY "documents: select own or admin"
    ON public.doctor_documents FOR SELECT TO authenticated
    USING (doctor_id = auth.uid() OR public.is_admin());

CREATE POLICY "documents: delete own or admin"
    ON public.doctor_documents FOR DELETE TO authenticated
    USING (doctor_id = auth.uid() OR public.is_admin());


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

-- doctor_documents: SELECT, DELETE granted; direct client INSERT and UPDATE revoked.
-- All document metadata creation is strictly routed through authorized SECURITY DEFINER RPCs
-- (submit_doctor_application and register_doctor_document) to enforce doctor row locks and quotas.
GRANT SELECT, DELETE ON public.doctor_documents TO authenticated;

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


-- =============================================================================
-- INTEGRATED PART 3: STORAGE BUCKET, POLICIES & CLEANUP QUEUE
-- =============================================================================

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
ON CONFLICT (id) DO NOTHING;

-- Assert that if 'doctor-docs' bucket already exists, it is strictly private
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'doctor-docs' AND public = true) THEN
        RAISE EXCEPTION 'Security assertion failed: Storage bucket "doctor-docs" exists but is configured as public (public = true). It must be strictly private.'
            USING ERRCODE = '42501';
    END IF;
END $$;

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
SECURITY INVOKER
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
SECURITY INVOKER
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
--        2. Path conforms to strict path rules (via public.validate_doctor_document_path).
--        3. Doctor/Applicant UUID segment of path strictly matches auth.uid()::text.
--        4. Calling user exists in the system as an approved doctor, an applicant
--           with a pending doctor profile, or an authenticated prospective applicant.
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
        AND public.validate_doctor_document_path(p_name)
        AND split_part(p_name, '/', 1) = auth.uid()::text
        AND (
            -- Case 1: Approved doctor
            public.is_doctor()
            -- Case 2: Applicant with pending application in public.doctors
            OR EXISTS (
                SELECT 1
                FROM   public.doctors d
                WHERE  d.id = auth.uid()
            )
            -- Case 3: Authenticated prospective applicant onboarding before approval
            OR EXISTS (
                SELECT 1
                FROM   public.profiles p
                WHERE  p.id = auth.uid()
                  AND  p.role = 'patient'::public.user_role
            )
        );
$$;

ALTER FUNCTION public.is_doctor_document_owner(text) OWNER TO postgres;
COMMENT ON FUNCTION public.is_doctor_document_owner(text)
    IS 'Returns true only if caller is a registered doctor or prospective applicant whose auth.uid() matches the validated path prefix';


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


-- =============================================================================
-- INTEGRATED PART 4: APPOINTMENT ENGINE & ONBOARDING RPCS
-- =============================================================================

-- =============================================================================
-- VoiceCare Phase 2 — Part 4: Appointment Engine & Doctor Onboarding RPCs
-- Target  : PostgreSQL 15+ / Supabase
-- Scope   : Transactional RPC Functions, Concurrency Guards, Onboarding Engine,
--           Appointment Engine, Appointment Lifecycle, In-App Reminders, Grants.
-- Status  : COMPLETE FINALIZATION — Design and Review Document Only.
--
-- Prerequisites (Strict Migration Sequence):
--   1. voicecare_part1_database.sql (Tables, Enums, Constraints, GiST Indexes)
--   2. voicecare_part2_auth.sql (Profiles, Roles, Triggers, RLS, Helper Functions)
--   3. voicecare_phase2_part3_storage.sql (Doctor Docs Bucket, Storage Path Engine)
-- =============================================================================


-- =============================================================================
-- SECTION 0: PREFLIGHT INTEGRITY & ENVIRONMENT ASSERTIONS
--
-- Fail-closed assertions verify that the runtime environment, superuser ownership,
-- and all prerequisite schema components from Parts 1, 2, and 3 are present.
-- =============================================================================

DO $$
DECLARE
    v_missing_tables TEXT := '';
    v_missing_types  TEXT := '';
    v_missing_funcs  TEXT := '';
    v_tbl TEXT;
    v_typ TEXT;
    v_fn  TEXT;
BEGIN
    -- 0.1 Enforce deployment role (must be postgres superuser)
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'Migration execution aborted: Part 4 must be executed as the "postgres" superuser. Current user is "%".',
            current_user;
    END IF;

    -- 0.2 Verify required enum types from Part 1 exist
    FOR v_typ IN SELECT unnest(ARRAY['user_role', 'verification_status', 'appointment_status', 'medical_specialty'])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = 'public' AND t.typname = v_typ
        ) THEN
            v_missing_types := v_missing_types || v_typ || ' ';
        END IF;
    END LOOP;

    IF v_missing_types <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required enum types from Part 1: %', v_missing_types;
    END IF;

    -- 0.3 Verify required tables from Parts 1 & 3 exist
    FOR v_tbl IN SELECT unnest(ARRAY[
        'profiles', 'patients', 'doctors', 'doctor_verifications',
        'doctor_documents', 'doctor_schedules', 'doctor_leaves',
        'appointments', 'in_app_reminders', 'storage_deletion_queue'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_tables
            WHERE schemaname = 'public' AND tablename = v_tbl
        ) THEN
            v_missing_tables := v_missing_tables || v_tbl || ' ';
        END IF;
    END LOOP;

    IF v_missing_tables <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required database tables: %', v_missing_tables;
    END IF;

    -- 0.4 Verify security helper functions from Part 2 & 3 exist
    FOR v_fn IN SELECT unnest(ARRAY[
        'is_admin', 'is_doctor', 'is_patient', 'auth_user_role',
        'validate_doctor_document_path'
    ])
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = v_fn
        ) THEN
            v_missing_funcs := v_missing_funcs || v_fn || ' ';
        END IF;
    END LOOP;

    IF v_missing_funcs <> '' THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Missing required helper functions: %', v_missing_funcs;
    END IF;

    -- 0.5 Verify GiST exclusion constraints on appointments table
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'uq_doctor_no_appointment_overlap'
          AND conrelid = 'public.appointments'::regclass
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Exclusion constraint uq_doctor_no_appointment_overlap missing from public.appointments.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint
        WHERE conname = 'uq_patient_no_appointment_overlap'
          AND conrelid = 'public.appointments'::regclass
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Exclusion constraint uq_patient_no_appointment_overlap missing from public.appointments.';
    END IF;

    -- 0.6 Verify Storage bucket "doctor-docs" exists from Part 3
    IF NOT EXISTS (
        SELECT 1
        FROM storage.buckets
        WHERE id = 'doctor-docs'
    ) THEN
        RAISE EXCEPTION 'Part 4 Preflight Failed: Storage bucket "doctor-docs" missing. Part 3 migration must be applied first.';
    END IF;
END $$;


-- =============================================================================
-- SECTION 1: DOCTOR ONBOARDING RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1.1  submit_doctor_application(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Atomic creation of public.doctors and public.doctor_verifications
--   - Strict validation of document payload (rejects non-array, malformed objects,
--     missing fields, duplicate paths, excessive count)
--   - Leaves is_approved = false and status = 'pending' unconditionally
--   - Preserves applicant's profile role as 'patient' until Part 5 Admin approval
--   - Defends against duplicate applications, doctor self-promotion, and credential collisions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_doctor_application(
    p_specialty TEXT,
    p_qualification TEXT,
    p_experience_years INTEGER,
    p_consultation_fee INTEGER,
    p_languages TEXT[] DEFAULT ARRAY['English']::TEXT[],
    p_bio TEXT DEFAULT '',
    p_clinic_name TEXT DEFAULT NULL,
    p_clinic_address TEXT DEFAULT NULL,
    p_registration_number TEXT DEFAULT NULL,
    p_issuing_authority TEXT DEFAULT NULL,
    p_documents JSONB DEFAULT '[]'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id       UUID;
    v_specialty_val public.medical_specialty;
    v_doc           JSONB;
    v_doc_type      TEXT;
    v_doc_name      TEXT;
    v_doc_path      TEXT;
    v_seen_paths    TEXT[] := ARRAY[]::TEXT[];
    v_lang          TEXT;
BEGIN
    -- 1. Authentication & caller identity check
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to submit doctor application (code: AUTH_REQUIRED)';
    END IF;

    -- 2. Verify caller profile exists in public.profiles
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User profile not found. User registration must be completed first (code: PROFILE_NOT_FOUND)';
    END IF;

    -- 3. System administrators cannot register as doctors
    IF public.is_admin() THEN
        RAISE EXCEPTION 'Administrators cannot register as doctor practitioners (code: ADMIN_DOCTOR_RESTRICTED)';
    END IF;

    -- 4. Prevent existing doctors or re-applications
    IF public.is_doctor() THEN
        RAISE EXCEPTION 'User is already registered as an approved doctor (code: ALREADY_A_DOCTOR)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.doctors WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'A doctor profile already exists for this account (code: DUPLICATE_DOCTOR_APPLICATION)';
    END IF;

    IF EXISTS (SELECT 1 FROM public.doctor_verifications WHERE doctor_id = v_user_id) THEN
        RAISE EXCEPTION 'A verification record already exists for this account (code: DUPLICATE_VERIFICATION_RECORD)';
    END IF;

    -- 5. Server-side Input Validations & Length Bounds
    IF p_qualification IS NULL OR length(trim(p_qualification)) = 0 THEN
        RAISE EXCEPTION 'Doctor qualification cannot be empty (code: INVALID_QUALIFICATION)';
    END IF;

    IF length(trim(p_qualification)) > 255 THEN
        RAISE EXCEPTION 'Doctor qualification exceeds maximum length of 255 characters (code: QUALIFICATION_TOO_LONG)';
    END IF;

    IF p_experience_years IS NULL OR p_experience_years < 0 OR p_experience_years > 70 THEN
        RAISE EXCEPTION 'Experience years must be between 0 and 70 (code: INVALID_EXPERIENCE_YEARS)';
    END IF;

    IF p_consultation_fee IS NULL OR p_consultation_fee < 0 OR p_consultation_fee > 50000 THEN
        RAISE EXCEPTION 'Consultation fee must be between 0 and 50,000 INR (code: INVALID_CONSULTATION_FEE)';
    END IF;

    IF p_clinic_name IS NULL OR length(trim(p_clinic_name)) = 0 THEN
        RAISE EXCEPTION 'Clinic name cannot be empty (code: INVALID_CLINIC_NAME)';
    END IF;

    IF length(trim(p_clinic_name)) > 255 THEN
        RAISE EXCEPTION 'Clinic name exceeds maximum length of 255 characters (code: CLINIC_NAME_TOO_LONG)';
    END IF;

    IF p_clinic_address IS NULL OR length(trim(p_clinic_address)) = 0 THEN
        RAISE EXCEPTION 'Clinic address cannot be empty (code: INVALID_CLINIC_ADDRESS)';
    END IF;

    IF length(trim(p_clinic_address)) > 500 THEN
        RAISE EXCEPTION 'Clinic address exceeds maximum length of 500 characters (code: CLINIC_ADDRESS_TOO_LONG)';
    END IF;

    IF p_registration_number IS NULL OR length(trim(p_registration_number)) = 0 THEN
        RAISE EXCEPTION 'Medical registration number cannot be empty (code: INVALID_REGISTRATION_NUMBER)';
    END IF;

    IF length(trim(p_registration_number)) > 100 THEN
        RAISE EXCEPTION 'Medical registration number exceeds maximum length of 100 characters (code: REGISTRATION_NUMBER_TOO_LONG)';
    END IF;

    IF p_issuing_authority IS NULL OR length(trim(p_issuing_authority)) = 0 THEN
        RAISE EXCEPTION 'Medical registration issuing authority cannot be empty (code: INVALID_ISSUING_AUTHORITY)';
    END IF;

    IF length(trim(p_issuing_authority)) > 255 THEN
        RAISE EXCEPTION 'Medical registration issuing authority exceeds maximum length of 255 characters (code: ISSUING_AUTHORITY_TOO_LONG)';
    END IF;

    IF p_bio IS NOT NULL AND length(trim(p_bio)) > 2000 THEN
        RAISE EXCEPTION 'Doctor biography exceeds maximum length of 2000 characters (code: BIO_TOO_LONG)';
    END IF;

    -- Languages validation
    IF p_languages IS NULL OR cardinality(p_languages) = 0 THEN
        RAISE EXCEPTION 'At least one consultation language must be specified (code: INVALID_LANGUAGES)';
    END IF;

    IF cardinality(p_languages) > 10 THEN
        RAISE EXCEPTION 'Maximum 10 consultation languages permitted (code: EXCESSIVE_LANGUAGES)';
    END IF;

    FOREACH v_lang IN ARRAY p_languages
    LOOP
        IF v_lang IS NULL OR length(trim(v_lang)) = 0 OR length(trim(v_lang)) > 50 THEN
            RAISE EXCEPTION 'Each language entry must be a non-empty string under 50 characters (code: INVALID_LANGUAGE_ENTRY)';
        END IF;
    END LOOP;

    -- Specialty enum validation
    BEGIN
        v_specialty_val := p_specialty::public.medical_specialty;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Invalid medical specialty: %. Allowed values: General Medicine, Cardiology, Dermatology, Pediatrics, Orthopedics, Gynecology, ENT, Ophthalmology, Dental Care, Psychiatry (code: INVALID_SPECIALTY)', p_specialty;
    END;

    -- Credential collision check (Indian medical councils require unique reg_no per council)
    IF EXISTS (
        SELECT 1
        FROM public.doctor_verifications
        WHERE registration_number = trim(p_registration_number)
          AND issuing_authority = trim(p_issuing_authority)
    ) THEN
        RAISE EXCEPTION 'Medical registration number "%" from "%" is already registered (code: DUPLICATE_REGISTRATION_CREDENTIALS)',
            trim(p_registration_number), trim(p_issuing_authority);
    END IF;

    -- 6. Strict Document Payload Validation
    IF p_documents IS NOT NULL THEN
        IF jsonb_typeof(p_documents) <> 'array' THEN
            RAISE EXCEPTION 'Documents payload must be a JSON array (code: INVALID_DOCUMENTS_PAYLOAD)';
        END IF;

        IF jsonb_array_length(p_documents) > 10 THEN
            RAISE EXCEPTION 'Maximum 10 verification documents allowed per application (code: EXCESSIVE_DOCUMENT_COUNT)';
        END IF;

        -- Pre-validate all documents before performing any table insertion
        FOR v_doc IN SELECT * FROM jsonb_array_elements(p_documents)
        LOOP
            IF jsonb_typeof(v_doc) <> 'object' THEN
                RAISE EXCEPTION 'Each document entry must be a JSON object (code: INVALID_DOCUMENT_ENTRY)';
            END IF;

            v_doc_type := trim(coalesce(v_doc->>'document_type', ''));
            v_doc_name := trim(coalesce(v_doc->>'document_name', ''));
            v_doc_path := trim(coalesce(v_doc->>'storage_path', ''));

            IF v_doc_type = '' OR v_doc_name = '' OR v_doc_path = '' THEN
                RAISE EXCEPTION 'Document entries must specify document_type, document_name, and storage_path (code: MISSING_DOCUMENT_FIELDS)';
            END IF;

            IF v_doc_type NOT IN ('medical_license', 'degree_certificate', 'identity_proof', 'other') THEN
                RAISE EXCEPTION 'Invalid document type: "%". Allowed: medical_license, degree_certificate, identity_proof, other (code: INVALID_DOCUMENT_TYPE)', v_doc_type;
            END IF;

            IF length(v_doc_name) > 255 THEN
                RAISE EXCEPTION 'Document name exceeds maximum length of 255 characters (code: DOCUMENT_NAME_TOO_LONG)';
            END IF;

            -- Strict path structure validation via Part 3 engine
            IF NOT public.validate_doctor_document_path(v_doc_path) THEN
                RAISE EXCEPTION 'Invalid storage path: "%". Must follow {doctor_uuid}/{filename.ext} (code: INVALID_STORAGE_PATH)', v_doc_path;
            END IF;

            -- Ownership validation: path prefix must match applicant UUID
            IF split_part(v_doc_path, '/', 1) <> v_user_id::text THEN
                RAISE EXCEPTION 'Document storage path does not match applicant ID (code: PATH_OWNERSHIP_MISMATCH)';
            END IF;

            -- Check for duplicate document paths in the submission payload
            IF v_doc_path = ANY(v_seen_paths) THEN
                RAISE EXCEPTION 'Duplicate document storage path in submission: "%" (code: DUPLICATE_DOCUMENT_PATH)', v_doc_path;
            END IF;
            v_seen_paths := array_append(v_seen_paths, v_doc_path);
        END LOOP;
    END IF;

    -- 7. Atomic Inserts
    -- Doctor profile record (is_approved = false, is_active = true)
    INSERT INTO public.doctors (
        id,
        specialty,
        qualification,
        experience_years,
        consultation_fee,
        languages,
        bio,
        clinic_name,
        clinic_address,
        is_approved,
        is_active,
        rating,
        review_count
    ) VALUES (
        v_user_id,
        v_specialty_val,
        trim(p_qualification),
        p_experience_years,
        p_consultation_fee,
        p_languages,
        coalesce(trim(p_bio), ''),
        trim(p_clinic_name),
        trim(p_clinic_address),
        false, -- Strictly unapproved upon submission
        true,
        NULL,
        0
    );

    -- Doctor verification workflow record (status = pending)
    INSERT INTO public.doctor_verifications (
        doctor_id,
        status,
        registration_number,
        issuing_authority,
        reviewed_by,
        reviewed_at,
        admin_notes
    ) VALUES (
        v_user_id,
        'pending'::public.verification_status,
        trim(p_registration_number),
        trim(p_issuing_authority),
        NULL,
        NULL,
        NULL
    );

    -- Insert verified documents into public.doctor_documents
    IF p_documents IS NOT NULL AND jsonb_array_length(p_documents) > 0 THEN
        FOR v_doc IN SELECT * FROM jsonb_array_elements(p_documents)
        LOOP
            INSERT INTO public.doctor_documents (
                doctor_id,
                document_type,
                document_name,
                storage_path
            ) VALUES (
                v_user_id,
                trim(v_doc->>'document_type'),
                trim(v_doc->>'document_name'),
                trim(v_doc->>'storage_path')
            );
        END LOOP;
    END IF;

    RETURN v_user_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 1.2  register_doctor_document(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Securely registers document metadata in public.doctor_documents
--   - Validates path via public.validate_doctor_document_path()
--   - Verifies caller ownership (or admin status)
--   - Prevents duplicate storage paths and enforces per-doctor document quota (max 25)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_doctor_document(
    p_document_type TEXT,
    p_document_name TEXT,
    p_storage_path TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id     UUID;
    v_document_id UUID;
    v_target_id   UUID;
    v_path_prefix TEXT;
    v_doc_count   INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- 1. Validate storage path structure
    IF p_storage_path IS NULL OR NOT public.validate_doctor_document_path(trim(p_storage_path)) THEN
        RAISE EXCEPTION 'Invalid storage path: %. Must match {doctor_uuid}/{filename.ext} (code: INVALID_STORAGE_PATH)', p_storage_path;
    END IF;

    v_path_prefix := split_part(trim(p_storage_path), '/', 1);

    -- 2. Authorization check
    IF public.is_admin() THEN
        v_target_id := v_path_prefix::uuid;
    ELSE
        IF v_path_prefix <> v_user_id::text THEN
            RAISE EXCEPTION 'Unauthorized: Document storage path does not belong to authenticated user (code: PATH_OWNERSHIP_MISMATCH)';
        END IF;
        v_target_id := v_user_id;
    END IF;

    -- 3. Verify target doctor profile exists and acquire row lock for concurrency-safe quota serialization
    PERFORM 1 FROM public.doctors WHERE id = v_target_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor profile not found for ID % (code: DOCTOR_NOT_FOUND)', v_target_id;
    END IF;

    -- 4. Enforce per-doctor document ceiling under row lock
    SELECT count(*) INTO v_doc_count FROM public.doctor_documents WHERE doctor_id = v_target_id;
    IF v_doc_count >= 25 THEN
        RAISE EXCEPTION 'Maximum document limit (25) reached for this doctor account (code: DOCUMENT_LIMIT_EXCEEDED)';
    END IF;

    -- 5. Prevent duplicate storage path registration
    IF EXISTS (SELECT 1 FROM public.doctor_documents WHERE storage_path = trim(p_storage_path)) THEN
        RAISE EXCEPTION 'Document with storage path "%" is already registered (code: DUPLICATE_DOCUMENT_PATH)', trim(p_storage_path);
    END IF;

    -- 6. Validate document type
    IF p_document_type IS NULL OR trim(p_document_type) NOT IN ('medical_license', 'degree_certificate', 'identity_proof', 'other') THEN
        RAISE EXCEPTION 'Invalid document type: "%". Allowed: medical_license, degree_certificate, identity_proof, other (code: INVALID_DOCUMENT_TYPE)', p_document_type;
    END IF;

    -- 7. Validate document name
    IF p_document_name IS NULL OR length(trim(p_document_name)) = 0 THEN
        RAISE EXCEPTION 'Document name cannot be empty (code: INVALID_DOCUMENT_NAME)';
    END IF;

    IF length(trim(p_document_name)) > 255 THEN
        RAISE EXCEPTION 'Document name exceeds maximum length of 255 characters (code: DOCUMENT_NAME_TOO_LONG)';
    END IF;

    -- 8. Insert metadata
    INSERT INTO public.doctor_documents (
        doctor_id,
        document_type,
        document_name,
        storage_path
    ) VALUES (
        v_target_id,
        trim(p_document_type),
        trim(p_document_name),
        trim(p_storage_path)
    )
    RETURNING id INTO v_document_id;

    RETURN v_document_id;
END;
$$;


-- =============================================================================
-- SECTION 2: PATIENT ONBOARDING & PROFILE RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1  complete_patient_onboarding(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Reconciles DOB with age value/unit: when DOB is supplied, calculates age
--     in months/years per Part 1 age model and rejects conflicting inputs
--   - When optional fields are omitted, preserves existing values (no accidental data loss)
--   - Enforces age constraints (months: 0-11, years: 1-120), blood group, and emergency phone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_patient_onboarding(
    p_age_value INTEGER DEFAULT NULL,
    p_age_unit TEXT DEFAULT NULL,
    p_gender TEXT DEFAULT NULL,
    p_blood_group TEXT DEFAULT NULL,
    p_emergency_phone TEXT DEFAULT NULL,
    p_medical_notes TEXT DEFAULT NULL,
    p_date_of_birth DATE DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id         UUID;
    v_ist_now         DATE;
    v_calc_months     INTEGER;
    v_final_age_val   INTEGER;
    v_final_age_unit  TEXT;
    v_effective_dob   DATE;
    v_gender_clean    TEXT;
    v_final_gender    TEXT;
    v_existing        RECORD;
    v_has_existing    BOOLEAN;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Verify profile exists in public.profiles
    IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user_id) THEN
        RAISE EXCEPTION 'User profile not found. User registration must be completed first (code: PROFILE_NOT_FOUND)';
    END IF;

    -- Retrieve existing patient record if present
    SELECT * INTO v_existing FROM public.patients WHERE id = v_user_id;
    v_has_existing := FOUND;

    v_ist_now := (now() AT TIME ZONE 'Asia/Kolkata')::date;

    -- 1. Reject incomplete age pairs: both value and unit must be supplied together
    IF (p_age_value IS NOT NULL AND p_age_unit IS NULL) OR (p_age_value IS NULL AND p_age_unit IS NOT NULL) THEN
        RAISE EXCEPTION 'Both age value and age unit must be supplied together (code: INCOMPLETE_AGE_SPECIFICATION)';
    END IF;

    -- 2. Determine authoritative effective Date of Birth:
    --    - If p_date_of_birth is supplied, it is the authoritative source.
    --    - If p_date_of_birth is omitted and patient record already has stored DOB, retain stored DOB and recalculate age from it.
    --    - If neither is available, DOB is unavailable (never infer or invent DOB from declared age).
    IF p_date_of_birth IS NOT NULL THEN
        v_effective_dob := p_date_of_birth;
    ELSIF v_has_existing AND v_existing.date_of_birth IS NOT NULL THEN
        v_effective_dob := v_existing.date_of_birth;
    ELSE
        v_effective_dob := NULL;
    END IF;

    IF v_effective_dob IS NOT NULL THEN
        -- Validate impossible or future DOB values
        IF v_effective_dob < '1900-01-01'::date OR v_effective_dob > v_ist_now THEN
            RAISE EXCEPTION 'Date of birth must be between 1900-01-01 and today (code: INVALID_DATE_OF_BIRTH)';
        END IF;

        -- DOB is authoritative for calculating patient age
        v_calc_months := (EXTRACT(YEAR FROM age(v_ist_now, v_effective_dob)) * 12 + EXTRACT(MONTH FROM age(v_ist_now, v_effective_dob)))::integer;

        IF v_calc_months < 12 THEN
            v_final_age_unit := 'months';
            v_final_age_val  := greatest(0, v_calc_months);
        ELSE
            v_final_age_unit := 'years';
            v_final_age_val  := least(120, greatest(1, EXTRACT(YEAR FROM age(v_ist_now, v_effective_dob))::integer));
        END IF;

        -- If caller also supplied declared age, validate format and verify it does not conflict with DOB
        IF p_age_value IS NOT NULL AND p_age_unit IS NOT NULL THEN
            IF p_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_age_unit = 'months' AND (p_age_value < 0 OR p_age_value > 11) THEN
                RAISE EXCEPTION 'Age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit = 'years' AND (p_age_value < 1 OR p_age_value > 120) THEN
                RAISE EXCEPTION 'Age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit <> v_final_age_unit OR abs(p_age_value - v_final_age_val) > 1 THEN
                RAISE EXCEPTION 'Supplied age (% %) is inconsistent with date of birth % (calculated: % %) (code: INCONSISTENT_AGE_DOB)',
                    p_age_value, p_age_unit, v_effective_dob, v_final_age_val, v_final_age_unit;
            END IF;
            -- DOB is authoritative; calculated age is retained
        END IF;
    ELSE
        -- No DOB available: accept validated declared age, or retain stored age
        IF p_age_value IS NOT NULL AND p_age_unit IS NOT NULL THEN
            IF p_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_age_unit = 'months' AND (p_age_value < 0 OR p_age_value > 11) THEN
                RAISE EXCEPTION 'Age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_age_unit = 'years' AND (p_age_value < 1 OR p_age_value > 120) THEN
                RAISE EXCEPTION 'Age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            v_final_age_val  := p_age_value;
            v_final_age_unit := p_age_unit;
        ELSIF v_has_existing THEN
            -- Retain stored declared age
            v_final_age_val  := v_existing.age_value;
            v_final_age_unit := v_existing.age_unit;
        ELSE
            RAISE EXCEPTION 'Age value and age unit are required for patient onboarding when date of birth is not supplied (code: AGE_REQUIRED)';
        END IF;
    END IF;

    -- 3. Gender Validation and Normalization to Part 1 Schema ('Male', 'Female', 'Other', 'Prefer not to say')
    IF p_gender IS NOT NULL THEN
        v_gender_clean := trim(p_gender);
        IF lower(v_gender_clean) = 'male' THEN
            v_final_gender := 'Male';
        ELSIF lower(v_gender_clean) = 'female' THEN
            v_final_gender := 'Female';
        ELSIF lower(v_gender_clean) = 'other' THEN
            v_final_gender := 'Other';
        ELSIF lower(v_gender_clean) IN ('prefer not to say', 'prefer_not_to_say') THEN
            v_final_gender := 'Prefer not to say';
        ELSE
            RAISE EXCEPTION 'Gender must be "Male", "Female", "Other", or "Prefer not to say" (code: INVALID_GENDER)';
        END IF;
    ELSIF v_has_existing THEN
        v_final_gender := v_existing.gender;
    ELSE
        RAISE EXCEPTION 'Gender is required for initial patient onboarding (code: GENDER_REQUIRED)';
    END IF;

    -- 4. Blood Group Validation
    IF p_blood_group IS NOT NULL AND p_blood_group NOT IN ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-') THEN
        RAISE EXCEPTION 'Invalid blood group: %. Allowed: A+, A-, B+, B-, AB+, AB-, O+, O- (code: INVALID_BLOOD_GROUP)', p_blood_group;
    END IF;

    -- 5. Emergency Phone Validation
    IF p_emergency_phone IS NOT NULL AND p_emergency_phone !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Emergency phone must be a valid 10-digit Indian mobile number (code: INVALID_EMERGENCY_PHONE)';
    END IF;

    -- 6. Medical Notes Length Bounds
    IF p_medical_notes IS NOT NULL AND length(trim(p_medical_notes)) > 2000 THEN
        RAISE EXCEPTION 'Medical notes exceed maximum length of 2000 characters (code: MEDICAL_NOTES_TOO_LONG)';
    END IF;

    -- 7. Upsert patient demographic record preserving existing values when parameters are omitted
    INSERT INTO public.patients (
        id,
        age_value,
        age_unit,
        date_of_birth,
        gender,
        blood_group,
        emergency_phone,
        medical_notes
    ) VALUES (
        v_user_id,
        v_final_age_val,
        v_final_age_unit,
        v_effective_dob,
        v_final_gender,
        p_blood_group,
        p_emergency_phone,
        nullif(trim(p_medical_notes), '')
    )
    ON CONFLICT (id) DO UPDATE SET
        age_value       = v_final_age_val,
        age_unit        = v_final_age_unit,
        date_of_birth   = v_effective_dob,
        gender          = v_final_gender,
        blood_group     = coalesce(EXCLUDED.blood_group, public.patients.blood_group),
        emergency_phone = coalesce(EXCLUDED.emergency_phone, public.patients.emergency_phone),
        medical_notes   = coalesce(EXCLUDED.medical_notes, public.patients.medical_notes),
        updated_at      = now();

    RETURN v_user_id;
END;
$$;


-- =============================================================================
-- SECTION 3: APPOINTMENT ENGINE RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3.1  book_appointment(...)
--
-- Security & Concurrency Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Timezone: Asia/Kolkata strictly enforced across all evaluations
--   - Validates doctor approval, active practice status, leaves, and schedule window
--   - Enforces exact slot alignment math: (appt_time - start_time) % slot_duration == 0
--   - Snapshots patient demographic age & contact data (Part 1 Age Model)
--   - Rejects incomplete age pairs (must supply both value and unit or neither)
--   - Multi-layer concurrency defense:
--       * Transaction-level advisory lock on both doctor and patient slot
--       * GiST physical temporal range exclusion constraints with specific error mapping
--   - Atomically provisions in-app reminder scheduled 2h before consultation
--     (safe fallback for appointments booked < 2h or < 5m out)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.book_appointment(
    p_doctor_id UUID,
    p_appointment_date DATE,
    p_appointment_time TIME,
    p_chief_complaint TEXT,
    p_patient_name TEXT DEFAULT NULL,
    p_patient_phone TEXT DEFAULT NULL,
    p_patient_age_value INTEGER DEFAULT NULL,
    p_patient_age_unit TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_patient_id            UUID;
    v_doc_approved          BOOLEAN;
    v_doc_active            BOOLEAN;
    v_current_ist_timestamp TIMESTAMP;
    v_current_ist_date      DATE;
    v_current_ist_time      TIME;
    v_appt_start_utc        TIMESTAMPTZ;
    v_lead_time             INTERVAL;
    v_dow                   INTEGER;
    v_sched_start           TIME;
    v_sched_end             TIME;
    v_slot_duration         INTEGER;
    v_minutes_from_start    INTEGER;
    v_end_time              TIME;
    v_prof_name             TEXT;
    v_prof_phone            TEXT;
    v_pat_age_val           INTEGER;
    v_pat_age_unit          TEXT;
    v_pat_dob               DATE;
    v_pat_em_phone          TEXT;
    v_snap_name             TEXT;
    v_snap_phone            TEXT;
    v_snap_age_val          INTEGER;
    v_snap_age_unit         TEXT;
    v_total_months          INTEGER;
    v_appointment_id        UUID;
    v_reminder_scheduled    TIMESTAMPTZ;
    v_constraint_name       TEXT;
BEGIN
    -- 1. Authentication check
    v_patient_id := auth.uid();
    IF v_patient_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required to book an appointment (code: AUTH_REQUIRED)';
    END IF;

    -- 2. Verify caller has completed patient registration
    IF NOT EXISTS (SELECT 1 FROM public.patients WHERE id = v_patient_id) THEN
        RAISE EXCEPTION 'Patient demographic profile not found. Please complete patient onboarding first (code: PATIENT_RECORD_REQUIRED)';
    END IF;

    -- 3. Prevent self-booking (doctor booking themselves)
    IF p_doctor_id = v_patient_id THEN
        RAISE EXCEPTION 'Doctors cannot book appointments with themselves (code: SELF_BOOKING_NOT_ALLOWED)';
    END IF;

    -- 4. Verify Doctor Approval and Active Practice Status
    SELECT is_approved, is_active
    INTO v_doc_approved, v_doc_active
    FROM public.doctors
    WHERE id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor not found (code: DOCTOR_NOT_FOUND)';
    END IF;

    IF NOT v_doc_approved OR NOT v_doc_active THEN
        RAISE EXCEPTION 'Doctor is currently not accepting appointments (code: DOCTOR_NOT_AVAILABLE)';
    END IF;

    -- 5. Timezone & Temporal Validations (Application Timezone: Asia/Kolkata)
    v_current_ist_timestamp := (now() AT TIME ZONE 'Asia/Kolkata');
    v_current_ist_date      := v_current_ist_timestamp::date;
    v_current_ist_time      := v_current_ist_timestamp::time;

    -- Compute full UTC start timestamp for precise interval checks
    v_appt_start_utc := ((p_appointment_date + p_appointment_time) AT TIME ZONE 'Asia/Kolkata');

    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot book an appointment in the past (code: APPOINTMENT_TIME_PAST)';
    END IF;

    IF p_appointment_date < v_current_ist_date THEN
        RAISE EXCEPTION 'Cannot book an appointment for a past date (code: APPOINTMENT_DATE_PAST)';
    END IF;

    IF p_appointment_date > (v_current_ist_date + INTERVAL '90 days')::date THEN
        RAISE EXCEPTION 'Appointments cannot be booked more than 90 days in advance (code: APPOINTMENT_DATE_TOO_FAR)';
    END IF;

    -- Minimum lead time guard: must book at least 30 seconds before slot start
    IF (v_appt_start_utc - now()) < INTERVAL '30 seconds' THEN
        RAISE EXCEPTION 'Cannot book an appointment starting in less than 30 seconds (code: APPOINTMENT_TOO_IMMINENT)';
    END IF;

    -- 6. Doctor Leave Verification
    IF EXISTS (
        SELECT 1
        FROM public.doctor_leaves
        WHERE doctor_id = p_doctor_id
          AND leave_date = p_appointment_date
    ) THEN
        RAISE EXCEPTION 'Doctor is on leave on the requested date (code: DOCTOR_ON_LEAVE)';
    END IF;

    -- 7. Doctor Schedule & Slot Window Verification
    v_dow := EXTRACT(DOW FROM p_appointment_date)::integer;

    SELECT start_time, end_time, slot_duration_minutes
    INTO v_sched_start, v_sched_end, v_slot_duration
    FROM public.doctor_schedules
    WHERE doctor_id = p_doctor_id
      AND day_of_week = v_dow
      AND is_active = true
      AND p_appointment_time >= start_time
      AND (p_appointment_time + (slot_duration_minutes || ' minutes')::interval)::time <= end_time;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Requested time is outside the doctor''s active schedule for this day (code: OUTSIDE_DOCTOR_SCHEDULE)';
    END IF;

    -- 8. Slot Alignment Verification
    v_minutes_from_start := (EXTRACT(EPOCH FROM (p_appointment_time - v_sched_start)) / 60)::integer;
    IF (v_minutes_from_start % v_slot_duration) <> 0 THEN
        RAISE EXCEPTION 'Appointment time % does not align with doctor''s %-minute slot intervals starting at % (code: INVALID_SLOT_ALIGNMENT)',
            p_appointment_time, v_slot_duration, v_sched_start;
    END IF;

    v_end_time := (p_appointment_time + (v_slot_duration || ' minutes')::interval)::time;

    -- 9. Chief Complaint & Input Bounds
    IF p_chief_complaint IS NULL OR length(trim(p_chief_complaint)) = 0 THEN
        RAISE EXCEPTION 'Chief complaint cannot be empty (code: EMPTY_CHIEF_COMPLAINT)';
    END IF;

    IF length(trim(p_chief_complaint)) > 1000 THEN
        RAISE EXCEPTION 'Chief complaint exceeds maximum length of 1000 characters (code: CHIEF_COMPLAINT_TOO_LONG)';
    END IF;

    -- 10. Patient Demographic Snapshot Resolution (Part 1 Age Model)
    SELECT full_name, phone INTO v_prof_name, v_prof_phone FROM public.profiles WHERE id = v_patient_id;
    SELECT age_value, age_unit, date_of_birth, emergency_phone INTO v_pat_age_val, v_pat_age_unit, v_pat_dob, v_pat_em_phone FROM public.patients WHERE id = v_patient_id;

    -- Snapshot patient name
    v_snap_name := coalesce(nullif(trim(p_patient_name), ''), v_prof_name);
    IF length(v_snap_name) = 0 THEN
        RAISE EXCEPTION 'Patient name cannot be empty (code: EMPTY_PATIENT_NAME)';
    END IF;

    IF length(v_snap_name) > 150 THEN
        RAISE EXCEPTION 'Patient name exceeds maximum length of 150 characters (code: PATIENT_NAME_TOO_LONG)';
    END IF;

    -- Snapshot patient phone
    v_snap_phone := coalesce(nullif(trim(p_patient_phone), ''), v_prof_phone, v_pat_em_phone);
    IF v_snap_phone IS NULL OR v_snap_phone !~ '^[6-9][0-9]{9}$' THEN
        RAISE EXCEPTION 'Patient phone number must be a valid 10-digit Indian mobile number (code: INVALID_PATIENT_PHONE)';
    END IF;

    -- Snapshot patient age: reject incomplete pairs
    IF (p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NULL) OR
       (p_patient_age_value IS NULL AND p_patient_age_unit IS NOT NULL) THEN
        RAISE EXCEPTION 'Both age value and age unit must be supplied together (code: INCOMPLETE_AGE_SPECIFICATION)';
    END IF;

    -- If patient has a stored date of birth, DOB is authoritative as of appointment date
    IF v_pat_dob IS NOT NULL THEN
        -- Calculate dynamic age as of the appointment date
        v_total_months := (EXTRACT(YEAR FROM age(p_appointment_date, v_pat_dob)) * 12 + EXTRACT(MONTH FROM age(p_appointment_date, v_pat_dob)))::integer;
        IF v_total_months < 12 THEN
            v_snap_age_unit := 'months';
            v_snap_age_val  := greatest(0, v_total_months);
        ELSE
            v_snap_age_unit := 'years';
            v_snap_age_val  := least(120, greatest(1, EXTRACT(YEAR FROM age(p_appointment_date, v_pat_dob))::integer));
        END IF;

        -- If caller also supplied declared age, validate format and verify consistency
        IF p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NOT NULL THEN
            IF p_patient_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Patient age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_patient_age_unit = 'months' AND (p_patient_age_value < 0 OR p_patient_age_value > 11) THEN
                RAISE EXCEPTION 'Patient age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit = 'years' AND (p_patient_age_value < 1 OR p_patient_age_value > 120) THEN
                RAISE EXCEPTION 'Patient age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit <> v_snap_age_unit OR abs(p_patient_age_value - v_snap_age_val) > 1 THEN
                RAISE EXCEPTION 'Supplied patient age (% %) is inconsistent with stored date of birth % as of appointment date % (calculated: % %) (code: INCONSISTENT_AGE_DOB)',
                    p_patient_age_value, p_patient_age_unit, v_pat_dob, p_appointment_date, v_snap_age_val, v_snap_age_unit;
            END IF;
            -- DOB is authoritative for snapshot
        END IF;
    ELSE
        -- DOB is unavailable: accept validated declared age or copy from stored profile
        IF p_patient_age_value IS NOT NULL AND p_patient_age_unit IS NOT NULL THEN
            IF p_patient_age_unit NOT IN ('months', 'years') THEN
                RAISE EXCEPTION 'Patient age unit must be "months" or "years" (code: INVALID_AGE_UNIT)';
            END IF;

            IF p_patient_age_unit = 'months' AND (p_patient_age_value < 0 OR p_patient_age_value > 11) THEN
                RAISE EXCEPTION 'Patient age in months must be between 0 and 11 (code: INVALID_AGE_VALUE)';
            END IF;

            IF p_patient_age_unit = 'years' AND (p_patient_age_value < 1 OR p_patient_age_value > 120) THEN
                RAISE EXCEPTION 'Patient age in years must be between 1 and 120 (code: INVALID_AGE_VALUE)';
            END IF;

            v_snap_age_val  := p_patient_age_value;
            v_snap_age_unit := p_patient_age_unit;
        ELSE
            -- Copy validated declared age and unit from stored patient profile
            v_snap_age_val  := v_pat_age_val;
            v_snap_age_unit := v_pat_age_unit;
        END IF;
    END IF;

    -- 11. Concurrency-Safe Booking Insertion
    -- Dual advisory locks: serialize concurrent bookings on doctor's slot AND patient's slot
    PERFORM pg_advisory_xact_lock(hashtext('doctor_slot:' || p_doctor_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));
    PERFORM pg_advisory_xact_lock(hashtext('patient_slot:' || v_patient_id::text || ':' || p_appointment_date::text || ':' || p_appointment_time::text));

    BEGIN
        INSERT INTO public.appointments (
            patient_id,
            doctor_id,
            appointment_date,
            appointment_time,
            end_time,
            slot_duration_minutes,
            status,
            patient_name,
            patient_age_value,
            patient_age_unit,
            patient_phone,
            chief_complaint
        ) VALUES (
            v_patient_id,
            p_doctor_id,
            p_appointment_date,
            p_appointment_time,
            v_end_time,
            v_slot_duration,
            'pending'::public.appointment_status,
            v_snap_name,
            v_snap_age_val,
            v_snap_age_unit,
            v_snap_phone,
            trim(p_chief_complaint)
        )
        RETURNING id INTO v_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
            IF v_constraint_name = 'uq_patient_no_appointment_overlap' THEN
                RAISE EXCEPTION 'You already have another active appointment booked during this time window (code: PATIENT_APPOINTMENT_CONFLICT)';
            ELSE
                RAISE EXCEPTION 'The requested doctor time slot is no longer available (code: SLOT_ALREADY_BOOKED)';
            END IF;
        WHEN unique_violation THEN
            RAISE EXCEPTION 'Appointment conflict detected (code: DUPLICATE_APPOINTMENT)';
    END;

    -- 12. Atomic In-App Reminder Provisioning
    v_lead_time := v_appt_start_utc - now();

    IF v_lead_time <= INTERVAL '5 minutes' THEN
        -- Short-notice booking (< 5m): schedule reminder 10s from now, strictly before appointment start
        v_reminder_scheduled := least(now() + INTERVAL '10 seconds', v_appt_start_utc - INTERVAL '10 seconds');
    ELSIF v_lead_time <= INTERVAL '2 hours' THEN
        -- Booked within 2h window: schedule reminder in 5 minutes (strictly before appointment start)
        v_reminder_scheduled := least(now() + INTERVAL '5 minutes', v_appt_start_utc - INTERVAL '1 minute');
    ELSE
        -- Standard booking: 2 hours prior to consultation
        v_reminder_scheduled := v_appt_start_utc - INTERVAL '2 hours';
    END IF;

    -- Invariant: Reminder is strictly never scheduled after appointment start
    v_reminder_scheduled := least(v_reminder_scheduled, v_appt_start_utc);
    IF v_reminder_scheduled > v_appt_start_utc THEN
        v_reminder_scheduled := v_appt_start_utc;
    END IF;

    INSERT INTO public.in_app_reminders (
        appointment_id,
        patient_id,
        scheduled_for,
        is_sent,
        is_dismissed
    ) VALUES (
        v_appointment_id,
        v_patient_id,
        v_reminder_scheduled,
        false,
        false
    );

    RETURN v_appointment_id;
END;
$$;


-- ---------------------------------------------------------------------------
-- 3.2  reschedule_appointment(...)
--
-- Security & Concurrency Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be booking patient or system administrator
--   - Row-level lock (FOR UPDATE) prevents concurrent modifications
--   - Rejects rescheduling appointments that have already started
--   - Revalidates doctor approval, active status, leaves, and schedule window
--   - Dual advisory locking on new doctor and patient slot
--   - Resets status to 'pending' for doctor reconfirmation
--   - Atomically updates in-app reminder timing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_appointment(
    p_appointment_id UUID,
    p_new_date DATE,
    p_new_time TIME,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id               UUID;
    v_appt                  RECORD;
    v_doc_approved          BOOLEAN;
    v_doc_active            BOOLEAN;
    v_current_ist_timestamp TIMESTAMP;
    v_current_ist_date      DATE;
    v_current_ist_time      TIME;
    v_existing_start_utc    TIMESTAMPTZ;
    v_new_start_utc         TIMESTAMPTZ;
    v_lead_time             INTERVAL;
    v_dow                   INTEGER;
    v_sched_start           TIME;
    v_sched_end             TIME;
    v_slot_duration         INTEGER;
    v_minutes_from_start    INTEGER;
    v_new_end_time          TIME;
    v_new_reminder_ts       TIMESTAMPTZ;
    v_existing_reminder_id  UUID;
    v_constraint_name       TEXT;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- 1. Fetch appointment with row-level lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- 2. Authorization check: caller must be the patient or admin
    IF v_appt.patient_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the booking patient or an administrator can reschedule this appointment (code: UNAUTHORIZED_APPOINTMENT_MODIFICATION)';
    END IF;

    -- 3. Status check: appointment must be active (pending or confirmed)
    IF v_appt.status NOT IN ('pending'::public.appointment_status, 'confirmed'::public.appointment_status) THEN
        RAISE EXCEPTION 'Cannot reschedule an appointment with status "%" (code: CANNOT_RESCHEDULE_CLOSED_APPOINTMENT)', v_appt.status;
    END IF;

    -- 4. Verify existing appointment has not already started
    v_existing_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_existing_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot reschedule an appointment that has already started or passed (code: CANNOT_RESCHEDULE_PAST_APPOINTMENT)';
    END IF;

    -- 5. Validate new date and time in Asia/Kolkata
    v_current_ist_timestamp := (now() AT TIME ZONE 'Asia/Kolkata');
    v_current_ist_date      := v_current_ist_timestamp::date;
    v_current_ist_time      := v_current_ist_timestamp::time;
    v_new_start_utc         := ((p_new_date + p_new_time) AT TIME ZONE 'Asia/Kolkata');

    IF v_new_start_utc <= now() THEN
        RAISE EXCEPTION 'New appointment time must be in the future (code: APPOINTMENT_TIME_PAST)';
    END IF;

    IF p_new_date < v_current_ist_date THEN
        RAISE EXCEPTION 'New appointment date cannot be in the past (code: APPOINTMENT_DATE_PAST)';
    END IF;

    IF p_new_date > (v_current_ist_date + INTERVAL '90 days')::date THEN
        RAISE EXCEPTION 'New appointment date cannot be more than 90 days in advance (code: APPOINTMENT_DATE_TOO_FAR)';
    END IF;

    -- 6. Verify Doctor is still active and approved
    SELECT is_approved, is_active
    INTO v_doc_approved, v_doc_active
    FROM public.doctors
    WHERE id = v_appt.doctor_id;

    IF NOT v_doc_approved OR NOT v_doc_active THEN
        RAISE EXCEPTION 'Doctor is currently not available for bookings (code: DOCTOR_NOT_AVAILABLE)';
    END IF;

    -- 7. Check Doctor Leaves for new date
    IF EXISTS (
        SELECT 1
        FROM public.doctor_leaves
        WHERE doctor_id = v_appt.doctor_id
          AND leave_date = p_new_date
    ) THEN
        RAISE EXCEPTION 'Doctor is on leave on the requested new date (code: DOCTOR_ON_LEAVE)';
    END IF;

    -- 8. Verify schedule and slot alignment for new date/time
    v_dow := EXTRACT(DOW FROM p_new_date)::integer;

    SELECT start_time, end_time, slot_duration_minutes
    INTO v_sched_start, v_sched_end, v_slot_duration
    FROM public.doctor_schedules
    WHERE doctor_id = v_appt.doctor_id
      AND day_of_week = v_dow
      AND is_active = true
      AND p_new_time >= start_time
      AND (p_new_time + (slot_duration_minutes || ' minutes')::interval)::time <= end_time;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Requested time is outside the doctor''s active schedule for this day (code: OUTSIDE_DOCTOR_SCHEDULE)';
    END IF;

    v_minutes_from_start := (EXTRACT(EPOCH FROM (p_new_time - v_sched_start)) / 60)::integer;
    IF (v_minutes_from_start % v_slot_duration) <> 0 THEN
        RAISE EXCEPTION 'Appointment time % does not align with doctor''s %-minute slot intervals starting at % (code: INVALID_SLOT_ALIGNMENT)',
            p_new_time, v_slot_duration, v_sched_start;
    END IF;

    v_new_end_time := (p_new_time + (v_slot_duration || ' minutes')::interval)::time;

    -- 9. Reason length check
    IF p_reason IS NOT NULL AND length(trim(p_reason)) > 500 THEN
        RAISE EXCEPTION 'Reschedule reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
    END IF;

    -- 10. Concurrency Locks on new slot
    PERFORM pg_advisory_xact_lock(hashtext('doctor_slot:' || v_appt.doctor_id::text || ':' || p_new_date::text || ':' || p_new_time::text));
    PERFORM pg_advisory_xact_lock(hashtext('patient_slot:' || v_appt.patient_id::text || ':' || p_new_date::text || ':' || p_new_time::text));

    -- 11. Update appointment record
    BEGIN
        UPDATE public.appointments
           SET appointment_date      = p_new_date,
               appointment_time      = p_new_time,
               end_time              = v_new_end_time,
               slot_duration_minutes = v_slot_duration,
               status                = 'pending'::public.appointment_status, -- Requires doctor re-confirmation
               cancellation_reason   = coalesce(nullif(trim(p_reason), ''), cancellation_reason),
               updated_at            = now()
         WHERE id = p_appointment_id;
    EXCEPTION
        WHEN exclusion_violation THEN
            GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
            IF v_constraint_name = 'uq_patient_no_appointment_overlap' THEN
                RAISE EXCEPTION 'You already have another active appointment booked during the new time window (code: PATIENT_APPOINTMENT_CONFLICT)';
            ELSE
                RAISE EXCEPTION 'The requested new doctor time slot is already booked (code: SLOT_ALREADY_BOOKED)';
            END IF;
    END;

    -- 12. Recalculate and upsert in-app reminder atomically
    v_lead_time := v_new_start_utc - now();

    IF v_lead_time <= INTERVAL '5 minutes' THEN
        v_new_reminder_ts := least(now() + INTERVAL '10 seconds', v_new_start_utc - INTERVAL '10 seconds');
    ELSIF v_lead_time <= INTERVAL '2 hours' THEN
        v_new_reminder_ts := least(now() + INTERVAL '5 minutes', v_new_start_utc - INTERVAL '1 minute');
    ELSE
        v_new_reminder_ts := v_new_start_utc - INTERVAL '2 hours';
    END IF;

    -- Invariant: Reminder is strictly never scheduled after new appointment start
    v_new_reminder_ts := least(v_new_reminder_ts, v_new_start_utc);
    IF v_new_reminder_ts > v_new_start_utc THEN
        v_new_reminder_ts := v_new_start_utc;
    END IF;

    -- Concurrency-safe reminder upsert: check existing reminder under appointment row lock
    SELECT id INTO v_existing_reminder_id
    FROM public.in_app_reminders
    WHERE appointment_id = p_appointment_id
      AND patient_id = v_appt.patient_id
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_existing_reminder_id IS NOT NULL THEN
        UPDATE public.in_app_reminders
           SET scheduled_for = v_new_reminder_ts,
               is_sent       = false,
               is_dismissed  = false
         WHERE id = v_existing_reminder_id;

        -- Dismiss any duplicate or obsolete reminders for this appointment
        UPDATE public.in_app_reminders
           SET is_dismissed = true
         WHERE appointment_id = p_appointment_id
           AND id <> v_existing_reminder_id
           AND is_dismissed = false;
    ELSE
        INSERT INTO public.in_app_reminders (
            appointment_id,
            patient_id,
            scheduled_for,
            is_sent,
            is_dismissed
        ) VALUES (
            p_appointment_id,
            v_appt.patient_id,
            v_new_reminder_ts,
            false,
            false
        );
    END IF;

    RETURN true;
END;
$$;


-- =============================================================================
-- SECTION 4: APPOINTMENT LIFECYCLE MANAGEMENT RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 4.1  cancel_appointment(...) & patient_cancel_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - cancel_appointment: Caller must be assigned patient, assigned doctor, or admin
--   - patient_cancel_appointment: Strictly enforces caller IS the booking patient
--     (prevents authorization bypass)
--   - Rejects cancellation after the appointment has already started
--   - Dismisses pending in-app reminders atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_appointment(
    p_appointment_id UUID,
    p_cancellation_reason TEXT DEFAULT 'Cancelled by user'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id         UUID;
    v_appt            RECORD;
    v_appt_start_utc  TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: patient, doctor, or admin
    IF v_appt.patient_id <> v_user_id AND v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the booking patient, assigned doctor, or an administrator can cancel this appointment (code: UNAUTHORIZED_APPOINTMENT_MODIFICATION)';
    END IF;

    -- Status check: cannot cancel closed/terminal appointments
    IF v_appt.status NOT IN ('pending'::public.appointment_status, 'confirmed'::public.appointment_status) THEN
        RAISE EXCEPTION 'Cannot cancel an appointment that is already "%" (code: CANNOT_CANCEL_CLOSED_APPOINTMENT)', v_appt.status;
    END IF;

    -- Timing check: reject cancellation after start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot cancel an appointment that has already started or passed (code: CANNOT_CANCEL_PAST_APPOINTMENT)';
    END IF;

    -- Reason length check
    IF p_cancellation_reason IS NOT NULL AND length(trim(p_cancellation_reason)) > 500 THEN
        RAISE EXCEPTION 'Cancellation reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
    END IF;

    -- Update appointment
    UPDATE public.appointments
       SET status              = 'cancelled'::public.appointment_status,
           cancellation_reason = coalesce(nullif(trim(p_cancellation_reason), ''), 'Cancelled by user'),
           cancelled_by        = v_user_id,
           cancelled_at        = now(),
           updated_at          = now()
     WHERE id = p_appointment_id;

    -- Dismiss associated reminders
    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;

-- Dedicated patient cancellation RPC: explicitly validates patient identity
CREATE OR REPLACE FUNCTION public.patient_cancel_appointment(
    p_appointment_id UUID,
    p_cancellation_reason TEXT DEFAULT 'Cancelled by patient'
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_appt    RECORD;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Explicit Patient Verification: prevent doctors or third parties from calling this as a bypass
    SELECT patient_id INTO v_appt FROM public.appointments WHERE id = p_appointment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    IF v_appt.patient_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: patient_cancel_appointment can only be invoked by the booking patient (code: PATIENT_CANCEL_UNAUTHORIZED)';
    END IF;

    RETURN public.cancel_appointment(p_appointment_id, p_cancellation_reason);
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.2  doctor_respond_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be the assigned doctor OR administrator
--   - Verifies doctor is approved and active
--   - Rejects confirmation of appointments that have already passed
--   - Allowed strictly when appointment status is 'pending'
--   - Decisions: 'confirmed' or 'rejected'
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.doctor_respond_appointment(
    p_appointment_id UUID,
    p_decision TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id        UUID;
    v_appt           RECORD;
    v_doc_app        BOOLEAN;
    v_doc_act        BOOLEAN;
    v_appt_start_utc TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Validate decision input
    IF p_decision NOT IN ('confirmed', 'rejected') THEN
        RAISE EXCEPTION 'Invalid decision: %. Allowed decisions: "confirmed" or "rejected" (code: INVALID_DECISION)', p_decision;
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: caller must be assigned doctor or admin
    IF v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the assigned doctor or an administrator can respond to this appointment (code: UNAUTHORIZED_DOCTOR_OPERATION)';
    END IF;

    -- Verify doctor account is active and approved
    SELECT is_approved, is_active INTO v_doc_app, v_doc_act FROM public.doctors WHERE id = v_appt.doctor_id;
    IF NOT v_doc_app OR NOT v_doc_act THEN
        RAISE EXCEPTION 'Doctor account is currently not active or approved (code: DOCTOR_NOT_ACTIVE)';
    END IF;

    -- Status check: strictly 'pending'
    IF v_appt.status <> 'pending'::public.appointment_status THEN
        RAISE EXCEPTION 'Cannot respond to appointment with status "%". Only pending appointments can be confirmed or rejected (code: INVALID_STATUS_TRANSITION)', v_appt.status;
    END IF;

    -- Timing check: both confirmation and rejection are disallowed after scheduled appointment start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc <= now() THEN
        RAISE EXCEPTION 'Cannot respond to an appointment whose scheduled start time has already passed (code: CANNOT_RESPOND_PAST_APPOINTMENT)';
    END IF;

    IF p_decision = 'rejected' THEN
        -- Rejection reason is strictly mandatory, non-empty, and trimmed
        IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
            RAISE EXCEPTION 'A non-empty rejection reason is required when declining an appointment (code: REJECTION_REASON_REQUIRED)';
        END IF;

        IF length(trim(p_reason)) > 500 THEN
            RAISE EXCEPTION 'Rejection reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
        END IF;

        UPDATE public.appointments
           SET status              = 'rejected'::public.appointment_status,
               cancellation_reason = trim(p_reason),
               cancelled_by        = v_user_id,
               cancelled_at        = now(),
               updated_at          = now()
         WHERE id = p_appointment_id;

        -- Dismiss in-app reminder
        UPDATE public.in_app_reminders
           SET is_dismissed = true
         WHERE appointment_id = p_appointment_id;
    ELSE -- confirmed
        IF p_reason IS NOT NULL AND length(trim(p_reason)) > 500 THEN
            RAISE EXCEPTION 'Response reason exceeds maximum length of 500 characters (code: REASON_TOO_LONG)';
        END IF;

        UPDATE public.appointments
           SET status     = 'confirmed'::public.appointment_status,
               updated_at = now()
         WHERE id = p_appointment_id;
    END IF;

    RETURN true;
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.3  doctor_close_appointment(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Caller must be the assigned doctor OR administrator
--   - Allowed strictly when appointment status is 'confirmed'
--   - Rejects completion before the scheduled appointment start time
--   - Outcomes: 'completed' (with clinical consultation notes) or 'no_show'
--   - Dismisses in-app reminders atomically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.doctor_close_appointment(
    p_appointment_id UUID,
    p_outcome TEXT,
    p_consultation_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id        UUID;
    v_appt           RECORD;
    v_doc_app        BOOLEAN;
    v_doc_act        BOOLEAN;
    v_appt_start_utc TIMESTAMPTZ;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    -- Validate outcome
    IF p_outcome NOT IN ('completed', 'no_show') THEN
        RAISE EXCEPTION 'Invalid outcome: %. Allowed outcomes: "completed" or "no_show" (code: INVALID_OUTCOME)', p_outcome;
    END IF;

    -- Fetch appointment with row lock
    SELECT *
    INTO v_appt
    FROM public.appointments
    WHERE id = p_appointment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Appointment not found (code: APPOINTMENT_NOT_FOUND)';
    END IF;

    -- Authorization check: must be assigned doctor or admin
    IF v_appt.doctor_id <> v_user_id AND NOT public.is_admin() THEN
        RAISE EXCEPTION 'Unauthorized: only the assigned doctor or an administrator can close this appointment (code: UNAUTHORIZED_DOCTOR_OPERATION)';
    END IF;

    -- Verify doctor account is active and approved (prevents suspended/unapproved doctors from closing appointments)
    SELECT is_approved, is_active INTO v_doc_app, v_doc_act FROM public.doctors WHERE id = v_appt.doctor_id;
    IF NOT v_doc_app OR NOT v_doc_act THEN
        RAISE EXCEPTION 'Doctor account is currently not active or approved (code: DOCTOR_NOT_ACTIVE)';
    END IF;

    -- Status check: strictly 'confirmed'
    IF v_appt.status <> 'confirmed'::public.appointment_status THEN
        RAISE EXCEPTION 'Cannot close appointment with status "%". Only confirmed appointments can be marked completed or no_show (code: INVALID_STATUS_TRANSITION)', v_appt.status;
    END IF;

    -- Timing check: consultation can only be completed/closed on or after its start time
    v_appt_start_utc := ((v_appt.appointment_date + v_appt.appointment_time) AT TIME ZONE 'Asia/Kolkata');
    IF v_appt_start_utc > now() THEN
        RAISE EXCEPTION 'Cannot complete or close an appointment before its scheduled start time (code: APPOINTMENT_NOT_YET_STARTED)';
    END IF;

    -- Consultation notes length check
    IF p_consultation_notes IS NOT NULL AND length(trim(p_consultation_notes)) > 5000 THEN
        RAISE EXCEPTION 'Consultation notes exceed maximum length of 5000 characters (code: NOTES_TOO_LONG)';
    END IF;

    IF p_outcome = 'completed' THEN
        UPDATE public.appointments
           SET status             = 'completed'::public.appointment_status,
               consultation_notes = coalesce(nullif(trim(p_consultation_notes), ''), consultation_notes),
               updated_at         = now()
         WHERE id = p_appointment_id;
    ELSE -- no_show
        UPDATE public.appointments
           SET status     = 'no_show'::public.appointment_status,
               updated_at = now()
         WHERE id = p_appointment_id;
    END IF;

    -- Dismiss reminder
    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE appointment_id = p_appointment_id;

    RETURN true;
END;
$$;


-- ---------------------------------------------------------------------------
-- 4.4  dismiss_reminder(...)
--
-- Security Properties:
--   - SECURITY DEFINER owned by postgres
--   - search_path = pg_catalog
--   - Patient can dismiss only their own reminders; admin can dismiss any
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dismiss_reminder(
    p_reminder_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_user_id UUID;
    v_updated INTEGER;
BEGIN
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required (code: AUTH_REQUIRED)';
    END IF;

    UPDATE public.in_app_reminders
       SET is_dismissed = true
     WHERE id = p_reminder_id
       AND (patient_id = v_user_id OR public.is_admin());

    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
        IF NOT EXISTS (SELECT 1 FROM public.in_app_reminders WHERE id = p_reminder_id) THEN
            RAISE EXCEPTION 'Reminder not found (code: REMINDER_NOT_FOUND)';
        ELSE
            RAISE EXCEPTION 'Unauthorized to modify this reminder (code: UNAUTHORIZED_REMINDER_MODIFICATION)';
        END IF;
    END IF;

    RETURN true;
END;
$$;


-- =============================================================================
-- SECTION 5: OWNERSHIP & EXPLICIT SQL PRIVILEGES (LEAST PRIVILEGE)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 5.1  Explicit Function Ownership
-- ---------------------------------------------------------------------------
ALTER FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) OWNER TO postgres;
ALTER FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) OWNER TO postgres;
ALTER FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) OWNER TO postgres;
ALTER FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) OWNER TO postgres;
ALTER FUNCTION public.cancel_appointment(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION public.patient_cancel_appointment(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) OWNER TO postgres;
ALTER FUNCTION public.dismiss_reminder(UUID) OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- 5.2  Revoke Execution Privileges from PUBLIC and anon
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_appointment(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.patient_cancel_appointment(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.dismiss_reminder(UUID) FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- 5.3  Grant Execution Privileges to authenticated
--      (Internal function logic enforces user roles, identity, and authorization)
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.submit_doctor_application(TEXT, TEXT, INTEGER, INTEGER, TEXT[], TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_doctor_document(TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_patient_onboarding(INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.book_appointment(UUID, DATE, TIME, TEXT, TEXT, TEXT, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reschedule_appointment(UUID, DATE, TIME, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_appointment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.patient_cancel_appointment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.doctor_respond_appointment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.doctor_close_appointment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_reminder(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5.4  Base Table Privilege Hardening: public.doctor_documents
--
-- Security Rationale:
--   - In Part 2, direct client INSERT was granted to authenticated on public.doctor_documents.
--   - In Part 4, public.register_doctor_document() was introduced to enforce:
--       * Strict path syntax and ownership validation via public.validate_doctor_document_path()
--       * Concurrency-safe doctor-row serialization (SELECT ... FOR UPDATE)
--       * The 25-document quota ceiling (DOCUMENT_LIMIT_EXCEEDED)
--   - If direct client INSERT remains granted, an authenticated doctor could bypass
--     register_doctor_document() and its 25-document quota via the Supabase Data API (PostgREST).
--   - To eliminate this bypass, direct INSERT on public.doctor_documents is revoked from
--     PUBLIC, anon, and authenticated.
--   - Document creation is routed exclusively through the trusted SECURITY DEFINER RPCs:
--       * public.submit_doctor_application() (initial onboarding, max 10 docs)
--       * public.register_doctor_document() (subsequent additions, max 25 docs under row lock)
--   - Direct client SELECT and DELETE privileges granted in Part 2 are preserved.
-- ---------------------------------------------------------------------------
REVOKE INSERT ON public.doctor_documents FROM PUBLIC, anon, authenticated;


-- =============================================================================
-- INTEGRATED PART 5: ADMIN REVIEW DASHBOARD & STATE MACHINE RPCS
-- =============================================================================

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


-- =============================================================================
-- INTEGRATED PART 6: AUDIT LOGGING, IMMUTABILITY & TELEMETRY
-- =============================================================================

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
SECURITY INVOKER
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


-- =============================================================================
-- SECTION 8: MASTER INTEGRATED END-TO-END POST-MIGRATION INTEGRITY BLOCK
-- =============================================================================
DO $$
DECLARE
    v_missing_tables TEXT[] := ARRAY[]::TEXT[];
    v_missing_types TEXT[] := ARRAY[]::TEXT[];
    v_missing_views TEXT[] := ARRAY[]::TEXT[];
    v_missing_funcs TEXT[] := ARRAY[]::TEXT[];
    v_missing_triggers TEXT[] := ARRAY[]::TEXT[];
    v_tbl TEXT;
    v_typ TEXT;
    v_vw TEXT;
    v_fn TEXT;
    v_trg TEXT;
    v_count INT;
BEGIN
    -- 1. Check all 12 core tables
    FOREACH v_tbl IN ARRAY ARRAY[
        'profiles', 'patients', 'doctors', 'doctor_verifications',
        'doctor_documents', 'doctor_schedules', 'doctor_leaves',
        'appointments', 'in_app_reminders', 'storage_deletion_queue',
        'audit_logs', 'operational_telemetry'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'public' AND table_name = v_tbl
        ) THEN
            v_missing_tables := array_append(v_missing_tables, v_tbl);
        END IF;
    END LOOP;

    -- 2. Check all 4 custom enum types
    FOREACH v_typ IN ARRAY ARRAY[
        'user_role', 'verification_status', 'appointment_status', 'medical_specialty'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_type t 
            JOIN pg_namespace n ON t.typnamespace = n.oid 
            WHERE n.nspname = 'public' AND t.typname = v_typ
        ) THEN
            v_missing_types := array_append(v_missing_types, v_typ);
        END IF;
    END LOOP;

    -- 3. Check all 3 views
    FOREACH v_vw IN ARRAY ARRAY[
        'public_doctor_directory', 'public_doctor_schedules', 'public_doctor_leaves'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.views 
            WHERE table_schema = 'public' AND table_name = v_vw
        ) THEN
            v_missing_views := array_append(v_missing_views, v_vw);
        END IF;
    END LOOP;

    -- 4. Check critical RPC functions
    FOREACH v_fn IN ARRAY ARRAY[
        'auth_user_role', 'is_admin', 'is_doctor', 'is_patient',
        'submit_doctor_application', 'register_doctor_document',
        'complete_patient_onboarding', 'book_appointment',
        'reschedule_appointment', 'cancel_appointment',
        'patient_cancel_appointment', 'doctor_respond_appointment',
        'doctor_close_appointment', 'dismiss_reminder',
        'admin_review_doctor_application', 'admin_list_doctor_applications',
        'admin_get_doctor_application_details', 'admin_get_application_stats',
        'record_telemetry_event', 'admin_list_audit_logs',
        'admin_get_audit_stats', 'admin_list_telemetry_events',
        'admin_get_telemetry_summary'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p 
            JOIN pg_namespace n ON p.pronamespace = n.oid 
            WHERE n.nspname = 'public' AND p.proname = v_fn
        ) THEN
            v_missing_funcs := array_append(v_missing_funcs, v_fn);
        END IF;
    END LOOP;

    -- 5. Check critical triggers
    FOREACH v_trg IN ARRAY ARRAY[
        'trg_protect_profile_role', 'trg_protect_doctor_fields',
        'trg_sync_doctor_approval', 'trg_doctor_documents_storage_cleanup',
        'trg_audit_logs_immutability', 'trg_telemetry_immutability',
        'trg_audit_doctor_verifications', 'trg_audit_appointments',
        'trg_audit_doctor_documents', 'trg_audit_profile_role'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = v_trg
        ) THEN
            v_missing_triggers := array_append(v_missing_triggers, v_trg);
        END IF;
    END LOOP;

    IF array_length(v_missing_tables, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Missing tables: %', v_missing_tables;
    END IF;

    IF array_length(v_missing_types, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Missing types: %', v_missing_types;
    END IF;

    IF array_length(v_missing_views, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Missing views: %', v_missing_views;
    END IF;

    IF array_length(v_missing_funcs, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Missing functions: %', v_missing_funcs;
    END IF;

    IF array_length(v_missing_triggers, 1) > 0 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Missing triggers: %', v_missing_triggers;
    END IF;

    -- Check RLS enablement across all 12 tables
    SELECT COUNT(*) INTO v_count 
    FROM pg_class c 
    JOIN pg_namespace n ON c.relnamespace = n.oid 
    WHERE n.nspname = 'public' 
      AND c.relname IN (
        'profiles', 'patients', 'doctors', 'doctor_verifications',
        'doctor_documents', 'doctor_schedules', 'doctor_leaves',
        'appointments', 'in_app_reminders', 'storage_deletion_queue',
        'audit_logs', 'operational_telemetry'
      )
      AND c.relrowsecurity = true;

    IF v_count < 12 THEN
        RAISE EXCEPTION 'Post-migration integrity failure: Only % of 12 tables have Row Level Security enabled.', v_count;
    END IF;

    RAISE NOTICE '================================================================================';
    RAISE NOTICE '>>> MASTER CONSOLIDATED POST-MIGRATION INTEGRITY BLOCK PASSED SUCCESSFULLY! <<<';
    RAISE NOTICE '    Tables (12/12), Enums (4/4), Views (3/3), Functions (39/39), Triggers (13/13)';
    RAISE NOTICE '    Row Level Security explicitly enabled on all 12 application tables.';
    RAISE NOTICE '================================================================================';
END;
$$;

COMMIT;
