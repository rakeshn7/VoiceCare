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
-- Explicit safety check: Assert no conflicting active doctor schedules exist before replacing constraint
DO $$
DECLARE
    v_conflicts INT := 0;
BEGIN
    SELECT COUNT(*) INTO v_conflicts
    FROM public.doctor_schedules s1
    JOIN public.doctor_schedules s2
        ON s1.doctor_id = s2.doctor_id
       AND s1.day_of_week = s2.day_of_week
       AND s1.id <> s2.id
       AND s1.is_active = true
       AND s2.is_active = true
       AND tsrange(('2000-01-01'::date + s1.start_time), ('2000-01-01'::date + s1.end_time), '[)') &&
           tsrange(('2000-01-01'::date + s2.start_time), ('2000-01-01'::date + s2.end_time), '[)');

    IF v_conflicts > 0 THEN
        RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping active doctor schedule rows in public.doctor_schedules. Resolve overlapping shifts before applying uq_doctor_schedules_no_overlap.', v_conflicts;
    END IF;
END;
$$;

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

-- Exclusion constraints: Prevent doctor and patient double-booking
-- Explicit safety check: Assert no conflicting appointments exist before replacing constraints
DO $$
DECLARE
    v_doctor_conflicts INT := 0;
    v_patient_conflicts INT := 0;
BEGIN
    -- Check for overlapping doctor appointments
    SELECT COUNT(*) INTO v_doctor_conflicts
    FROM public.appointments a1
    JOIN public.appointments a2
        ON a1.doctor_id = a2.doctor_id
       AND a1.id <> a2.id
       AND a1.status IN ('pending', 'confirmed')
       AND a2.status IN ('pending', 'confirmed')
       AND tsrange((a1.appointment_date + a1.appointment_time)::timestamp, (a1.appointment_date + a1.end_time)::timestamp, '[)') &&
           tsrange((a2.appointment_date + a2.appointment_time)::timestamp, (a2.appointment_date + a2.end_time)::timestamp, '[)');

    IF v_doctor_conflicts > 0 THEN
        RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping doctor appointments (pending/confirmed) in public.appointments. Resolve doctor double-bookings before applying uq_doctor_no_appointment_overlap.', v_doctor_conflicts;
    END IF;

    -- Check for overlapping patient appointments
    SELECT COUNT(*) INTO v_patient_conflicts
    FROM public.appointments a1
    JOIN public.appointments a2
        ON a1.patient_id = a2.patient_id
       AND a1.id <> a2.id
       AND a1.status IN ('pending', 'confirmed')
       AND a2.status IN ('pending', 'confirmed')
       AND tsrange((a1.appointment_date + a1.appointment_time)::timestamp, (a1.appointment_date + a1.end_time)::timestamp, '[)') &&
           tsrange((a2.appointment_date + a2.appointment_time)::timestamp, (a2.appointment_date + a2.end_time)::timestamp, '[)');

    IF v_patient_conflicts > 0 THEN
        RAISE EXCEPTION 'PRE-MIGRATION CONSTRAINT CONFLICT: Found % overlapping patient appointments (pending/confirmed) in public.appointments. Resolve patient double-bookings before applying uq_patient_no_appointment_overlap.', v_patient_conflicts;
    END IF;
END;
$$;

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
